#pragma once

#include <godot_cpp/classes/script_language_extension.hpp>

class GzLanguage : public godot::ScriptLanguageExtension {
  GDCLASS(GzLanguage, godot::ScriptLanguageExtension)

  static GzLanguage *singleton;

protected:
  static void _bind_methods();

public:
  GzLanguage();
  ~GzLanguage();
  static GzLanguage *get_singleton() { return singleton; }

  godot::String _get_name() const override;
  void _init() override;
  godot::String _get_type() const override;
  godot::String _get_extension() const override;
  void _finish() override;
  godot::PackedStringArray _get_reserved_words() const override;
  bool _is_control_flow_keyword(const godot::String &keyword) const override;
  godot::PackedStringArray _get_comment_delimiters() const override;
  godot::PackedStringArray _get_string_delimiters() const override;
  godot::Ref<godot::Script>
  _make_template(const godot::String &template_name,
                 const godot::String &class_name,
                 const godot::String &base_class_name) const override;
  godot::TypedArray<godot::Dictionary>
  _get_built_in_templates(const godot::StringName &object) const override;
  bool _is_using_templates() override;
  godot::Dictionary _validate(const godot::String &script,
                              const godot::String &path,
                              bool validate_functions, bool validate_errors,
                              bool validate_warnings,
                              bool validate_safe_lines) const override;
  godot::String _validate_path(const godot::String &path) const override;
  bool _supports_builtin_mode() const override;
  bool _supports_documentation() const override;
  bool _can_inherit_from_file() const override;
  int32_t _find_function(const godot::String &function,
                         const godot::String &code) const override;
  bool _can_make_function() const override;
  godot::Dictionary _complete_code(const godot::String &code,
                                   const godot::String &path,
                                   godot::Object *owner) const override;
  godot::Dictionary _lookup_code(const godot::String &code,
                                 const godot::String &symbol,
                                 const godot::String &path,
                                 godot::Object *owner) const override;
  godot::String _auto_indent_code(const godot::String &code, int32_t from_line,
                                  int32_t to_line) const override;
  void _thread_enter() override;
  void _thread_exit() override;
  godot::Dictionary _debug_get_stack_level_locals(int32_t level,
                                                  int32_t max_subitems,
                                                  int32_t max_depth) override;
  godot::Dictionary _debug_get_stack_level_members(int32_t level,
                                                   int32_t max_subitems,
                                                   int32_t max_depth) override;
  void *_debug_get_stack_level_instance(int32_t level) override;
  godot::Dictionary _debug_get_globals(int32_t max_subitems,
                                       int32_t max_depth) override;
  godot::TypedArray<godot::Dictionary> _debug_get_current_stack_info() override;
  void _reload_all_scripts() override;
  void _reload_scripts(const godot::Array &scripts, bool soft_reload) override;
  void _reload_tool_script(const godot::Ref<godot::Script> &script,
                           bool soft_reload) override;
  godot::PackedStringArray _get_recognized_extensions() const override;
  godot::TypedArray<godot::Dictionary> _get_public_functions() const override;
  godot::Dictionary _get_public_constants() const override;
  godot::TypedArray<godot::Dictionary> _get_public_annotations() const override;
  int32_t _profiling_get_accumulated_data(
      godot::ScriptLanguageExtensionProfilingInfo *info_array,
      int32_t info_max) override;
  int32_t _profiling_get_frame_data(
      godot::ScriptLanguageExtensionProfilingInfo *info_array,
      int32_t info_max) override;
  void _frame() override;
  bool _handles_global_class_type(const godot::String &type) const override;
  godot::Dictionary
  _get_global_class_name(const godot::String &path) const override;
};
