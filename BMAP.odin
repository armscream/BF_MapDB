// Engine/src/Modules/BF_MapDB/BMAP.odin
//
// .bmap on-disk format (versioned) + serializer / deserializer.
//
// Per prompt_plan items 53-62:
//   - .bmap serializes the persistent map / world representation
//     rather than the runtime renderer or GPU state.
//   - Serialize map metadata, map / chunk definitions, chunk flags /
//     state required for persistence, entity records, entity /
//     component data, asset references, relationships, and other
//     persistent map data.
//   - Serialize the relevant map database(s) and their ECS component
//     data into .bmap.
//   - Preserve ODE entity relationships such as hierarchy / ChildOf
//     when serializing maps.
//   - Do not serialize transient runtime state (GPU resource IDs,
//     renderer allocations, scheduler state, worker state, command
//     buffers, ...).
//   - Use stable asset references / IDs in .bmap, not absolute
//     filesystem paths.
//   - Make .bmap versioned so the format can evolve.
//   - Support loading a .bmap into the persistent / map representation
//     and then instantiating / loading its data into runtime ECS
//     databases.
//   - Support saving runtime-authoring changes back into .bmap.
//
// File layout (all little-endian):
//
//   +------------------------------+
//   | BMAP_Header (16 bytes)      |  magic + version + flags + section_count
//   +------------------------------+
//   | Section table               |  N * BMAP_Section_Header (12 bytes each)
//   | (id, length, flags)         |
//   +------------------------------+
//   | Section payloads...         |
//   +------------------------------+
//
// Section IDs:
//   1 STRINGS   - shared string table (UTF-8, dedup'd by index)
//   2 METADATA  - one Map_Metadata
//   3 ASSETS    - array of Map_Asset_Entry (referenced by STRING index)
//   4 CHUNKS    - array of Map_Chunk
//   5 ENTITIES  - array of Map_Entity (referenced by STRING index)
//   6 HIERARCHY - dense (parent_index, first_child, next_sibling) per entity

package BF_MapDB

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "base:runtime"
import mth "../../Core/BF_Math"
import Core "../../Core"
import ECS "../BF_ECS"

// ============================================================================
// Errors
// ============================================================================

BMAP_Error :: enum {
	None,
	IO_Error,
	Bad_Magic,
	Bad_Version,
	Unsupported_Version,
	Bad_Section,
	Truncated,
	Bad_String_Table,
	Allocation_Failed,
}

BMAP_Result :: struct {
	error:   BMAP_Error,
	message: string,
}

// ============================================================================
// Encode (little-endian)
// ============================================================================

@(private)
w_u8  :: proc(buf: ^[dynamic]u8, v: u8)  { append(buf, v) }
@(private)
w_u16 :: proc(buf: ^[dynamic]u8, v: u16) {
	append(buf, u8(v & 0xFF))
	append(buf, u8((v >> 8) & 0xFF))
}
@(private)
w_u32 :: proc(buf: ^[dynamic]u8, v: u32) {
	append(buf, u8( v        & 0xFF))
	append(buf, u8((v >>  8) & 0xFF))
	append(buf, u8((v >> 16) & 0xFF))
	append(buf, u8((v >> 24) & 0xFF))
}
@(private)
w_u64 :: proc(buf: ^[dynamic]u8, v: u64) {
	append(buf, u8( v        & 0xFF))
	append(buf, u8((v >>  8) & 0xFF))
	append(buf, u8((v >> 16) & 0xFF))
	append(buf, u8((v >> 24) & 0xFF))
	append(buf, u8((v >> 32) & 0xFF))
	append(buf, u8((v >> 40) & 0xFF))
	append(buf, u8((v >> 48) & 0xFF))
	append(buf, u8((v >> 56) & 0xFF))
}
@(private)
w_i32 :: proc(buf: ^[dynamic]u8, v: i32) { w_u32(buf, transmute(u32)v) }
@(private)
w_i64 :: proc(buf: ^[dynamic]u8, v: i64) { w_u64(buf, transmute(u64)v) }
@(private)
w_f32 :: proc(buf: ^[dynamic]u8, v: f32) {
	u := transmute(u32)mem_safe_load_u32(v)
	w_u32(buf, u)
}

// Use a small helper because raw transmute isn't always const-foldable.
@(private)
mem_safe_load_u32 :: proc(v: f32) -> u32 {
	return transmute(u32)v
}

