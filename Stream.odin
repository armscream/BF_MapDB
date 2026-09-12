// Engine/src/Modules/BF_MapDB/Stream.odin
//
// Chunk-by-chunk streaming of a persistent Map_DB_Document into the
// runtime BF_ECS databases.
//
//
// Pipeline:
//
//   .bmap -> bmap_load_from_file -> Map_DB_Document
//                                |
//                                v
//                Map_DB_Streamer (this file)
//                                |
//                                v
//                  BF_ECS.World (chunk index + entities)
//
// Threading: a single streamer is owned per world. All APIs are expected
// to run on the world owner thread; the runtime scheduler replays
// command-buffer mutations as needed.

package BF_MapDB

import "core:log"
import "base:runtime"
import mth "../../Core/BF_Math"
import Core "../../Core"
import ECS "../BF_ECS"

Map_DB_Streamer_Settings :: struct {
	// Optional override for chunk_size in the world chunk index. If 0,
	// the streamer uses the value from the loaded Map_DB_Document's
	// metadata. The world chunk index must be initialized before the
	// streamer is initialized; mismatched settings are surfaced as a
	// failed stream call rather than a partial state.
	chunk_size:         f32,
	// If true (default), the streamer marks each streamed chunk Active
	// and Visible as soon as its entities are spawned. The renderer
	// extraction scope can then pick the chunk up immediately. Set
	// false for tests / editor previews that want explicit control
	// over chunk activation.
	auto_activate:      bool,
	// If true, world chunk index settings are required to already
	// match `chunk_size`. If false, the streamer still tries to add
	// the chunk (which will fail with a deterministic error if the
	// grid does not match).
	require_chunk_size: bool,
}

MAP_DB_STREAMER_DEFAULT_SETTINGS :: Map_DB_Streamer_Settings {
	chunk_size         = 0, // inherit from Map_DB_Document.metadata
	auto_activate      = true,
	require_chunk_size = false,
}

// Streaming state of a chunk relative to the runtime world. Independent
// from Chunk_Runtime_State (which is the chunk index's own lifecycle).
Map_DB_Stream_State :: enum u8 {
	Unstreamed, // no entities exist for this chunk yet
	Loading,    // streaming in progress (reserved; this implementation is synchronous)
	Loaded,     // all entities for this chunk exist in the runtime ECS
	Unloading,  // unstream in progress (reserved)
	Failed,     // last attempt failed; check map_db_streamer_last_error
}

Map_DB_Stream_Chunk_Record :: struct {
	state:       Map_DB_Stream_State,
	// Map_Entity.entity_index -> runtime Entity, dense. Built once on
	// stream-in; cleared on stream-out. Read-only after the chunk
	// transitions to Loaded (mutated only on Unload).
	entities:    map[u32]ECS.Entity,
	// Reverse lookup so we can find a chunk from a runtime entity when
	// tearing the streamer down. Mirrors the world's entity_chunk, but
	// owned here so the streamer can unstream without re-scanning.
	chunk_by_entity: map[ECS.Entity]ECS.Chunk_ID,
}

// One streamer owns a streaming map for one (world, document) pair.
// The map grows lazily as chunks are streamed in.
Map_DB_Streamer :: struct {
	allocator:       runtime.Allocator,
	world:           ^ECS.World,
	doc:             ^Map_DB_Document,
	settings:        Map_DB_Streamer_Settings,
	// Chunk_ID -> runtime record
	chunks:          map[ECS.Chunk_ID]Map_DB_Stream_Chunk_Record,
	// Last error reported for any stream / unstream call.
	last_error:      Stream_Error,
	last_error_msg:  string,
	// Total entities currently spawned by this streamer.
	entity_count:    int,
}

Stream_Error :: enum {
	None,
	Bad_Input,           // nil world / doc / streamer
	No_World,            // world chunk index not initialized
	World_Mismatch, // world's chunk_size does not match streamer / doc
	Unknown_Chunk,       // chunk id is not in Map_DB_Document
	Already_Loaded,      // chunk already streamed in
	Not_Loaded,          // unstream called on a chunk that isn't streamed
	Entity_Capacity,     // ODE table is full (or world over capacity)
	Component_Insert,    // component_add returned a null slot
	No_Bindings,         // required component bindings are missing from the registry
}

