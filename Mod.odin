// Engine/src/Modules/BF_MapDB/Mod.odin
//
// BF_MapDB module entry point.
//
// Owns the static-map pipeline:
//
//   Blender / Anvil -> GLTF / GLB
//                          |
//                          v
//                  BF_MapDB.GLTF parser
//                          |
//                          v
//                  BF_MapDB.Importer  (GLTF -> persistent Map DB)
//                          |
//                          v
//                  BF_MapDB.BMAP     (versioned .bmap file on disk)
//                          |
//                          v
//                  runtime ECS (chunk streaming)
//
// GLTF is the interchange format; .bmap is the runtime-loadable, persistent
// map format. See Engine/src/Modules/README.md and Plans/prompt_plan.md
// items 10-12.

package BF_MapDB

import "core:log"
import "../../Core"

// === MODULE_IDENTITY (parsed by rbs) ===
IDENTITY :: Core.Lib_Descriptor {
	api_version    = Core.LIB_API_VERSION,
	name           = "BF_MapDB",
	version        = Core.Version{0, 0, 1},
	author         = "armscream",
	description    = "GLTF/GLB import, persistent Map DB conversion, versioned .bmap serialization.",
	component_kind = .Module,
	type           = .Other,
	flags          = {.Runtime, .Provides_Service},
	capabilities   = {.Custom},
	dependencies   = {
		{
			name            = "BF_ECS",
			min_version     = Core.Version{0, 0, 1},
			max_version     = Core.Version{9, 9, 9},
			has_max_version = true,
			has_min_version = true,
			optional        = false,
		},
	},
	dependency_count = 1,
}
// === END MODULE_IDENTITY ===

MODULE_API := Core.LIB_API {
	descriptor = IDENTITY,
	load       = module_load,
	register   = module_register,
	activate   = module_activate,
	deactivate = module_deactivate,
	unload     = module_unload,
}

when #config(BUILDING_BF_MAPDB_DLL, false) {
	@(export)
	bifrost_lib_get_api :: proc() -> ^Core.LIB_API {
		return &MODULE_API
	}
}

module_load :: proc(ctx: ^Core.Lib_Context) -> bool {
	_ = ctx
	context.logger = log.create_console_logger()
	log.info("[MapDB] loaded")
	return true
}

module_register :: proc(ctx: ^Core.Lib_Context) -> bool {
	_ = ctx
	log.info("[MapDB] registered (no runtime services in v1; importers + serializer are direct-call)")
	return true
}

module_activate :: proc(ctx: ^Core.Lib_Context) -> bool {
	_ = ctx
	log.info("[MapDB] active")
	return true
}

module_deactivate :: proc(ctx: ^Core.Lib_Context) {
	_ = ctx
}

module_unload :: proc(ctx: ^Core.Lib_Context) {
	_ = ctx
	log.info("[MapDB] unloaded")
}
