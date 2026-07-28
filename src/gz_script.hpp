#pragma once

#include "gz_compiled_module.hpp"

#include <godot_cpp/classes/script_extension.hpp>
#include <godot_cpp/classes/script_language.hpp>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <unordered_set>
#include <vector>

class GzScript : public godot::ScriptExtension
{
  GDCLASS(GzScript, godot::ScriptExtension)

  friend class GzBuildManager;

  godot::String source;
  std::shared_ptr<GzCompiledModule> module;
  bool valid = false;
  uint64_t compile_generation = 0;

  // The script-level module and Inspector metadata are published immediately.
  // Existing instances then migrate to pending_module incrementally.
  std::shared_ptr<GzCompiledModule> pending_module;
  bool pending_refresh = false;
  bool refresh_call_scheduled = false;
  bool pending_exports_changed = false;
  std::vector<void *> pending_refresh_instances;
  std::size_t refresh_index = 0;

  mutable std::unordered_set<void *> placeholders;
  mutable std::unordered_set<void *> instances;
  static std::unordered_set<GzScript *> scripts;

  void _update_placeholder(void *placeholder) const;
  void _schedule_pending_refresh();

protected:
  static void _bind_methods();

public:
  GzScript();
  ~GzScript();

  static const std::unordered_set<GzScript *> &get_scripts()
  {
    return scripts;
  }

  void set_source(const godot::String &code) { source = code; }
  const std::shared_ptr<GzCompiledModule> &get_module() const { return module; }
  void remove_instance(void *instance) const { instances.erase(instance); }

  void publish_module(std::shared_ptr<GzCompiledModule> next_module);
  void _refresh_editor_instances(
      std::shared_ptr<GzCompiledModule> next_module);
  void _apply_pending_refresh();

  bool _editor_can_reload_from_file() override;
  bool _can_instantiate() const override;
  godot::Ref<godot::Script> _get_base_script() const override;
  godot::StringName _get_global_name() const override;
  bool _inherits_script(const godot::Ref<godot::Script> &script) const override;
  godot::StringName _get_instance_base_type() const override;
  void *_instance_create(godot::Object *owner) const override;
  void *_placeholder_instance_create(godot::Object *owner) const override;
  void _placeholder_erased(void *placeholder) override;
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
  godot::TypedArray<godot::Dictionary>
  _get_script_signal_list() const override;
  bool _has_property_default_value(
      const godot::StringName &property) const override;
  godot::Variant _get_property_default_value(
      const godot::StringName &property) const override;
  void _update_exports() override;
  godot::TypedArray<godot::Dictionary>
  _get_script_method_list() const override;
  godot::TypedArray<godot::Dictionary>
  _get_script_property_list() const override;
  int32_t _get_member_line(const godot::StringName &member) const override;
  godot::Dictionary _get_constants() const override;
  godot::TypedArray<godot::StringName> _get_members() const override;
  bool _is_placeholder_fallback_enabled() const override;
  godot::Variant _get_rpc_config() const override;
};