Stream_Result :: struct {
	error:         Stream_Error,
	message:       string,
	// When the call streamed in or out a chunk, this is the count of
	// entities that were created or destroyed. 0 when the call was a
	// no-op (chunk already in the requested state) or failed.
	entities_touched: int,
}

// Init / destroy
map_db_streamer_init :: proc(
	streamer: ^Map_DB_Streamer,
	world: ^ECS.World,
	doc: ^Map_DB_Document,
	settings: Map_DB_Streamer_Settings = MAP_DB_STREAMER_DEFAULT_SETTINGS,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	if streamer == nil do return false
	if world == nil || doc == nil do return false
	if ECS.world_chunk_index(world) == nil do return false

	streamer^ = {}
	streamer.allocator = allocator
	streamer.world     = world
	streamer.doc       = doc
	streamer.settings  = settings
	streamer.chunks    = make(map[ECS.Chunk_ID]Map_DB_Stream_Chunk_Record, allocator)
	streamer.last_error = .None
	return true
}

map_db_streamer_destroy :: proc(streamer: ^Map_DB_Streamer) {
	if streamer == nil do return
	// Best-effort unstream everything we streamed in.
	map_db_streamer_unstream_all(streamer)
	for _, &rec in streamer.chunks {
		delete(rec.entities)
		delete(rec.chunk_by_entity)
	}
	delete(streamer.chunks)
	streamer^ = {}
}

// Resolve the ODE table + add/get/has/remove vtable entries for every
// built-in component the streamer needs to write. Returns false if any
// required binding is missing. Missing optional bindings are reported via
// the `out_*_present` flags so callers can decide whether to skip the
// corresponding component.
streamer_bindings :: struct {
	// Required.
	transform:         ECS.Component_Binding,
	render_model:      ECS.Component_Binding,
	chunk_membership:  ECS.Component_Binding,
	spatial_state:     ECS.Component_Binding,
	// Optional.
	material_override_present: bool,
	material_override:         ECS.Component_Binding,
	spatial_bounds_present:    bool,
	spatial_bounds:            ECS.Component_Binding,
}

streamer_resolve_bindings :: proc(b: ^streamer_bindings, world: ^ECS.World) -> bool {
	if b == nil || world == nil do return false

	b.transform        = binding_lookup(world, ECS.Transform, .Gameplay)
	b.render_model     = binding_lookup(world, ECS.Render_Model, .Gameplay)
	b.chunk_membership = binding_lookup(world, ECS.Chunk_Membership, .Spatial)
	b.spatial_state    = binding_lookup(world, ECS.Spatial_State, .Spatial)

	b.material_override = binding_lookup(world, ECS.Render_Material_Override, .Gameplay)
	b.material_override_present = b.material_override.table != nil

	b.spatial_bounds = binding_lookup(world, ECS.Spatial_Bounds, .Spatial)
	b.spatial_bounds_present = b.spatial_bounds.table != nil

	if b.transform.table == nil do return false
	if b.render_model.table == nil do return false
	if b.chunk_membership.table == nil do return false
	if b.spatial_state.table == nil do return false
	return true
}

@(private)
binding_lookup :: proc(world: ^ECS.World, $T: typeid, db: ECS.Database_Kind) -> ECS.Component_Binding {
	descriptor := ECS.component_find_by_type(T, &world.registry)
	if descriptor == nil do return {}
	b := ECS.component_binding_find(descriptor, db)
	if b == nil do return {}
	return b^
}

// ============================================================================
//* Public API

// Returns the streaming state of a chunk relative to the world.
map_db_streamer_chunk_state :: proc(
	streamer: ^Map_DB_Streamer,
	id: ECS.Chunk_ID,
) -> Map_DB_Stream_State {
	if streamer == nil do return .Unstreamed
	rec, ok := streamer.chunks[id]
	if !ok do return .Unstreamed
	return rec.state
}

