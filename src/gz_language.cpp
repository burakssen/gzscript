#include "gz_language.hpp"

#include "gz_script.hpp"

#include <godot_cpp/core/memory.hpp>

using namespace godot;

GzLanguage *GzLanguage::singleton = nullptr;

void GzLanguage::_bind_methods() {}

GzLanguage::GzLanguage() { singleton = this; }
GzLanguage::~GzLanguage() {
  if (singleton == this)
    singleton = nullptr;
}

String GzLanguage::_get_name() const { return "Zig"; }
void GzLanguage::_init() {}
String GzLanguage::_get_type() const { return "ZigScript"; }
String GzLanguage::_get_extension() const { return "zig"; }
void GzLanguage::_finish() {}

PackedStringArray GzLanguage::_get_reserved_words() const {
  PackedStringArray words;
  for (const char *word : {"const", "var", "fn", "pub", "struct", "enum",
                           "union", "if", "else", "while", "for", "return",
                           "comptime", "try", "catch", "defer", "switch"})
    words.push_back(word);
  return words;
}

bool GzLanguage::_is_control_flow_keyword(const String &keyword) const {
  return keyword == "if" || keyword == "else" || keyword == "while" ||
         keyword == "for" || keyword == "return" || keyword == "switch";
}

PackedStringArray GzLanguage::_get_comment_delimiters() const {
  return PackedStringArray({"//", "/* */"});
}
PackedStringArray GzLanguage::_get_string_delimiters() const {
  return PackedStringArray({"\" \""});
}

Ref<Script> GzLanguage::_make_template(const String &, const String &,
                                       const String &base_class_name) const {
  Ref<GzScript> script;
  script.instantiate();
  String base = base_class_name.is_empty() ? "Node" : base_class_name;
  script->set_source("const gd = @import(\"godot\");\n\n"
                     "pub const Base = gd." +
                     base +
                     ";\n"
                     "const Self = @This();\n\n"
                     "base: Base,\n\n"
                     "pub fn init(ctx: gd.InitContext) !Self {\n"
                     "    return .{ .base = .{ .owner = ctx.owner } };\n"
                     "}\n\n"
                     "pub fn _ready(self: *Self) !void {\n"
                     "    _ = self;\n"
                     "}\n");
  return script;
}

TypedArray<Dictionary>
GzLanguage::_get_built_in_templates(const StringName &object) const {
  Dictionary item;
  item["inherit"] = object;
  item["name"] = "Default";
  item["description"] = "Basic Zig script";
  item["content"] = "";
  item["id"] = 0;
  item["origin"] = 0;
  TypedArray<Dictionary> result;
  result.push_back(item);
  return result;
}

bool GzLanguage::_is_using_templates() { return true; }

Dictionary GzLanguage::_validate(const String &, const String &, bool, bool,
                                 bool, bool) const {
  Dictionary result;
  result["valid"] = true;
  return result;
}

String GzLanguage::_validate_path(const String &path) const {
  return path.get_extension() == "zig"
             ? String()
             : "Zig scripts must use the .zig extension";
}
bool GzLanguage::_supports_builtin_mode() const { return false; }
bool GzLanguage::_supports_documentation() const { return false; }
bool GzLanguage::_can_inherit_from_file() const { return false; }
int32_t GzLanguage::_find_function(const String &, const String &) const {
  return -1;
}
String GzLanguage::_make_function(const String &, const String &,
                                  const PackedStringArray &) const {
  return {};
}
bool GzLanguage::_can_make_function() const { return false; }
Error GzLanguage::_open_in_external_editor(const Ref<Script> &, int32_t,
                                           int32_t) {
  return ERR_UNAVAILABLE;
}
bool GzLanguage::_overrides_external_editor() { return false; }

Dictionary GzLanguage::_complete_code(const String &, const String &,
                                      Object *) const {
  Dictionary result;
  result["result"] = ERR_UNAVAILABLE;
  result["force"] = false;
  result["call_hint"] = String();
  return result;
}

Dictionary GzLanguage::_lookup_code(const String &, const String &,
                                    const String &, Object *) const {
  Dictionary result;
  result["result"] = ERR_UNAVAILABLE;
  result["type"] = LOOKUP_RESULT_SCRIPT_LOCATION;
  return result;
}

String GzLanguage::_auto_indent_code(const String &code, int32_t,
                                     int32_t) const {
  return code;
}
void GzLanguage::_add_global_constant(const StringName &, const Variant &) {}
void GzLanguage::_add_named_global_constant(const StringName &,
                                            const Variant &) {}
void GzLanguage::_remove_named_global_constant(const StringName &) {}
void GzLanguage::_thread_enter() {}
void GzLanguage::_thread_exit() {}
String GzLanguage::_debug_get_error() const { return {}; }
int32_t GzLanguage::_debug_get_stack_level_count() const { return 0; }
int32_t GzLanguage::_debug_get_stack_level_line(int32_t) const { return -1; }
String GzLanguage::_debug_get_stack_level_function(int32_t) const { return {}; }
String GzLanguage::_debug_get_stack_level_source(int32_t) const { return {}; }
Dictionary GzLanguage::_debug_get_stack_level_locals(int32_t, int32_t,
                                                     int32_t) {
  return {};
}
Dictionary GzLanguage::_debug_get_stack_level_members(int32_t, int32_t,
                                                      int32_t) {
  return {};
}
void *GzLanguage::_debug_get_stack_level_instance(int32_t) { return nullptr; }
Dictionary GzLanguage::_debug_get_globals(int32_t, int32_t) { return {}; }
String GzLanguage::_debug_parse_stack_level_expression(int32_t, const String &,
                                                       int32_t, int32_t) {
  return {};
}
TypedArray<Dictionary> GzLanguage::_debug_get_current_stack_info() {
  return {};
}

void GzLanguage::_reload_all_scripts() {}

void GzLanguage::_reload_scripts(const Array &scripts, bool soft_reload) {
  for (int i = 0; i < scripts.size(); ++i) {
    Ref<Script> script = scripts[i];
    if (script.is_valid())
      script->reload(soft_reload);
  }
}

void GzLanguage::_reload_tool_script(const Ref<Script> &script,
                                     bool soft_reload) {
  if (script.is_valid())
    script->reload(soft_reload);
}
PackedStringArray GzLanguage::_get_recognized_extensions() const {
  return PackedStringArray({"zig"});
}
TypedArray<Dictionary> GzLanguage::_get_public_functions() const { return {}; }
Dictionary GzLanguage::_get_public_constants() const { return {}; }
TypedArray<Dictionary> GzLanguage::_get_public_annotations() const {
  return {};
}
void GzLanguage::_profiling_start() {}
void GzLanguage::_profiling_stop() {}
void GzLanguage::_profiling_set_save_native_calls(bool) {}
int32_t GzLanguage::_profiling_get_accumulated_data(
    ScriptLanguageExtensionProfilingInfo *, int32_t) {
  return 0;
}
int32_t
GzLanguage::_profiling_get_frame_data(ScriptLanguageExtensionProfilingInfo *,
                                      int32_t) {
  return 0;
}
void GzLanguage::_frame() {}
bool GzLanguage::_handles_global_class_type(const String &) const {
  return false;
}
Dictionary GzLanguage::_get_global_class_name(const String &) const {
  return {};
}
