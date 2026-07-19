#pragma once

#include "gz_compiled_module.hpp"

#include <godot_cpp/classes/script_extension.hpp>
#include <godot_cpp/classes/script_language.hpp>

#include <memory>
#include <unordered_set>

class GzScript : public godot::ScriptExtension {
  GDCLASS(GzScript, godot::ScriptExtension)

  godot::String source;
  std::shared_ptr<GzCompiledModule> module;
  bool valid = false;
  static std::unordered_set<GzScript *> scripts;

protected:
  static void _bind_methods();

public:
  GzScript();
  ~GzScript();
  static const std::unordered_set<GzScript *> &get_scripts() { return scripts; }
  void set_source(const godot::String &code) { source = code; }
  const std::shared_ptr<GzCompiledModule> &get_module() const { return module; }

  bool _editor_can_reload_from_file() override;
  bool _can_instantiate() const override;
  godot::Ref<godot::Script> _get_base_script() const override;
  godot::StringName _get_global_name() const override;
  bool _inherits_script(const godot::Ref<godot::Script> &script) const override;
  godot::StringName _get_instance_base_type() const override;
  void *_instance_create(godot::Object *owner) const override;
  void *_placeholder_instance_create(godot::Object *owner) const override;
  bool _has_source_code() const override;
  godot::String _get_source_code() const override;
  void _set_source_code(const godot::String &code) override;
  godot::Error _reload(bool keep_state) override;
  godot::StringName _get_doc_class_name() const override;
  godot::TypedArray<godot::Dictionary> _get_documentation() const override;
  bool _has_method(const godot::StringName &method) const override;
  bool _has_static_method(const godot::StringName &method) const override;
  godot::Variant _get_script_method_argument_count(
      const godot::StringName &method) const override;
  godot::Dictionary
  _get_method_info(const godot::StringName &method) const override;
  bool _is_tool() const override;
  bool _is_valid() const override;
  bool _is_abstract() const override;
  godot::ScriptLanguage *_get_language() const override;
  bool _has_script_signal(const godot::StringName &signal) const override;
  godot::TypedArray<godot::Dictionary> _get_script_signal_list() const override;
  bool
  _has_property_default_value(const godot::StringName &property) const override;
  godot::Variant
  _get_property_default_value(const godot::StringName &property) const override;
  void _update_exports() override;
  godot::TypedArray<godot::Dictionary> _get_script_method_list() const override;
  godot::TypedArray<godot::Dictionary>
  _get_script_property_list() const override;
  int32_t _get_member_line(const godot::StringName &member) const override;
  godot::Dictionary _get_constants() const override;
  godot::TypedArray<godot::StringName> _get_members() const override;
  bool _is_placeholder_fallback_enabled() const override;
  godot::Variant _get_rpc_config() const override;
};
