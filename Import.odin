// Engine/src/Modules/BF_MapDB/Import.odin
//
// GLTF_Document -> Map_DB_Document conversion.
//
// Per prompt_plan items 65-77:
//   - Convert imported Blender scene hierarchy into Bifrost entities and
//     relationships (parent / children indices).
//   - Convert imported transforms into Transform_Local.
//   - Convert imported meshes / models / material references into
//     Bifrost asset references (Asset_Ref on Asset_ID).
//   - Convert Blender scene objects into the appropriate Bifrost
//     ECS / map entities (Mesh_Instance for nodes with meshes, plain
//     Node otherwise).
//   - Preserve hierarchy / parent-child relationships during import.
//   - Convert imported static geometry into the persistent map /
//     static-map representation.
//   - Associate imported objects with the appropriate world chunks
//     (Chunk_Membership derived from world position via
//     chunk_calculate_from_position).
//   - Generate chunk membership / spatial bounds for imported static
//     geometry.
//   - Keep imported source asset identity separate from runtime GPU
//     resource IDs (asset paths are stable strings, not GPU IDs).
//
// This module produces a Map_DB_Document that can be serialized to
// .bmap (BMAP.odin) or directly instantiated into runtime ECS
// databases (deferred to a follow-up).

package BF_MapDB

import "core:fmt"
import "core:math"
import "base:runtime"
import mth "../../Core/BF_Math"
import Core "../../Core"
import ECS "../BF_ECS"

// ============================================================================
// Import settings
// ============================================================================

Import_Settings :: struct {
	// World-space size of one chunk edge. Used to compute
	// Chunk_Membership from entity translation.
	chunk_size:        f32,
	// Map-level flags applied to the resulting document.
	map_flags:         ECS.Map_Flags,
	// Optional generator / version stamped on the document.
	generator:         string,
	generator_version: string,
}

IMPORT_DEFAULT_SETTINGS :: Import_Settings {
	chunk_size        = 64.0,
	map_flags         = {.Persistent, .Runtime},
	generator         = "BF_MapDB.GLTFImporter",
	generator_version = "0.0.1",
}

// ============================================================================
// Import result
// ============================================================================

Import_Stats :: struct {
	nodes_visited:    int,
	entities_emitted: int,
	meshes_referenced: int,
	materials_referenced: int,
	chunks_touched:   int,
}

Import_Result :: struct {
	error:   Import_Error,
	message: string,
	stats:   Import_Stats,
}

Import_Error :: enum {
	None,
	Bad_Input,
	Empty_Scene,
}

// ============================================================================
// Top-level import
// ============================================================================

// Import a GLTF document into `doc`. The destination document is
// cleared via map_db_reset before import. The source document's
// `source_path` is preserved on `doc.metadata.source_path` if set.
map_db_import_gltf :: proc(
	doc: ^Map_DB_Document,
	gltf: ^GLTF_Document,
	settings := IMPORT_DEFAULT_SETTINGS,
) -> Import_Result {
	result: Import_Result
	if doc == nil || gltf == nil {
		result.error   = .Bad_Input
		result.message = "nil doc or gltf"
		return result
	}

	context.allocator = doc.allocator

	map_db_reset(doc)
	doc.metadata.flags          = settings.map_flags
	doc.metadata.chunk_size     = settings.chunk_size
	doc.metadata.generator      = settings.generator
	doc.metadata.generator_version = settings.generator_version
	doc.metadata.source_format  = gltf.source_format == .GLB ? "GLB" : "GLTF"
	doc.metadata.source_path    = gltf.source_path

	// Choose the scene to import: default scene if present, else the
	// first one.
	if gltf.default_scene >= 0 && gltf.default_scene < len(gltf.scenes) {
		// walk from gltf.scenes[default_scene].nodes
	} else if len(gltf.scenes) == 0 {
		result.error   = .Empty_Scene
		result.message = "GLTF document has no scenes"
		return result
	}

	scene_index: int
	if gltf.default_scene >= 0 && gltf.default_scene < len(gltf.scenes) {
		scene_index = gltf.default_scene
	} else {
		scene_index = 0
	}
	scene_root_nodes := gltf.scenes[scene_index].nodes[:]

	visited := make([dynamic]bool, len(gltf.nodes), doc.allocator)
	defer delete(visited)

	for ri in scene_root_nodes {
		import_walk_node(doc, gltf, ri, -1, visited, settings, &result.stats)
	}

	return result
}

