// Engine/src/Modules/BF_MapDB/Types.odin
//
// Shared types for the static-map pipeline.
//
// Three layers, owned by BF_MapDB:
//
//   GLTF_Document
//     Pure GLTF/GLB-parsed representation. Asset paths are GLTF URIs
//     (relative to the imported file). Used only by the importer; not
//     serialized to .bmap.
//
//   Map_DB_Document
//     Persistent, editor-time map database. Entities carry the same
//     components BF_ECS exposes at runtime (Transform, Render_Model,
//     Chunk_Membership, Spatial_Bounds, Spatial_State, ...), plus
//     hierarchy metadata. Asset references are stable Asset_Ref
//     values keyed by string source paths. This is the structure
//     that .bmap serializes.
//
//   BMAP types
//     On-disk versioned binary layout for Map_DB_Document. Has
//     stable IDs and is forward-compatible at the section-table
//     level: unknown sections are skipped on load.
//
// Runtime state (GPU resource IDs, chunk streaming lifecycle, command
// buffers, ...) is deliberately NOT represented in any of these
// types. See Plans/prompt_plan.md items 54-62.

package BF_MapDB

import "base:runtime"
import mth "../../Core/BF_Math"
import Core "../../Core"
import ECS "../BF_ECS"

// GLTF_* types and helpers now live in Engine/src/dependencies/gltf
// and are re-exported from GLTF.odin in this package. See GLTF.odin.

// ============================================================================
// Map DB: persistent map representation
// ============================================================================

// Asset identity is the same `Core.Asset_Ref` / `Core.Asset_ID` that
// BF_ECS uses at runtime. The `source` field carries the original
// (relative) URI from the GLTF and is the stable name in .bmap.
Map_Asset_Entry :: struct {
	id:     ECS.Asset_ID,
	type:   Core.Asset_Type,
	source: string, // path/URI relative to the .bmap or source GLTF
	name:   string, // optional display name
}

// Persistent entity record. Mirrors BF_ECS components but stores only
// what needs to be serialized. `parent` is -1 for root nodes; siblings
// use the document order. `kind` describes what the entity represents
// in the static map.
Map_Entity :: struct {
	entity_index: u32, // dense, stable per map; runtime maps onto ODE Entity.ix
	name:         string,
	kind:         Map_Entity_Kind,
	parent:       int, // -1 if root
	children:     [dynamic]int,
	transform:    ECS.Transform_Local,
	has_transform: bool,
	render_model: Map_Render_Model,
	has_render_model: bool,
	chunk:        ECS.Chunk_ID,
	has_chunk:    bool,
	bounds:       Map_Spatial_Bounds,
	has_bounds:   bool,
	spatial_state: ECS.Spatial_State,
	has_spatial_state: bool,
	asset_refs:   [dynamic]Map_Asset_Ref, // auxiliary asset links (materials etc.)
	tags:         [dynamic]string,        // optional string tags
}

Map_Entity_Kind :: enum u8 {
	Node,            // bare transform node (empty parent)
	Mesh_Instance,   // has Render_Model + Transform + Chunk_Membership
	Light,           // future
	Audio_Source,    // future
	Particle,        // future
	Prefab,          // future
	Custom,
}

Map_Render_Model :: struct {
	model_source: string,       // GLTF mesh name or path
	materials:    [dynamic]string, // GLTF material names / paths per primitive slot
	flags:        ECS.Render_Instance_Flags,
}

Map_Spatial_Bounds :: struct {
	local: mth.AABB,
	world: mth.AABB,
}

// Asset reference on an entity (slot + Asset_ID). Slot is a small int
// so per-entity overrides (e.g. "this chair's 3rd material is wood")
// round-trip cleanly.
Map_Asset_Ref :: struct {
	slot:     u16,
	asset_id: ECS.Asset_ID,
}

// Chunk record persisted in the map. Streaming lifecycle is intentionally
// NOT stored; only the persistent shape (id, bounds, flags, name, entity
// list) is. See prompt_plan §16 / §59.
Map_Chunk :: struct {
	id:     ECS.Chunk_ID,
	name:   string,
	bounds: mth.AABB,
	flags:  ECS.Chunk_Flags,
	entities: [dynamic]u32, // Map_Entity.entity_index
}

Map_Metadata :: struct {
	name:           string,
	source_format:  string, // "GLTF" / "GLB" / "Editor"
	source_path:    string,
	generator:      string,
	generator_version: string,
	created_at_unix: i64,
	flags:          ECS.Map_Flags,
	chunk_size:     f32,
}

// Top-level persistent map representation. This is what .bmap serializes.
// Heap-owned slices are tracked so the destroy proc can free them.
Map_DB_Document :: struct {
	allocator: runtime.Allocator,
	metadata:  Map_Metadata,
	assets:    [dynamic]Map_Asset_Entry,
	entities:  [dynamic]Map_Entity,
	chunks:    [dynamic]Map_Chunk,
	// entity_index -> entity slot (index into `entities`). Built lazily
	// for `map_db_resolve_entity`.
	entity_by_index: map[u32]int,
}

// ============================================================================
// .bmap on-disk format
// ============================================================================

// Magic bytes: "BMAP" + a four-byte version-major tag.
BMAP_MAGIC :: [4]u8{'B', 'M', 'A', 'P'}