// Read the underlying byte of a bit_set (which fits in 1-4 bytes for
// our schema). Used for serialization; the caller picks the width.
@(private)
bitset_u8 :: proc(b: $T) -> u8 {
	v := b
	return (cast(^u8)&v)^
}

// ============================================================================
// Decode (little-endian)
// ============================================================================

@(private)
r_u8  :: proc(r: ^Reader, v: ^u8)  -> bool {
	if r.pos + 1 > len(r.data) do return false
	v^ = r.data[r.pos]; r.pos += 1
	return true
}
@(private)
r_u16 :: proc(r: ^Reader, v: ^u16) -> bool {
	if r.pos + 2 > len(r.data) do return false
	b0 := u16(r.data[r.pos])
	b1 := u16(r.data[r.pos+1]) << 8
	v^ = b0 | b1
	r.pos += 2
	return true
}
@(private)
r_u32 :: proc(r: ^Reader, v: ^u32) -> bool {
	if r.pos + 4 > len(r.data) do return false
	b0 := u32(r.data[r.pos])
	b1 := u32(r.data[r.pos+1]) << 8
	b2 := u32(r.data[r.pos+2]) << 16
	b3 := u32(r.data[r.pos+3]) << 24
	v^ = b0 | b1 | b2 | b3
	r.pos += 4
	return true
}
@(private)
r_u64 :: proc(r: ^Reader, v: ^u64) -> bool {
	if r.pos + 8 > len(r.data) do return false
	b0 := u64(r.data[r.pos])
	b1 := u64(r.data[r.pos+1]) << 8
	b2 := u64(r.data[r.pos+2]) << 16
	b3 := u64(r.data[r.pos+3]) << 24
	b4 := u64(r.data[r.pos+4]) << 32
	b5 := u64(r.data[r.pos+5]) << 40
	b6 := u64(r.data[r.pos+6]) << 48
	b7 := u64(r.data[r.pos+7]) << 56
	v^ = b0 | b1 | b2 | b3 | b4 | b5 | b6 | b7
	r.pos += 8
	return true
}
@(private)
r_i32 :: proc(r: ^Reader, v: ^i32) -> bool { u: u32; if !r_u32(r, &u) do return false; v^ = transmute(i32)u; return true }
@(private)
r_i64 :: proc(r: ^Reader, v: ^i64) -> bool { u: u64; if !r_u64(r, &u) do return false; v^ = transmute(i64)u; return true }
@(private)
r_f32 :: proc(r: ^Reader, v: ^f32) -> bool { u: u32; if !r_u32(r, &u) do return false; v^ = transmute(f32)u; return true }
@(private)
r_str :: proc(r: ^Reader, allocator := context.allocator) -> (string, bool) {
	n: u32
	if !r_u32(r, &n) do return "", false
	if int(n) > len(r.data) - r.pos do return "", false
	s := strings.clone(string(r.data[r.pos:r.pos+int(n)]), allocator)
	r.pos += int(n)
	return s, true
}

// ============================================================================
// Reader / Writer helpers
// ============================================================================

Reader :: struct {
	data: []u8,
	pos:  int,
}

// ============================================================================
// Serialize
// ============================================================================

// Serializes `doc` to `path` (a .bmap file).
bmap_save_to_file :: proc(doc: ^Map_DB_Document, path: string) -> BMAP_Result {
	result: BMAP_Result
	if doc == nil || len(path) == 0 {
		result.error   = .IO_Error
		result.message = "nil doc or empty path"
		return result
	}

	buf, buf_err := bmap_save_to_bytes(doc)
	if buf_err.error != .None do return buf_err
	defer delete(buf)

	if err := os.write_entire_file(path, buf); err != nil {
		result.error   = .IO_Error
		result.message = fmt.tprintf("write_entire_file %q: %v", path, err)
		return result
	}
	return result
}