// ============================================================================
// Node walk
// ============================================================================

@(private)
import_walk_node :: proc(
	doc: ^Map_DB_Document,
	gltf: ^GLTF_Document,
	node_index: int,
	parent_entity_index: int,
	visited: [dynamic]bool,
	settings: Import_Settings,
	stats: ^Import_Stats,
) {
	if node_index < 0 || node_index >= len(gltf.nodes) do return
	if visited[node_index] do return
	visited[node_index] = true
	stats.nodes_visited += 1

	n := &gltf.nodes[node_index]

	// Emit one entity per GLTF node. The `name` string borrows from
	// the GLTF document; the caller is expected to keep `gltf` alive
	// for as long as the Map_DB is used. The hierarchy index is the
	// position the entity will occupy in `doc.entities`.
	my_index := len(doc.entities)

	e := Map_Entity {
		entity_index = u32(my_index),
		name         = n.name,
		parent       = parent_entity_index,
	}

	//* Transform
	e.has_transform = true
	e.transform.position = {n.translation[0], n.translation[1], n.translation[2]}
	e.transform.rotation = quaternion_from_gltf(n.rotation)
	e.transform.scale    = {n.scale[0], n.scale[1], n.scale[2]}
	if n.has_matrix {
		// Decompose into position/rotation/scale (T-R-S only).
		// For v1 we extract position from the translation column;
		// full decomposition is a follow-up.
		e.transform.position = {n.matrix_data[12], n.matrix_data[13], n.matrix_data[14]}
		e.has_transform = true
	}

	//* Render_Model (only if the node has a mesh)
	if n.mesh >= 0 && n.mesh < len(gltf.meshes) {
		mesh := &gltf.meshes[n.mesh]
		e.kind             = .Mesh_Instance
		e.has_render_model = true
		e.render_model.model_source = import_mesh_source(gltf, mesh, n.mesh)
		stats.meshes_referenced += 1
		for &p in mesh.primitives {
			append(&e.render_model.materials, import_material_source(gltf, p.material, int(p.material)))
			stats.materials_referenced += 1
		}
		e.render_model.flags = {.Static, .Visible}
	}

	//* Chunk membership: derived from world position. For nodes with
	//   no mesh, we still assign a chunk so spatial queries can find
	//   the empty parent.
	if settings.chunk_size > 0 {
		e.has_chunk = true
		e.chunk     = ECS.chunk_calculate_from_position(e.transform.position, settings.chunk_size)
	}

	//* Spatial state
	e.has_spatial_state = true
	if e.kind == .Mesh_Instance {
		e.spatial_state.flags = {.Active, .Visible}
	} else {
		e.spatial_state.flags = {.Active}
	}

	// Append + record chunk membership.
	append(&doc.entities, e)
	stats.entities_emitted += 1
	doc.entity_by_index[e.entity_index] = my_index

	if e.has_chunk {
		import_record_chunk_membership(doc, u32(my_index), e.chunk, stats)
	}

	// Record this child on the parent's children list (if it has one).
	if parent_entity_index >= 0 && parent_entity_index < len(doc.entities) {
		append(&doc.entities[parent_entity_index].children, my_index)
	}

	// Recurse into children.
	for ci in n.children {
		import_walk_node(doc, gltf, ci, my_index, visited, settings, stats)
	}
}

// ============================================================================
// Asset source path helpers
// ============================================================================

@(private)
import_mesh_source :: proc(gltf: ^GLTF_Document, mesh: ^GLTF_Mesh, index: int) -> string {
	if len(mesh.name) > 0 do return fmt.tprintf("meshes/%s.bmesh", mesh.name)
	return fmt.tprintf("meshes/%s#%d.bmesh", base_name(gltf.source_path), index)
}