// Stream a single chunk out of the persistent document into the runtime
// world. Idempotent: re-streaming a chunk that is already Loaded is a
// no-op that returns Already_Loaded.
map_db_stream_chunk :: proc(
	streamer: ^Map_DB_Streamer,
	id: ECS.Chunk_ID,
) -> Stream_Result {
	result: Stream_Result

	if streamer == nil || streamer.world == nil || streamer.doc == nil {
		streamer_set_err(streamer, .Bad_Input, "nil streamer / world / doc")
		result.error   = .Bad_Input
		result.message = "nil streamer / world / doc"
		return result
	}

	if id == ECS.CHUNK_INVALID {
		streamer_set_err(streamer, .Bad_Input, "CHUNK_INVALID")
		result.error   = .Bad_Input
		result.message = "CHUNK_INVALID"
		return result
	}

	if rec, ok := streamer.chunks[id]; ok && rec.state == .Loaded {
		streamer_set_err(streamer, .Already_Loaded, "chunk already loaded")
		result.error = .Already_Loaded
		return result
	}

	doc_idx := map_db_find_chunk(streamer.doc, id)
	if doc_idx < 0 {
		streamer_set_err(streamer, .Unknown_Chunk, "chunk id not in document")
		result.error   = .Unknown_Chunk
		result.message = "chunk id not in document"
		return result
	}

	chunk_record := &streamer.doc.chunks[doc_idx]

	// Chunk-size sanity: if the streamer was configured with a chunk_size
	// override, make sure the world chunk index matches.
	expected_size := streamer.settings.chunk_size
	if expected_size <= 0 do expected_size = streamer.doc.metadata.chunk_size
	idx := ECS.world_chunk_index(streamer.world)
	if idx == nil {
		streamer_set_err(streamer, .No_World, "world chunk index not initialized")
		result.error   = .No_World
		result.message = "world chunk index not initialized"
		return result
	}
	if expected_size > 0 && streamer.settings.require_chunk_size {
		if idx.settings.chunk_size != expected_size {
			streamer_set_err(streamer, .World_Mismatch,
				"world chunk_size does not match streamer / doc")
			result.error   = .World_Mismatch
			result.message = "world chunk_size mismatch"
			return result
		}
	}

	// Resolve component bindings. If the world has not registered
	// built-in components, refuse to stream rather than silently
	// dropping data.
	bindings: streamer_bindings
	if !streamer_resolve_bindings(&bindings, streamer.world) {
		streamer_set_err(streamer, .No_Bindings, "required ECS component bindings missing")
		result.error   = .No_Bindings
		result.message = "required component bindings missing"
		return result
	}

	// Register the chunk in the world chunk index. Idempotent: if the
	// caller has already pre-registered it (e.g. the editor allocated
	// the runtime ahead of time), this is a no-op.
	if !ECS.chunk_index_contains(idx, id) {
		// Use chunk_size from the index settings if non-zero, else
		// recompute bounds from the persistent document.
		size: f32 = idx.settings.chunk_size
		if size <= 0 do size = expected_size
		bounds: mth.AABB
		if chunk_record.bounds.min != chunk_record.bounds.max {
			bounds = chunk_record.bounds
		} else if size > 0 {
			bounds = ECS.chunk_calculate_bounds(id, size)
		} else {
			bounds = mth.AABB{min = -mth.Vec3{1,1,1}, max = mth.Vec3{1,1,1}}
		}
		if ECS.chunk_index_register(idx, id, bounds, chunk_record.flags) == nil {
			streamer_set_err(streamer, .Entity_Capacity, "chunk_index_register failed")
			result.error   = .Entity_Capacity
			result.message = "chunk_index_register failed"
			return result
		}
	}

	// Allocate the per-chunk record up front so partial failures can be
	// unwound. The maps are heap-allocated to keep the streamer struct
	// size bounded even for very chunk-rich maps.
	rec := Map_DB_Stream_Chunk_Record {
		state           = .Loading,
		entities        = make(map[u32]ECS.Entity, streamer.allocator),
		chunk_by_entity = make(map[ECS.Entity]ECS.Chunk_ID, streamer.allocator),
	}
	streamer.chunks[id] = rec
	rec_ptr := &streamer.chunks[id]

	spawned := 0
	failed  := false

	for ei in chunk_record.entities {
		doc_entity_idx := map_db_find_entity(streamer.doc, ei)
		if doc_entity_idx < 0 {
			failed = true
			break
		}
		me := &streamer.doc.entities[doc_entity_idx]
		runtime_entity, ok := stream_create_entity_for(
			streamer, me, id, &bindings,
		)
		if !ok {
			failed = true
			break
		}
		rec_ptr.entities[ei] = runtime_entity
		rec_ptr.chunk_by_entity[runtime_entity] = id
		spawned += 1
	}

	if failed {
		// Unwind every entity we just spawned.
		for _, e in rec_ptr.entities {
			stream_destroy_entity_for(streamer, e, &bindings)
		}
		delete(rec_ptr.entities)
		delete(rec_ptr.chunk_by_entity)
		delete_key(&streamer.chunks, id)
		// Leave the chunk registered with the chunk index so the caller
		// can decide whether to unregister it. We could roll that back,
		// but unregistering an unknown chunk is cheap enough to defer.
		streamer_set_err(streamer, .Component_Insert, "entity spawn failed mid-chunk")
		result.error   = .Component_Insert
		result.message = "entity spawn failed mid-chunk"
		return result
	}

	rec_ptr.state = .Loaded
	streamer.entity_count += spawned

	// Flip the chunk's subsystem states.
	if streamer.settings.auto_activate {
		ECS.chunk_index_set_state(idx, id, .Active)
		ECS.chunk_index_toggle_state(idx, id, .Loaded, true)
		ECS.chunk_index_toggle_state(idx, id, .Active, true)
		ECS.chunk_index_toggle_state(idx, id, .Visible, true)
	} else {
		ECS.chunk_index_set_state(idx, id, .Loaded)
		ECS.chunk_index_toggle_state(idx, id, .Loaded, true)
	}

	streamer.last_error = .None
	result.error = .None
	result.message = ""
	result.entities_touched = spawned

	log.debugf(
		"[MapDB.Streamer] streamed chunk %016X (%d entities) into world",
		u64(id), spawned,
	)
	return result
}