// Bump on every breaking change to the layout. Additive changes (new
// optional sections, new fields appended to existing sections) do not
// require a bump as long as the section table is consulted first.
BMAP_VERSION_MAJOR :: u32(1)
BMAP_VERSION_MINOR :: u32(0)
BMAP_VERSION_PATCH :: u32(0)

BMAP_VERSION :: u32(
	(BMAP_VERSION_MAJOR << 24) |
	(BMAP_VERSION_MINOR << 16) |
	(BMAP_VERSION_PATCH <<  0),
)

// Section IDs. Stable; new sections get new IDs and older readers skip them.
BMAP_SECTION_NONE       :: u32(0)
BMAP_SECTION_STRINGS    :: u32(1) // shared string table (used for asset sources + entity names)
BMAP_SECTION_METADATA   :: u32(2)
BMAP_SECTION_ASSETS     :: u32(3)
BMAP_SECTION_CHUNKS     :: u32(4)
BMAP_SECTION_ENTITIES   :: u32(5)
BMAP_SECTION_HIERARCHY  :: u32(6) // parent / children indices per entity

// On-disk section record.
BMAP_Section_Header :: struct {
	id:     u32,
	length: u32, // payload bytes (does not include this header)
	flags:  u32,
}

// On-disk file header. Followed by the section table; sections are
// laid out in declaration order in the file body.
BMAP_Header :: struct {
	magic:    [4]u8,    // BMAP_MAGIC
	version:  u32,      // BMAP_VERSION
	flags:    u32,      // BMAP_FLAGS_*
	section_count: u16,
	reserved: u16,
	// Variable-length section table follows.
}

BMAP_FLAGS_NONE :: u32(0)
BMAP_FLAG_LITTLE_ENDIAN :: u32(1 << 0) // informational; readers assume LE

// ============================================================================
// Lifecycle
// ============================================================================
//
// GLTF lifecycle procs (gltf_document_init / gltf_document_destroy) have
// moved to Engine/src/dependencies/gltf and are re-exported from
// GLTF.odin in this package.

map_db_init :: proc(doc: ^Map_DB_Document, allocator := context.allocator) {
	if doc == nil do return
	doc.allocator = allocator
	doc.entity_by_index = make(map[u32]int, allocator)
}

map_db_destroy :: proc(doc: ^Map_DB_Document) {
	if doc == nil do return
	for &e in doc.entities {
		delete(e.render_model.materials)
		delete(e.children)
		delete(e.asset_refs)
		delete(e.tags)
	}
	delete(doc.entities)
	delete(doc.assets)
	for &c in doc.chunks {
		delete(c.entities)
	}
	delete(doc.chunks)
	delete(doc.entity_by_index)
	doc^ = {}
}

map_db_reset :: proc(doc: ^Map_DB_Document) {
	if doc == nil do return
	for &e in doc.entities {
		delete(e.render_model.materials)
		delete(e.children)
		delete(e.asset_refs)
		delete(e.tags)
	}
	clear(&doc.entities)
	clear(&doc.assets)
	for &c in doc.chunks {
		delete(c.entities)
	}
	clear(&doc.chunks)
	clear(&doc.entity_by_index)
	doc.metadata = {}
}

// Convenience: register an asset and return its stable Asset_ID. The
// first registered asset gets Asset_ID(1) so Asset_ID(0) keeps meaning
// "invalid / unset" on the BF_ECS side. Duplicate `source` returns the
// existing Asset_ID without re-registering.
map_db_register_asset :: proc(
	doc: ^Map_DB_Document,
	source: string,
	type: Core.Asset_Type,
	name: string = "",
) -> ECS.Asset_ID {
	if doc == nil || len(source) == 0 do return Core.ASSET_INVALID
	for a, i in doc.assets {
		if a.source == source && a.type == type {
			return ECS.Asset_ID(u32(i) + 1)
		}
	}
	id := ECS.Asset_ID(u32(len(doc.assets)) + 1)
	append(&doc.assets, Map_Asset_Entry {
		id     = id,
		type   = type,
		source = source,
		name   = name,
	})
	return id
}

map_db_find_asset :: proc(
	doc: ^Map_DB_Document,
	source: string,
	type: Core.Asset_Type,
) -> ECS.Asset_ID {
	if doc == nil || len(source) == 0 do return Core.ASSET_INVALID
	for a, i in doc.assets {
		if a.source == source && a.type == type {
			return ECS.Asset_ID(u32(i) + 1)
		}
	}
	return Core.ASSET_INVALID
}

map_db_add_entity :: proc(doc: ^Map_DB_Document, e: Map_Entity) -> int {
	if doc == nil do return -1
	idx := len(doc.entities)
	append(&doc.entities, e)
	doc.entity_by_index[e.entity_index] = idx
	return idx
}

map_db_find_entity :: proc(doc: ^Map_DB_Document, entity_index: u32) -> int {
	if doc == nil do return -1
	idx, ok := doc.entity_by_index[entity_index]
	if !ok do return -1
	return idx
}

map_db_add_chunk :: proc(doc: ^Map_DB_Document, c: Map_Chunk) -> int {
	if doc == nil do return -1
	idx := len(doc.chunks)
	append(&doc.chunks, c)
	return idx
}

map_db_find_chunk :: proc(doc: ^Map_DB_Document, id: ECS.Chunk_ID) -> int {
	if doc == nil do return -1
	for c, i in doc.chunks {
		if c.id == id do return i
	}
	return -1
}