// Serializes `doc` into a freshly-allocated []byte buffer. Caller owns
// the buffer and must `delete` it.
bmap_save_to_bytes :: proc(doc: ^Map_DB_Document, allocator := context.allocator) -> ([]byte, BMAP_Result) {
	result: BMAP_Result
	if doc == nil {
		result.error   = .IO_Error
		result.message = "nil doc"
		return nil, result
	}

	context.allocator = allocator

	// Build string table first; every other section references it.
	strtab: [dynamic]string
	defer delete(strtab)
	strtab_index := make(map[string]u32, allocator)
	defer delete(strtab_index)
	bmap_string_table_build(doc, &strtab, &strtab_index)

	// Encode each section into a temporary buffer.
	meta_buf:     [dynamic]u8
	strings_buf:  [dynamic]u8
	assets_buf:   [dynamic]u8
	chunks_buf:   [dynamic]u8
	entities_buf: [dynamic]u8
	hier_buf:     [dynamic]u8
	defer {
		delete(meta_buf)
		delete(strings_buf)
		delete(assets_buf)
		delete(chunks_buf)
		delete(entities_buf)
		delete(hier_buf)
	}

	bmap_encode_metadata(doc, &strtab, &strtab_index, &meta_buf)
	bmap_encode_strings(strtab[:], &strings_buf)
	bmap_encode_assets(doc, &strtab_index, &assets_buf)
	bmap_encode_chunks(doc, &strtab_index, &chunks_buf)
	bmap_encode_entities(doc, &strtab_index, &entities_buf)
	bmap_encode_hierarchy(doc, &hier_buf)

	payloads := [][]u8 {
		meta_buf[:],
		strings_buf[:],
		assets_buf[:],
		chunks_buf[:],
		entities_buf[:],
		hier_buf[:],
	}
	section_ids := []u32 {
		BMAP_SECTION_METADATA,
		BMAP_SECTION_STRINGS,
		BMAP_SECTION_ASSETS,
		BMAP_SECTION_CHUNKS,
		BMAP_SECTION_ENTITIES,
		BMAP_SECTION_HIERARCHY,
	}

	section_table_size := i64(len(payloads)) * size_of(BMAP_Section_Header)
	payload_size: i64
	for p in payloads do payload_size += i64(len(p))
	total_size := i64(size_of(BMAP_Header)) + section_table_size + payload_size

	out, alloc_err := make([]byte, int(total_size), allocator)
	if alloc_err != nil {
		result.error   = .Allocation_Failed
		result.message = "make([]byte) failed"
		return nil, result
	}

	hdr := cast(^BMAP_Header)raw_data(out)
	hdr.magic         = BMAP_MAGIC
	hdr.version       = BMAP_VERSION
	hdr.flags         = BMAP_FLAG_LITTLE_ENDIAN
	hdr.section_count = u16(len(payloads))
	hdr.reserved      = 0

	offset := i64(size_of(BMAP_Header))
	for p, i in payloads {
		sh := cast(^BMAP_Section_Header)raw_data(out[offset:])
		sh.id     = section_ids[i]
		sh.length = u32(len(p))
		sh.flags  = 0
		offset += size_of(BMAP_Section_Header)
		copy(out[offset:], p)
		offset += i64(len(p))
	}

	return out, result
}

// ============================================================================
// Deserialize
// ============================================================================

bmap_load_from_file :: proc(doc: ^Map_DB_Document, path: string) -> BMAP_Result {
	result: BMAP_Result
	if doc == nil || len(path) == 0 {
		result.error   = .IO_Error
		result.message = "nil doc or empty path"
		return result
	}
	data, err := os.read_entire_file(path, doc.allocator)
	if err != nil {
		result.error   = .IO_Error
		result.message = fmt.tprintf("read_entire_file %q: %v", path, err)
		return result
	}
	defer delete(data, doc.allocator)
	return bmap_load_from_bytes(doc, data)
}