// Unstream a chunk: destroy every runtime entity that was created for
// it, clear its membership in the world chunk index, and remove the
// chunk from the streamer record. Idempotent for Unstreamed chunks.
map_db_unstream_chunk :: proc(
	streamer: ^Map_DB_Streamer,
	id: ECS.Chunk_ID,
) -> Stream_Result {
	result: Stream_Result

	if streamer == nil {
		result.error = .Bad_Input
		return result
	}
	if id == ECS.CHUNK_INVALID {
		streamer_set_err(streamer, .Bad_Input, "CHUNK_INVALID")
		result.error = .Bad_Input
		return result
	}
	rec, ok := streamer.chunks[id]
	if !ok || rec.state != .Loaded {
		streamer_set_err(streamer, .Not_Loaded, "chunk not loaded")
		result.error = .Not_Loaded
		return result
	}

	bindings: streamer_bindings
	_ = streamer_resolve_bindings(&bindings, streamer.world)

	destroyed := 0
	for _, e in rec.entities {
		stream_destroy_entity_for(streamer, e, &bindings)
		destroyed += 1
	}
	streamer.entity_count -= destroyed

	// Drop the chunk from the runtime chunk index. This also clears
	// any entities that were still membered to it via chunk_index_set_*
	// before the teardown.
	idx := ECS.world_chunk_index(streamer.world)
	if idx != nil {
		ECS.chunk_index_unregister(idx, id)
	}

	delete(rec.entities)
	delete(rec.chunk_by_entity)
	delete_key(&streamer.chunks, id)

	streamer.last_error = .None
	result.error = .None
	result.entities_touched = destroyed

	log.debugf(
		"[MapDB.Streamer] unstreamed chunk %016X (%d entities)",
		u64(id), destroyed,
	)
	return result
}