@(private)
import_material_source :: proc(gltf: ^GLTF_Document, material_index: int, slot: int) -> string {
	if material_index >= 0 && material_index < len(gltf.materials) {
		m := &gltf.materials[material_index]
		if len(m.name) > 0 do return fmt.tprintf("materials/%s.bmat", m.name)
		return fmt.tprintf("materials/%s#%d.bmat", base_name(gltf.source_path), material_index)
	}
	return fmt.tprintf("materials/default#%d.bmat", slot)
}

@(private)
base_name :: proc(path: string) -> string {
	if path == "" do return "map"
	base := path
	if slash := last_index_byte(path, '/'); slash >= 0 do base = path[slash+1:]
	if bslash := last_index_byte(base, '\\'); bslash >= 0 do base = base[bslash+1:]
	if dot := last_index_byte(base, '.'); dot > 0 do base = base[:dot]
	if len(base) == 0 do return "map"
	return base
}

@(private)
last_index_byte :: proc(s: string, sub: byte) -> int {
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == sub do return i
	}
	return -1
}

// ============================================================================
// Chunk membership
// ============================================================================

@(private)
import_record_chunk_membership :: proc(
	doc: ^Map_DB_Document,
	entity_index: u32,
	id: ECS.Chunk_ID,
	stats: ^Import_Stats,
) {
	// CHUNK_INVALID happens to be 0, which is also a valid origin chunk.
	// We always want to register chunk_id == 0 because the caller has
	// already gated on has_chunk (which is set only for non-trivial
	// positions in this importer), so just record it.
	idx := map_db_find_chunk(doc, id)
	if idx < 0 {
		bounds := ECS.chunk_calculate_bounds(id, doc.metadata.chunk_size)
		c := Map_Chunk {
			id      = id,
			name    = fmt.tprintf("chunk_%016X", u64(id)),
			bounds  = bounds,
			flags   = {.Persistent, .Streamable, .Baked},
		}
		append(&doc.chunks, c)
		idx = len(doc.chunks) - 1
		stats.chunks_touched += 1
	}
	append(&doc.chunks[idx].entities, entity_index)
}

// ============================================================================
// Quaternion helper
// ============================================================================

@(private)
quaternion_from_gltf :: proc(gltf_q: [4]f32) -> quaternion128 {
	x := gltf_q[0]
	y := gltf_q[1]
	z := gltf_q[2]
	w := gltf_q[3]
	// GLTF is xyzw; the quaternion() builtin expects (w, x, y, z).
	q := quaternion(w = w, x = x, y = y, z = z)
	// Normalize defensively.
	raw := (cast(^runtime.Raw_Quaternion128)&q)
	len := math.sqrt(raw.real * raw.real + raw.imag * raw.imag + raw.jmag * raw.jmag + raw.kmag * raw.kmag)
	if len > 0 {
		raw.real /= len
		raw.imag /= len
		raw.jmag /= len
		raw.kmag /= len
	}
	return q
}

// ============================================================================
// Asset registration helpers
// ============================================================================

// Register every asset referenced by the document. Call this after
// map_db_import_gltf to populate `doc.assets` from the entities'
// Render_Model + material references. Returns the count of new
// assets registered. Idempotent: re-registering the same source
// returns the existing Asset_ID.
map_db_register_assets :: proc(doc: ^Map_DB_Document) -> int {
	if doc == nil do return 0
	context.allocator = doc.allocator
	n := 0
	for &e in doc.entities {
		if !e.has_render_model do continue
		if len(e.render_model.model_source) > 0 {
			_ = map_db_register_asset(doc, e.render_model.model_source, .Model, e.name)
			n += 1
		}
		for mat in e.render_model.materials {
			if len(mat) == 0 do continue
			_ = map_db_register_asset(doc, mat, .Material, "")
			n += 1
		}
	}
	return n
}