bmap_load_from_bytes :: proc(doc: ^Map_DB_Document, data: []byte) -> BMAP_Result {
	result: BMAP_Result
	if doc == nil {
		result.error   = .IO_Error
		result.message = "nil doc"
		return result
	}
	context.allocator = doc.allocator

	if int(len(data)) < size_of(BMAP_Header) {
		result.error   = .Truncated
		result.message = "data shorter than header"
		return result
	}
	hdr := cast(^BMAP_Header)raw_data(data)
	if hdr.magic != BMAP_MAGIC {
		result.error   = .Bad_Magic
		result.message = fmt.tprintf("bad magic %v (expected %v)", hdr.magic, BMAP_MAGIC)
		return result
	}
	if hdr.version >> 24 != BMAP_VERSION_MAJOR {
		result.error   = .Unsupported_Version
		result.message = fmt.tprintf("major version mismatch: file %d.x, this build reads %d.x",
			hdr.version >> 24, BMAP_VERSION_MAJOR)
		return result
	}
	if int(hdr.section_count) > 64 {
		result.error   = .Bad_Section
		result.message = "section count too large"
		return result
	}

	map_db_reset(doc)
	strtab: [dynamic]string
	defer {
		bmap_strtab_free(&strtab)
		delete(strtab)
	}
	strtab_index := make(map[string]u32, doc.allocator)
	defer delete(strtab_index)

	// First pass: STRINGS only (so other sections can resolve names).
	{
		offset := int(size_of(BMAP_Header))
		for _ in 0 ..< int(hdr.section_count) {
			if offset + size_of(BMAP_Section_Header) > len(data) {
				result.error = .Truncated; result.message = "section table overruns file"; return result
			}
			sh := cast(^BMAP_Section_Header)raw_data(data[offset:])
			offset += size_of(BMAP_Section_Header)
			if offset + int(sh.length) > len(data) {
				result.error = .Truncated; result.message = "section overruns file"; return result
			}
			payload := data[offset:offset + int(sh.length)]
			offset += int(sh.length)

			if sh.id == BMAP_SECTION_STRINGS {
				if !bmap_decode_strings(payload, &strtab, doc.allocator) {
					result.error = .Bad_String_Table
					result.message = "string table decode failed"
					return result
				}
			}
		}
	}

	// Second pass: everything else.
	{
		offset := int(size_of(BMAP_Header))
		for _ in 0 ..< int(hdr.section_count) {
			sh := cast(^BMAP_Section_Header)raw_data(data[offset:])
			offset += size_of(BMAP_Section_Header)
			payload := data[offset:offset + int(sh.length)]
			offset += int(sh.length)

			switch sh.id {
			case BMAP_SECTION_METADATA:
				if !bmap_decode_metadata(payload, doc, &strtab, &strtab_index) {
					result.error = .Bad_Section
					result.message = "metadata decode failed"
					return result
				}
			case BMAP_SECTION_ASSETS:
				if !bmap_decode_assets(payload, doc, &strtab, &strtab_index) {
					result.error = .Bad_Section
					result.message = "assets decode failed"
					return result
				}
			case BMAP_SECTION_CHUNKS:
				if !bmap_decode_chunks(payload, doc, &strtab, &strtab_index) {
					result.error = .Bad_Section
					result.message = "chunks decode failed"
					return result
				}
			case BMAP_SECTION_ENTITIES:
				if !bmap_decode_entities(payload, doc, &strtab, &strtab_index) {
					result.error = .Bad_Section
					result.message = "entities decode failed"
					return result
				}
			case BMAP_SECTION_HIERARCHY:
				if !bmap_decode_hierarchy(payload, doc) {
					result.error = .Bad_Section
					result.message = "hierarchy decode failed"
					return result
				}
			case BMAP_SECTION_STRINGS:
				// already processed
			case:
				// unknown sections: skip (forward-compat)
			}
		}
	}

	// Rebuild entity_by_index.
	clear(&doc.entity_by_index)
	for e, i in doc.entities {
		doc.entity_by_index[e.entity_index] = i
	}

	return result
}

// ============================================================================
// String table
// ============================================================================

@(private)
bmap_string_table_build :: proc(
	doc: ^Map_DB_Document,
	strtab: ^[dynamic]string,
	index: ^map[string]u32,
) {
	// Reserved slot 0 = "" (empty / null).
	append(strtab, "")

	add :: proc(s: string, strtab: ^[dynamic]string, index: ^map[string]u32) {
		if len(s) == 0 do return
		if _, ok := index^[s]; ok do return
		index^[s] = u32(len(strtab^))
		append(strtab, s)
	}

	add(doc.metadata.name, strtab, index)
	add(doc.metadata.source_path, strtab, index)
	add(doc.metadata.source_format, strtab, index)
	add(doc.metadata.generator, strtab, index)
	add(doc.metadata.generator_version, strtab, index)

	for a in doc.assets {
		add(a.source, strtab, index)
		add(a.name,   strtab, index)
	}
	for c in doc.chunks {
		add(c.name, strtab, index)
	}
	for e in doc.entities {
		add(e.name, strtab, index)
		if e.has_render_model {
			add(e.render_model.model_source, strtab, index)
			for m in e.render_model.materials {
				add(m, strtab, index)
			}
		}
		for t in e.tags {
			add(t, strtab, index)
		}
	}
}