// Unstream every chunk the streamer currently owns. Used at shutdown
// and on map unload.
map_db_streamer_unstream_all :: proc(streamer: ^Map_DB_Streamer) -> int {
	if streamer == nil do return 0
	// Copy chunk IDs so we can mutate the map while iterating.
	ids := make([dynamic]ECS.Chunk_ID, 0, len(streamer.chunks), streamer.allocator)
	defer delete(ids)
	for id, rec in streamer.chunks {
		if rec.state == .Loaded do append(&ids, id)
	}
	destroyed := 0
	for id in ids {
		r := map_db_unstream_chunk(streamer, id)
		destroyed += r.entities_touched
	}
	return destroyed
}

// Convenience helper to stream every chunk the persistent document
// knows about. Returns the total entities spawned (or 0 on error).
map_db_streamer_stream_all :: proc(streamer: ^Map_DB_Streamer) -> Stream_Result {
	result: Stream_Result
	if streamer == nil {
		result.error = .Bad_Input
		return result
	}
	if len(streamer.doc.chunks) == 0 {
		result.error = .None
		result.message = "document has no chunks"
		return result
	}
	for &c in streamer.doc.chunks {
		if rec, ok := streamer.chunks[c.id]; ok && rec.state == .Loaded do continue
		r := map_db_stream_chunk(streamer, c.id)
		if r.error != .None {
			result.error = r.error
			result.message = r.message
			return result
		}
		result.entities_touched += r.entities_touched
	}
	return result
}

// Number of chunks currently in the Loaded state.
map_db_streamer_chunk_count :: #force_inline proc(streamer: ^Map_DB_Streamer) -> int {
	if streamer == nil do return 0
	n := 0
	for _, rec in streamer.chunks {
		if rec.state == .Loaded do n += 1
	}
	return n
}

// Number of runtime entities currently spawned by the streamer.
map_db_streamer_entity_count :: #force_inline proc(streamer: ^Map_DB_Streamer) -> int {
	if streamer == nil do return 0
	return streamer.entity_count
}

// Returns the runtime entity created for a given persistent
// Map_Entity.entity_index, or ENTITY_INVALID when the chunk that owns
// it is not streamed.
map_db_streamer_lookup :: proc(
	streamer: ^Map_DB_Streamer,
	doc_entity_index: u32,
) -> ECS.Entity {
	if streamer == nil do return ECS.ENTITY_INVALID
	doc_idx := map_db_find_entity(streamer.doc, doc_entity_index)
	if doc_idx < 0 do return ECS.ENTITY_INVALID
	chunk_id := streamer.doc.entities[doc_idx].chunk
	if chunk_id == ECS.CHUNK_INVALID do return ECS.ENTITY_INVALID
	rec, found := streamer.chunks[chunk_id]
	if !found do return ECS.ENTITY_INVALID
	e, has := rec.entities[doc_entity_index]
	if !has do return ECS.ENTITY_INVALID
	return e
}

// ============================================================================
//* Internal: spawn / destroy one entity

