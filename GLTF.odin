// Engine/src/Modules/BF_MapDB/GLTF.odin
//
// Thin re-export of the shared `gltf` dependency package. All GLTF /
// GLB parsing now lives at Engine/src/dependencies/gltf so the asset
// converter tool (Engine/src/Tools/asset_converter) can share the
// same representation. See Plans/prompt_plan.md item 9.

package BF_MapDB

import gltf "../../dependencies/gltf"

GLB_Magic          :: gltf.GLB_Magic
GLB_Version        :: gltf.GLB_Version
GLB_Header_Size    :: gltf.GLB_Header_Size
GLB_Header         :: gltf.GLB_Header
GLTF_Source_Format :: gltf.GLTF_Source_Format
GLTF_Document      :: gltf.GLTF_Document
GLTF_Component_Type :: gltf.GLTF_Component_Type
GLTF_Type          :: gltf.GLTF_Type
GLTF_Primitive_Mode :: gltf.GLTF_Primitive_Mode
GLTF_Accessor      :: gltf.GLTF_Accessor
GLTF_Buffer_View   :: gltf.GLTF_Buffer_View
GLTF_Buffer        :: gltf.GLTF_Buffer
GLTF_Image         :: gltf.GLTF_Image
GLTF_Sampler       :: gltf.GLTF_Sampler
GLTF_Texture       :: gltf.GLTF_Texture
GLTF_Material_PBR  :: gltf.GLTF_Material_PBR
GLTF_Material      :: gltf.GLTF_Material
GLTF_Primitive_Attribute :: gltf.GLTF_Primitive_Attribute
GLTF_Primitive     :: gltf.GLTF_Primitive
GLTF_Mesh          :: gltf.GLTF_Mesh
GLTF_Node          :: gltf.GLTF_Node
GLTF_Scene         :: gltf.GLTF_Scene
GLTF_Asset_Info    :: gltf.GLTF_Asset_Info
GLTF_Animation     :: gltf.GLTF_Animation
GLTF_Animation_Sampler :: gltf.GLTF_Animation_Sampler
GLTF_Animation_Channel  :: gltf.GLTF_Animation_Channel
GLTF_Animation_Path     :: gltf.GLTF_Animation_Path
GLTF_Animation_Interpolation :: gltf.GLTF_Animation_Interpolation

GLTF_Parse_Error   :: gltf.GLTF_Parse_Error
GLTF_Parse_Result  :: gltf.GLTF_Parse_Result

gltf_document_init    :: proc { gltf.gltf_document_init }
gltf_document_destroy :: proc { gltf.gltf_document_destroy }
gltf_parse_bytes      :: proc { gltf.gltf_parse_bytes }
gltf_parse_file       :: proc { gltf.gltf_parse_file }
gltf_detect_format    :: proc { gltf.gltf_detect_format }
gltf_accessor_bytes   :: proc { gltf.gltf_accessor_bytes }
gltf_accessor_component_size :: proc { gltf.gltf_accessor_component_size }
gltf_find_attribute    :: proc { gltf.gltf_find_attribute }
gltf_document_log_summary :: proc { gltf.gltf_document_log_summary }