@(private)
str_index_for :: proc(s: string, index: ^map[string]u32) -> u32 {
	if len(s) == 0 do return 0
	if index == nil do return 0
	if v, ok := index^[s]; ok do return v
	return 0
}

@(private)
str_lookup :: proc(strtab: ^[dynamic]string, ix: u32) -> string {
	if strtab == nil do return ""
	if int(ix) >= len(strtab^) do return ""
	return strtab^[ix]
}

// ============================================================================
// Encoders
// ============================================================================

@(private)
bmap_encode_metadata :: proc(
	doc: ^Map_DB_Document,
	_: ^[dynamic]string,
	index: ^map[string]u32,
	buf: ^[dynamic]u8,
) {
	w_u32(buf, str_index_for(doc.metadata.name,                index))
	w_u32(buf, str_index_for(doc.metadata.source_format,      index))
	w_u32(buf, str_index_for(doc.metadata.source_path,        index))
	w_u32(buf, str_index_for(doc.metadata.generator,          index))
	w_u32(buf, str_index_for(doc.metadata.generator_version,  index))
	w_i64(buf, doc.metadata.created_at_unix)
	w_u8 (buf, bitset_u8(doc.metadata.flags))
	w_f32(buf, doc.metadata.chunk_size)
}

@(private)
bmap_encode_strings :: proc(strings_slice: []string, buf: ^[dynamic]u8) {
	w_u32(buf, u32(len(strings_slice)))
	for s in strings_slice {
		w_u32(buf, u32(len(s)))
		raw := transmute([]u8)s
		append_elems(buf, ..raw)
	}
}

@(private)
bmap_encode_assets :: proc(doc: ^Map_DB_Document, index: ^map[string]u32, buf: ^[dynamic]u8) {
	w_u32(buf, u32(len(doc.assets)))
	for a in doc.assets {
		w_u32(buf, u32(a.id))
		w_u8 (buf, u8(a.type))
		w_u32(buf, str_index_for(a.source, index))
		w_u32(buf, str_index_for(a.name,   index))
	}
}

@(private)
bmap_encode_chunks :: proc(doc: ^Map_DB_Document, index: ^map[string]u32, buf: ^[dynamic]u8) {
	w_u32(buf, u32(len(doc.chunks)))
	for c in doc.chunks {
		w_u64(buf, u64(c.id))
		w_u32(buf, str_index_for(c.name, index))
		w_f32(buf, c.bounds.min.x); w_f32(buf, c.bounds.min.y); w_f32(buf, c.bounds.min.z)
		w_f32(buf, c.bounds.max.x); w_f32(buf, c.bounds.max.y); w_f32(buf, c.bounds.max.z)
		w_u8 (buf, bitset_u8(c.flags))
		w_u32(buf, u32(len(c.entities)))
		for ei in c.entities {
			w_u32(buf, ei)
		}
	}
}

@(private)
bmap_encode_entities :: proc(doc: ^Map_DB_Document, index: ^map[string]u32, buf: ^[dynamic]u8) {
	w_u32(buf, u32(len(doc.entities)))
	for e in doc.entities {
		w_u32(buf, e.entity_index)
		w_u8 (buf, u8(e.kind))
		w_u32(buf, str_index_for(e.name, index))
		// Transform
		w_u8 (buf, e.has_transform ? 1 : 0)
		if e.has_transform {
			w_f32(buf, e.transform.position.x); w_f32(buf, e.transform.position.y); w_f32(buf, e.transform.position.z)
			w_f32(buf, e.transform.rotation.x); w_f32(buf, e.transform.rotation.y); w_f32(buf, e.transform.rotation.z); w_f32(buf, e.transform.rotation.w)
			w_f32(buf, e.transform.scale.x);    w_f32(buf, e.transform.scale.y);    w_f32(buf, e.transform.scale.z)
		}
		// Render_Model
		w_u8 (buf, e.has_render_model ? 1 : 0)
		if e.has_render_model {
			w_u32(buf, str_index_for(e.render_model.model_source, index))
			w_u8 (buf, bitset_u8(e.render_model.flags))
			w_u32(buf, u32(len(e.render_model.materials)))
			for m in e.render_model.materials {
				w_u32(buf, str_index_for(m, index))
			}
		}
		// Chunk
		w_u8 (buf, e.has_chunk ? 1 : 0)
		if e.has_chunk do w_u64(buf, u64(e.chunk))
		// Bounds
		w_u8 (buf, e.has_bounds ? 1 : 0)
		if e.has_bounds {
			w_f32(buf, e.bounds.local.min.x); w_f32(buf, e.bounds.local.min.y); w_f32(buf, e.bounds.local.min.z)
			w_f32(buf, e.bounds.local.max.x); w_f32(buf, e.bounds.local.max.y); w_f32(buf, e.bounds.local.max.z)
			w_f32(buf, e.bounds.world.min.x); w_f32(buf, e.bounds.world.min.y); w_f32(buf, e.bounds.world.min.z)
			w_f32(buf, e.bounds.world.max.x); w_f32(buf, e.bounds.world.max.y); w_f32(buf, e.bounds.world.max.z)
		}
		// Spatial state
		w_u8 (buf, e.has_spatial_state ? 1 : 0)
		if e.has_spatial_state do w_u8(buf, bitset_u8(e.spatial_state.flags))
		// Asset refs
		w_u32(buf, u32(len(e.asset_refs)))
		for ar in e.asset_refs {
			w_u32(buf, u32(ar.slot))
			w_u32(buf, u32(ar.asset_id))
		}
		// Tags
		w_u32(buf, u32(len(e.tags)))
		for t in e.tags {
			w_u32(buf, str_index_for(t, index))
		}
	}
}