@(private)
stream_create_entity_for :: proc(
	streamer: ^Map_DB_Streamer,
	me: ^Map_Entity,
	chunk: ECS.Chunk_ID,
	b: ^streamer_bindings,
) -> (ECS.Entity, bool) {
	entity := ECS.world_create_entity(streamer.world)
	if entity == ECS.ENTITY_INVALID do return ECS.ENTITY_INVALID, false

	//* Transform
	if me.has_transform {
		slot, ok := typed_add(ECS.Transform, &b.transform, entity)
		if !ok do return entity, false
		t := cast(^ECS.Transform)slot
		t.local = me.transform
		// World matrix will be filled by the transform system; we do not
		// pre-bake it here.
	}

	//* Render_Model
	if me.has_render_model {
		slot, ok := typed_add(ECS.Render_Model, &b.render_model, entity)
		if !ok do return entity, false
		rm := cast(^ECS.Render_Model)slot
		rm.flags = me.render_model.flags
		if len(me.render_model.model_source) > 0 {
			asset_id := map_db_find_asset(
				streamer.doc,
				me.render_model.model_source,
				.Model,
			)
			rm.model.id   = asset_id
			rm.model.type = .Model
		} else {
			rm.model.id   = Core.ASSET_INVALID
			rm.model.type = .Unknown
		}
	}

	//* Render_Material_Override.
	// ODE tables only allow one component per entity per table, so a
	// multi-slot entity has to fall back to a single runtime override
	// (slot 0). The full per-slot list is preserved on the persistent
	// Map_Entity.material_override_refs-style storage; downstream code
	// that needs the per-slot values can read them straight from the
	// document after streaming.
	if b.material_override_present {
		for src in me.render_model.materials {
			if len(src) == 0 do continue
			slot, ok := typed_add(
				ECS.Render_Material_Override,
				&b.material_override,
				entity,
			)
			if !ok do return entity, false
			ov := cast(^ECS.Render_Material_Override)slot
			ov.material.id   = map_db_find_asset(streamer.doc, src, .Material)
			ov.material.type = .Material
			ov.slot          = 0
			break
		}
	}

	//* Chunk_Membership
	{
		slot, ok := typed_add(ECS.Chunk_Membership, &b.chunk_membership, entity)
		if !ok do return entity, false
		cm := cast(^ECS.Chunk_Membership)slot
		cm.chunk = me.has_chunk ? me.chunk : chunk
	}

	//* Spatial_Bounds
	if b.spatial_bounds_present && me.has_bounds {
		slot, ok := typed_add(ECS.Spatial_Bounds, &b.spatial_bounds, entity)
		if !ok do return entity, false
		sb := cast(^ECS.Spatial_Bounds)slot
		sb.local = me.bounds.local
		sb.world = me.bounds.world
	}

	//* Spatial_State
	{
		slot, ok := typed_add(ECS.Spatial_State, &b.spatial_state, entity)
		if !ok do return entity, false
		ss := cast(^ECS.Spatial_State)slot
		ss.flags = me.has_spatial_state ? me.spatial_state.flags : ECS.Spatial_Flags{}
	}

	//* Chunk-index membership. Has to happen after the entity exists
	//   and after the chunk is registered with the index.
	idx := ECS.world_chunk_index(streamer.world)
	if idx != nil {
		if !ECS.chunk_index_set_entity_chunk(idx, entity, cm_chunk_id(me, chunk)) {
			// The chunk is registered but membership failed. Treat it as
			// a hard failure so the chunk rolls back cleanly.
			return entity, false
		}
	}

	return entity, true
}

@(private)
stream_destroy_entity_for :: proc(
	streamer: ^Map_DB_Streamer,
	entity: ECS.Entity,
	b: ^streamer_bindings,
) {
	// Chunk_Membership has to be cleared before the entity is destroyed
	// so the reverse map does not retain a stale reference.
	idx := ECS.world_chunk_index(streamer.world)
	if idx != nil {
		ECS.chunk_index_clear_entity(idx, entity)
	}

	if b.transform.table != nil        do b.transform.remove(b.transform.table, entity)
	if b.render_model.table != nil     do b.render_model.remove(b.render_model.table, entity)
	if b.material_override.table != nil {
		_ = b.material_override.remove(b.material_override.table, entity)
	}
	if b.chunk_membership.table != nil do b.chunk_membership.remove(b.chunk_membership.table, entity)
	if b.spatial_bounds.table != nil   do b.spatial_bounds.remove(b.spatial_bounds.table, entity)
	if b.spatial_state.table != nil    do b.spatial_state.remove(b.spatial_state.table, entity)

	destroy_target := entity
	_ = ECS.world_destroy_entity(streamer.world, &destroy_target)
}

@(private)
typed_add :: proc(
	$T: typeid,
	binding: ^ECS.Component_Binding,
	entity: ECS.Entity,
) -> (rawptr, bool) {
	if binding.table == nil || binding.add == nil do return nil, false
	slot := binding.add(binding.table, entity)
	if slot == nil do return nil, false
	return slot, true
}

@(private)
cm_chunk_id :: proc(me: ^Map_Entity, fallback: ECS.Chunk_ID) -> ECS.Chunk_ID {
	return me.has_chunk ? me.chunk : fallback
}

@(private)
streamer_set_err :: proc(
	streamer: ^Map_DB_Streamer,
	err: Stream_Error,
	msg: string,
) {
	if streamer == nil do return
	streamer.last_error = err
	streamer.last_error_msg = msg
}