@(private)
bmap_encode_hierarchy :: proc(doc: ^Map_DB_Document, buf: ^[dynamic]u8) {
	parent      := make([]i32, len(doc.entities), context.allocator)
	first_child := make([]i32, len(doc.entities), context.allocator)
	next_sibling:= make([]i32, len(doc.entities), context.allocator)
	defer {
		delete(parent)
		delete(first_child)
		delete(next_sibling)
	}
	for &p in first_child do p = -1
	for &n in next_sibling do n = -1

	for e, i in doc.entities {
		parent[i] = e.parent < 0 ? -1 : i32(map_db_find_entity(doc, u32(e.parent)))
	}

	for e, i in doc.entities {
		if parent[i] < 0 do continue
		next_sibling[i] = first_child[parent[i]]
		first_child[parent[i]] = i32(i)
	}

	w_u32(buf, u32(len(doc.entities)))
	for i in 0 ..< len(doc.entities) {
		w_i32(buf, parent[i])
		w_i32(buf, first_child[i])
		w_i32(buf, next_sibling[i])
	}
}

// ============================================================================
// Decoders
// ============================================================================

@(private)
bmap_decode_strings :: proc(payload: []byte, strtab: ^[dynamic]string, allocator: runtime.Allocator) -> bool {
	r := &Reader{data = payload}
	count: u32
	if !r_u32(r, &count) do return false
	for _ in 0 ..< int(count) {
		s, ok := r_str(r, allocator)
		if !ok do return false
		append(strtab, s)
	}
	return true
}

// Free every cloned string in the strtab. Use this in callers that
// populated the strtab via bmap_decode_strings; the strtab itself is
// owned by the caller and freed via `delete(strtab^)`.
@(private)
bmap_strtab_free :: proc(strtab: ^[dynamic]string) {
	if strtab == nil do return
	for s in strtab^ {
		if len(s) > 0 do delete_string(s)
	}
}

@(private)
bmap_decode_metadata :: proc(
	payload: []byte,
	doc: ^Map_DB_Document,
	strtab: ^[dynamic]string,
	_: ^map[string]u32,
) -> bool {
	r := &Reader{data = payload}
	name_ix: u32
	src_fmt_ix: u32
	src_path_ix: u32
	gen_ix: u32
	gen_ver_ix: u32
	created_at: i64
	flags_u8: u8
	chunk_size: f32
	if !r_u32(r, &name_ix)     do return false
	if !r_u32(r, &src_fmt_ix)  do return false
	if !r_u32(r, &src_path_ix) do return false
	if !r_u32(r, &gen_ix)      do return false
	if !r_u32(r, &gen_ver_ix)  do return false
	if !r_i64(r, &created_at)  do return false
	if !r_u8 (r, &flags_u8)    do return false
	if !r_f32(r, &chunk_size)  do return false
	doc.metadata.name               = str_lookup(strtab, name_ix)
	doc.metadata.source_format     = str_lookup(strtab, src_fmt_ix)
	doc.metadata.source_path       = str_lookup(strtab, src_path_ix)
	doc.metadata.generator         = str_lookup(strtab, gen_ix)
	doc.metadata.generator_version = str_lookup(strtab, gen_ver_ix)
	doc.metadata.created_at_unix   = created_at
	doc.metadata.flags             = u8_to_bitset(flags_u8, ECS.Map_Flags)
	doc.metadata.chunk_size        = chunk_size
	return true
}

@(private)
bmap_decode_assets :: proc(
	payload: []byte,
	doc: ^Map_DB_Document,
	strtab: ^[dynamic]string,
	_: ^map[string]u32,
) -> bool {
	r := &Reader{data = payload}
	count: u32
	if !r_u32(r, &count) do return false
	for _ in 0 ..< int(count) {
		id: u32
		t:  u8
		src_ix: u32
		name_ix: u32
		if !r_u32(r, &id)      do return false
		if !r_u8 (r, &t)       do return false
		if !r_u32(r, &src_ix)  do return false
		if !r_u32(r, &name_ix) do return false
		append(&doc.assets, Map_Asset_Entry {
			id     = ECS.Asset_ID(id),
			type   = transmute(Core.Asset_Type)t,
			source = str_lookup(strtab, src_ix),
			name   = str_lookup(strtab, name_ix),
		})
	}
	return true
}

@(private)
bmap_decode_chunks :: proc(
	payload: []byte,
	doc: ^Map_DB_Document,
	strtab: ^[dynamic]string,
	_: ^map[string]u32,
) -> bool {
	r := &Reader{data = payload}
	count: u32
	if !r_u32(r, &count) do return false
	for _ in 0 ..< int(count) {
		id_raw: u64
		name_ix: u32
		min_x, min_y, min_z: f32
		max_x, max_y, max_z: f32
		flags_u8: u8
		ec: u32
		if !r_u64(r, &id_raw)        do return false
		if !r_u32(r, &name_ix)       do return false
		if !r_f32(r, &min_x)         do return false
		if !r_f32(r, &min_y)         do return false
		if !r_f32(r, &min_z)         do return false
		if !r_f32(r, &max_x)         do return false
		if !r_f32(r, &max_y)         do return false
		if !r_f32(r, &max_z)         do return false
		if !r_u8 (r, &flags_u8)      do return false
		if !r_u32(r, &ec)            do return false
		c := Map_Chunk {
			id     = ECS.Chunk_ID(id_raw),
			name   = str_lookup(strtab, name_ix),
			bounds = mth.AABB{
				min = {min_x, min_y, min_z},
				max = {max_x, max_y, max_z},
			},
			flags = u8_to_bitset(flags_u8, ECS.Chunk_Flags),
		}
		for _ in 0 ..< int(ec) {
			ei: u32
			if !r_u32(r, &ei) do return false
			append(&c.entities, ei)
		}
		append(&doc.chunks, c)
	}
	return true
}

@(private)
bmap_decode_entities :: proc(
	payload: []byte,
	doc: ^Map_DB_Document,
	strtab: ^[dynamic]string,
	_: ^map[string]u32,
) -> bool {
	r := &Reader{data = payload}
	count: u32
	if !r_u32(r, &count) do return false
	for _ in 0 ..< int(count) {
		e: Map_Entity
		e_ix: u32
		kind: u8
		name_ix: u32
		if !r_u32(r, &e_ix)    do return false
		if !r_u8 (r, &kind)    do return false
		if !r_u32(r, &name_ix) do return false
		e.entity_index = e_ix
		e.kind         = transmute(Map_Entity_Kind)kind
		e.name         = str_lookup(strtab, name_ix)

		// Transform
		has_t: u8
		if !r_u8(r, &has_t) do return false
		if has_t != 0 {
			e.has_transform = true
			if !r_f32(r, &e.transform.position.x) do return false
			if !r_f32(r, &e.transform.position.y) do return false
			if !r_f32(r, &e.transform.position.z) do return false
			if !r_f32(r, &e.transform.rotation.x) do return false
			if !r_f32(r, &e.transform.rotation.y) do return false
			if !r_f32(r, &e.transform.rotation.z) do return false
			if !r_f32(r, &e.transform.rotation.w) do return false
			if !r_f32(r, &e.transform.scale.x)    do return false
			if !r_f32(r, &e.transform.scale.y)    do return false
			if !r_f32(r, &e.transform.scale.z)    do return false
		}
		// Render_Model
		has_rm: u8
		if !r_u8(r, &has_rm) do return false
		if has_rm != 0 {
			e.has_render_model = true
			ms_ix: u32
			flags_u8: u8
			matc: u32
			if !r_u32(r, &ms_ix)     do return false
			if !r_u8 (r, &flags_u8)  do return false
			if !r_u32(r, &matc)      do return false
			e.render_model.model_source = str_lookup(strtab, ms_ix)
			e.render_model.flags        = u8_to_bitset(flags_u8, ECS.Render_Instance_Flags)
			for _ in 0 ..< int(matc) {
				m_ix: u32
				if !r_u32(r, &m_ix) do return false
				append(&e.render_model.materials, str_lookup(strtab, m_ix))
			}
		}
		// Chunk
		has_c: u8
		if !r_u8(r, &has_c) do return false
		if has_c != 0 {
			e.has_chunk = true
			c_raw: u64
			if !r_u64(r, &c_raw) do return false
			e.chunk = ECS.Chunk_ID(c_raw)
		}
		// Bounds
		has_b: u8
		if !r_u8(r, &has_b) do return false
		if has_b != 0 {
			e.has_bounds = true
			if !r_f32(r, &e.bounds.local.min.x)  do return false
			if !r_f32(r, &e.bounds.local.min.y)  do return false
			if !r_f32(r, &e.bounds.local.min.z)  do return false
			if !r_f32(r, &e.bounds.local.max.x)  do return false
			if !r_f32(r, &e.bounds.local.max.y)  do return false
			if !r_f32(r, &e.bounds.local.max.z)  do return false
			if !r_f32(r, &e.bounds.world.min.x)  do return false
			if !r_f32(r, &e.bounds.world.min.y)  do return false
			if !r_f32(r, &e.bounds.world.min.z)  do return false
			if !r_f32(r, &e.bounds.world.max.x)  do return false
			if !r_f32(r, &e.bounds.world.max.y)  do return false
			if !r_f32(r, &e.bounds.world.max.z)  do return false
		}
		// Spatial state
		has_s: u8
		if !r_u8(r, &has_s) do return false
		if has_s != 0 {
			e.has_spatial_state = true
			flags_u8: u8
			if !r_u8(r, &flags_u8) do return false
			e.spatial_state.flags = u8_to_bitset(flags_u8, ECS.Spatial_Flags)
		}
		// Asset refs
		arc: u32
		if !r_u32(r, &arc) do return false
		for _ in 0 ..< int(arc) {
			slot: u32
			aid:  u32
			if !r_u32(r, &slot) do return false
			if !r_u32(r, &aid)  do return false
			append(&e.asset_refs, Map_Asset_Ref {
				slot     = u16(slot),
				asset_id = ECS.Asset_ID(aid),
			})
		}
		// Tags
		tagc: u32
		if !r_u32(r, &tagc) do return false
		for _ in 0 ..< int(tagc) {
			t_ix: u32
			if !r_u32(r, &t_ix) do return false
			append(&e.tags, str_lookup(strtab, t_ix))
		}
		append(&doc.entities, e)
	}
	return true
}

@(private)
bmap_decode_hierarchy :: proc(payload: []byte, doc: ^Map_DB_Document) -> bool {
	r := &Reader{data = payload}
	count: u32
	if !r_u32(r, &count) do return false
	if int(count) != len(doc.entities) do return false

	parents      := make([]i32, count, context.allocator)
	first_child  := make([]i32, count, context.allocator)
	next_sibling := make([]i32, count, context.allocator)
	defer {
		delete(parents)
		delete(first_child)
		delete(next_sibling)
	}

	for i in 0 ..< int(count) {
		if !r_i32(r, &parents[i])      do return false
		if !r_i32(r, &first_child[i])  do return false
		if !r_i32(r, &next_sibling[i]) do return false
	}

	for i in 0 ..< int(count) {
		doc.entities[i].parent = int(parents[i])
	}
	for slot in 0 ..< int(count) {
		child := first_child[slot]
		for child >= 0 {
			append(&doc.entities[slot].children, int(child))
			child = next_sibling[child]
		}
	}
	return true
}

// Restore a bit_set from a single byte by writing into a fresh local.
@(private)
u8_to_bitset :: proc(b: u8, $T: typeid) -> T {
	out: T
	(cast(^u8)&out)^ = b
	return out
}
