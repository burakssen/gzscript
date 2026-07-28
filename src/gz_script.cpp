#include "gz_script.hpp"

#include "gz_build_manager.hpp"
#include "gz_language.hpp"
#include "gz_value_codec.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/wrapped.hpp>
#include <godot_cpp/core/gdextension_interface_loader.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/templates/list.hpp>

#include <vector>

using namespace godot;

std::unordered_set<GzScript *> GzScript::scripts;

namespace
{
  struct InstanceData
  {
    Object *owner = nullptr;
    Ref<GzScript> script;
    std::shared_ptr<GzCompiledModule> module;
    void *zig_instance = nullptr;
    std::vector<Variant> retained_objects;
  };

  MethodInfo signal_method_info(const GzSignalDescriptor &signal)
  {
    MethodInfo result(StringName(gzscript::from_view(signal.name)));
    for (uint32_t i = 0; i < signal.argument_count; ++i)
    {
      const GzSignalArgumentDescriptor &argument = signal.arguments[i];
      result.arguments.push_back(PropertyInfo(
          gzscript::variant_type(argument.type),
          StringName(gzscript::from_view(argument.name))));
    }
    return result;
  }

  // Property names and indices are cached when the module loads.
  int property_index(InstanceData *data, const StringName &name)
  {
    return data->module->find_property(name);
  }

  void sync_retained_objects(InstanceData *data)
  {
    const GzScriptDescriptor *descriptor = data->module->get_descriptor();
    for (uint32_t i = 0; i < descriptor->property_count; ++i)
    {
      if (descriptor->properties[i].type != GZ_VALUE_OBJECT)
        continue;
      GzValue value{};
      if (descriptor->get_property(data->zig_instance, i, &value) !=
          GZ_STATUS_OK)
        continue;
      bool valid = false;
      Variant object = gzscript::to_variant(value, &valid);
      if (!valid)
        continue;
      Object *instance = object;
      StringName expected(gzscript::from_view(
          descriptor->properties[i].class_name));
      if (instance && !expected.is_empty() && !instance->is_class(expected))
      {
        GzValue previous{};
        previous.type = GZ_VALUE_OBJECT;
        Object *retained = data->retained_objects[i];
        previous.data.object_id = retained ? retained->get_instance_id() : 0;
        descriptor->set_property(data->zig_instance, i, &previous);
        UtilityFunctions::printerr(
            "gzscript: script assigned an incompatible object to ",
            gzscript::from_view(descriptor->properties[i].name));
        continue;
      }
      data->retained_objects[i] = object;
    }
  }

  bool migrate_editor_instance(
      InstanceData *data, const std::shared_ptr<GzCompiledModule> &next_module)
  {
    const GzScriptDescriptor *current = data->module->get_descriptor();
    const GzScriptDescriptor *next = next_module->get_descriptor();
    void *next_instance = nullptr;
    if (next->create_instance(data->owner->get_instance_id(), &next_instance) !=
        GZ_STATUS_OK)
      return false;

    for (uint32_t i = 0; i < current->property_count; ++i)
    {
      const int32_t next_index = next_module->find_property(
          StringName(gzscript::from_view(current->properties[i].name)));
      if (next_index < 0 || current->properties[i].type !=
                                next->properties[next_index].type)
        continue;
      GzValue value{};
      if (current->get_property(data->zig_instance, i, &value) != GZ_STATUS_OK ||
          next->set_property(next_instance, next_index, &value) != GZ_STATUS_OK)
      {
        next->destroy_instance(next_instance);
        return false;
      }
    }

    std::shared_ptr<GzCompiledModule> previous_module = data->module;
    void *previous_instance = data->zig_instance;
    // Keep old RefCounted exports alive until the new retention set is built.
    std::vector<Variant> previous_retained =
        std::move(data->retained_objects);
    data->module = next_module;
    data->zig_instance = next_instance;
    data->retained_objects.resize(next->property_count);
    sync_retained_objects(data);
    previous_module->get_descriptor()->destroy_instance(previous_instance);
    return true;
  }

  GDExtensionBool instance_set(void *pointer, GDExtensionConstStringNamePtr name,
                               GDExtensionConstVariantPtr value)
  {
    auto *data = static_cast<InstanceData *>(pointer);
    int index = property_index(data, *reinterpret_cast<const StringName *>(name));
    if (index < 0)
      return false;
    const Variant &incoming = *reinterpret_cast<const Variant *>(value);
    const GzPropertyDescriptor &property =
        data->module->get_descriptor()->properties[index];
    if (property.type == GZ_VALUE_OBJECT && incoming.get_type() != Variant::NIL)
    {
      Object *object = incoming;
      StringName expected(gzscript::from_view(property.class_name));
      if (!object || (!expected.is_empty() && !object->is_class(expected)))
        return false;
    }
    CharString string_storage;
    bool valid = false;
    GzValue converted =
        gzscript::from_variant(incoming, &string_storage, &valid);
    if (!valid)
      return false;
    if (data->module->get_descriptor()->set_property(
            data->zig_instance, index, &converted) != GZ_STATUS_OK)
      return false;
    if (property.type == GZ_VALUE_OBJECT)
      data->retained_objects[index] = incoming;
    return true;
  }

  GDExtensionBool instance_get(void *pointer, GDExtensionConstStringNamePtr name,
                               GDExtensionVariantPtr result)
  {
    auto *data = static_cast<InstanceData *>(pointer);
    int index = property_index(data, *reinterpret_cast<const StringName *>(name));
    if (index < 0)
      return false;
    GzValue value{};
    if (data->module->get_descriptor()->get_property(data->zig_instance, index,
                                                     &value) != GZ_STATUS_OK)
      return false;
    bool valid = false;
    *reinterpret_cast<Variant *>(result) = gzscript::to_variant(value, &valid);
    return valid;
  }

  const GDExtensionPropertyInfo *instance_get_property_list(void *pointer,
                                                            uint32_t *count)
  {
    auto *data = static_cast<InstanceData *>(pointer);
    const auto &cached = data->module->get_inspector_properties();
    if (cached.empty())
    {
      *count = 0;
      return nullptr;
    }

    auto *properties = memnew(List<PropertyInfo>);
    for (const PropertyInfo &property : cached)
      properties->push_back(property);

    return internal::create_c_property_list(properties, count);
  }
  void instance_free_property_list(void *, const GDExtensionPropertyInfo *list,
                                   uint32_t)
  {
    if (list)
      internal::free_c_property_list(const_cast<GDExtensionPropertyInfo *>(list));
  }
  GDExtensionBool instance_property_can_revert(
      void *pointer, GDExtensionConstStringNamePtr name)
  {
    auto *data = static_cast<InstanceData *>(pointer);
    return property_index(data, *reinterpret_cast<const StringName *>(name)) >= 0;
  }
  GDExtensionBool instance_property_get_revert(
      void *pointer, GDExtensionConstStringNamePtr name,
      GDExtensionVariantPtr result)
  {
    auto *data = static_cast<InstanceData *>(pointer);
    const StringName &property_name =
        *reinterpret_cast<const StringName *>(name);
    if (property_index(data, property_name) < 0)
      return false;

    *reinterpret_cast<Variant *>(result) =
        data->module->get_property_defaults().get(property_name, Variant());
    return true;
  }
  GDExtensionObjectPtr instance_get_owner(void *pointer)
  {
    return static_cast<InstanceData *>(pointer)->owner->_owner;
  }
  void instance_get_property_state(void *,
                                   GDExtensionScriptInstancePropertyStateAdd,
                                   void *) {}
  const GDExtensionMethodInfo *instance_get_method_list(void *, uint32_t *count)
  {
    *count = 0;
    return nullptr;
  }
  void instance_free_method_list(void *, const GDExtensionMethodInfo *,
                                 uint32_t) {}

  GDExtensionVariantType
  instance_get_property_type(void *pointer, GDExtensionConstStringNamePtr name,
                             GDExtensionBool *valid)
  {
    auto *data = static_cast<InstanceData *>(pointer);
    int index = property_index(data, *reinterpret_cast<const StringName *>(name));
    *valid = index >= 0;
    return index >= 0
               ? static_cast<GDExtensionVariantType>(gzscript::variant_type(
                     data->module->get_descriptor()->properties[index].type))
               : GDEXTENSION_VARIANT_TYPE_NIL;
  }

  GDExtensionBool instance_has_method(void *pointer,
                                      GDExtensionConstStringNamePtr name)
  {
    auto *data = static_cast<InstanceData *>(pointer);
    StringName requested = *reinterpret_cast<const StringName *>(name);
    const GzScriptDescriptor *descriptor = data->module->get_descriptor();
    for (uint32_t i = 0; i < descriptor->method_count; ++i)
      if (StringName(gzscript::from_view(descriptor->methods[i].name)) ==
          requested)
        return true;
    return false;
  }

  GDExtensionInt instance_get_method_argument_count(
      void *pointer, GDExtensionConstStringNamePtr name, GDExtensionBool *valid)
  {
    auto *data = static_cast<InstanceData *>(pointer);
    StringName requested = *reinterpret_cast<const StringName *>(name);
    const GzScriptDescriptor *descriptor = data->module->get_descriptor();
    for (uint32_t i = 0; i < descriptor->method_count; ++i)
    {
      if (StringName(gzscript::from_view(descriptor->methods[i].name)) ==
          requested)
      {
        *valid = true;
        return descriptor->methods[i].argument_count;
      }
    }
    *valid = false;
    return 0;
  }

  void instance_call(void *pointer, GDExtensionConstStringNamePtr method,
                     const GDExtensionConstVariantPtr *arguments,
                     GDExtensionInt argument_count, GDExtensionVariantPtr result,
                     GDExtensionCallError *error)
  {
    auto *data = static_cast<InstanceData *>(pointer);
    std::vector<GzValue> values(argument_count);
    std::vector<CharString> strings(argument_count);
    for (GDExtensionInt i = 0; i < argument_count; ++i)
    {
      bool valid = false;
      values[i] = gzscript::from_variant(
          *reinterpret_cast<const Variant *>(arguments[i]), &strings[i], &valid);
      if (!valid)
      {
        error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
        error->argument = i;
        return;
      }
    }
    CharString method_name =
        String(*reinterpret_cast<const StringName *>(method)).utf8();
    GzValue return_value{};
    GzStatus status = data->module->get_descriptor()->call_method(
        data->zig_instance,
        {method_name.get_data(), static_cast<size_t>(method_name.length())},
        values.empty() ? nullptr : values.data(), argument_count, &return_value);
    sync_retained_objects(data);
    if (status == GZ_STATUS_OK)
    {
      bool valid = false;
      *reinterpret_cast<Variant *>(result) =
          gzscript::to_variant(return_value, &valid);
      if (!valid)
      {
        error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
        return;
      }
      error->error = GDEXTENSION_CALL_OK;
    }
    else
    {
      error->error = status == GZ_STATUS_METHOD_NOT_FOUND
                         ? GDEXTENSION_CALL_ERROR_INVALID_METHOD
                         : GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
    }
  }

  void instance_notification(void *pointer, int32_t what,
                             GDExtensionBool reversed)
  {
    auto *data = static_cast<InstanceData *>(pointer);
    data->module->get_descriptor()->notification(data->zig_instance, what,
                                                 reversed);
    sync_retained_objects(data);
  }

  void instance_to_string(void *, GDExtensionBool *valid,
                          GDExtensionStringPtr result)
  {
    *valid = true;
    *reinterpret_cast<String *>(result) = "<ZigScriptInstance>";
  }

  void instance_refcount_incremented(void *) {}
  GDExtensionBool instance_refcount_decremented(void *) { return true; }
  GDExtensionObjectPtr instance_get_script(void *pointer)
  {
    return static_cast<InstanceData *>(pointer)->script->_owner;
  }
  GDExtensionBool instance_is_placeholder(void *) { return false; }
  GDExtensionScriptLanguagePtr instance_get_language(void *)
  {
    return GzLanguage::get_singleton()->_owner;
  }

  void instance_free(void *pointer)
  {
    auto *data = static_cast<InstanceData *>(pointer);
    data->script->remove_instance(pointer);
    data->module->get_descriptor()->destroy_instance(data->zig_instance);
    delete data;
  }

  const GDExtensionScriptInstanceInfo3 instance_info = {
      instance_set,
      instance_get,
      instance_get_property_list,
      instance_free_property_list,
      nullptr,
      instance_property_can_revert,
      instance_property_get_revert,
      instance_get_owner,
      instance_get_property_state,
      instance_get_method_list,
      instance_free_method_list,
      instance_get_property_type,
      nullptr,
      instance_has_method,
      instance_get_method_argument_count,
      instance_call,
      instance_notification,
      instance_to_string,
      instance_refcount_incremented,
      instance_refcount_decremented,
      instance_get_script,
      instance_is_placeholder,
      instance_set,
      instance_get,
      instance_get_language,
      instance_free,
  };
} // namespace

void GzScript::_bind_methods()
{
  ClassDB::bind_method(D_METHOD("_apply_pending_refresh"),
                       &GzScript::_apply_pending_refresh);
}

GzScript::GzScript()
{
  scripts.insert(this);
}

GzScript::~GzScript()
{
  pending_refresh = false;
  pending_module.reset();
  scripts.erase(this);
}

void GzScript::_schedule_pending_refresh()
{
  if (refresh_call_scheduled || !pending_refresh || !pending_module)
    return;

  refresh_call_scheduled = true;
  call_deferred("_apply_pending_refresh");
}

void GzScript::publish_module(std::shared_ptr<GzCompiledModule> next_module)
{
  if (!next_module)
    return;

  const bool exports_changed =
      !module || !module->has_same_exports(*next_module);

  if (!Engine::get_singleton()->is_editor_hint())
  {
    module = std::move(next_module);
    valid = true;

    if (exports_changed)
      _update_exports();
    else
      emit_changed();
    return;
  }

  // Publish the script-level module and its cached export metadata immediately.
  // Existing InstanceData objects retain their own shared_ptr to the old module
  // until their state migration succeeds.
  pending_module = next_module;
  module = std::move(next_module);
  valid = true;

  if (exports_changed)
    _update_exports();
  else
    emit_changed();

  // A newer reload replaces any older pending migration. Snapshot the currently
  // live instances and migrate only those not already using the new module.
  pending_refresh_instances.clear();
  pending_refresh_instances.reserve(instances.size());
  for (void *instance : instances)
  {
    auto *data = static_cast<InstanceData *>(instance);
    if (data->module != pending_module)
      pending_refresh_instances.push_back(instance);
  }

  refresh_index = 0;
  pending_exports_changed = exports_changed;
  pending_refresh = !pending_refresh_instances.empty();

  if (!pending_refresh)
  {
    pending_module.reset();
    pending_exports_changed = false;
    return;
  }

  _schedule_pending_refresh();
}

void GzScript::_refresh_editor_instances(
    std::shared_ptr<GzCompiledModule> next_module)
{
  publish_module(std::move(next_module));
}

void GzScript::_apply_pending_refresh()
{
  // This invocation has now consumed the scheduled callback. A new callback is
  // scheduled below only when more work remains.
  refresh_call_scheduled = false;

  if (!pending_refresh || !pending_module)
    return;

  constexpr uint64_t TIME_BUDGET_USEC = 2000;
  constexpr std::size_t MIN_BATCH = 8;

  const uint64_t started_at = Time::get_singleton()->get_ticks_usec();
  std::size_t processed = 0;

  while (refresh_index < pending_refresh_instances.size())
  {
    void *instance = pending_refresh_instances[refresh_index++];

    // An instance may have been destroyed after the snapshot was taken.
    if (instances.find(instance) == instances.end())
      continue;

    auto *data = static_cast<InstanceData *>(instance);

    // A newer instance or an earlier pass may already use the latest module.
    if (data->module == pending_module)
      continue;

    Object *owner = data->owner;
    if (migrate_editor_instance(data, pending_module))
    {
      // Only a changed property schema requires an Object-side property-list
      // invalidation. Notify immediately so no raw owner pointer is retained
      // across deferred frames.
      if (pending_exports_changed && owner)
        owner->notify_property_list_changed();
    }
    else
    {
      UtilityFunctions::printerr(
          "gzscript: failed to refresh editor instance for ", get_path());
    }

    ++processed;
    if (processed >= MIN_BATCH &&
        Time::get_singleton()->get_ticks_usec() - started_at >=
            TIME_BUDGET_USEC)
    {
      break;
    }
  }

  if (refresh_index < pending_refresh_instances.size())
  {
    _schedule_pending_refresh();
    return;
  }

  pending_refresh = false;
  pending_exports_changed = false;
  pending_module.reset();
  pending_refresh_instances.clear();
  refresh_index = 0;
}

bool GzScript::_editor_can_reload_from_file() { return true; }
bool GzScript::_can_instantiate() const { return valid && module != nullptr; }
Ref<Script> GzScript::_get_base_script() const { return {}; }
StringName GzScript::_get_global_name() const { return {}; }
bool GzScript::_inherits_script(const Ref<Script> &) const { return false; }

StringName GzScript::_get_instance_base_type() const
{
  return module
             ? StringName(
                   gzscript::from_view(module->get_descriptor()->base_class))
             : StringName("Node");
}

void *GzScript::_instance_create(Object *owner) const
{
  if (!module || !owner)
    return nullptr;
  auto *data = new InstanceData;
  data->owner = owner;
  data->script = Ref<GzScript>(const_cast<GzScript *>(this));
  data->module = module;
  data->retained_objects.resize(module->get_descriptor()->property_count);
  if (module->get_descriptor()->create_instance(
          owner->get_instance_id(), &data->zig_instance) != GZ_STATUS_OK)
  {
    delete data;
    return nullptr;
  }
  sync_retained_objects(data);
  instances.insert(data);
  return gdextension_interface::script_instance_create3(&instance_info, data);
}

void *GzScript::_placeholder_instance_create(Object *owner) const
{
  if (!owner)
    return nullptr;

  void *placeholder = gdextension_interface::placeholder_script_instance_create(
      GzLanguage::get_singleton()->_owner, const_cast<GzScript *>(this)->_owner,
      owner->_owner);
  GzScript *script = const_cast<GzScript *>(this);
  script->placeholders.insert(placeholder);

  // Creating one placeholder must not update every existing placeholder.
  script->_update_placeholder(placeholder);
  return placeholder;
}

void GzScript::_placeholder_erased(void *placeholder)
{
  placeholders.erase(placeholder);
}

bool GzScript::_has_source_code() const { return true; }
String GzScript::_get_source_code() const { return source; }
void GzScript::_set_source_code(const String &code) { source = code; }

Error GzScript::_reload(bool keep_state)
{
  // Existing instances keep their module; migration needs an
  // explicit state and rollback protocol.
  (void)keep_state;
  auto next = GzBuildManager::get_singleton()->compile(get_path(), source);
  if (!next)
  {
    valid = false;
    emit_changed();
    return ERR_COMPILATION_FAILED;
  }

  publish_module(std::move(next));
  GzBuildManager::get_singleton()->emit_signal("script_compiled");
  return OK;
}

StringName GzScript::_get_doc_class_name() const { return {}; }
TypedArray<Dictionary> GzScript::_get_documentation() const { return {}; }

bool GzScript::_has_method(const StringName &method) const
{
  if (!module)
    return false;
  for (uint32_t i = 0; i < module->get_descriptor()->method_count; ++i)
    if (StringName(gzscript::from_view(
            module->get_descriptor()->methods[i].name)) == method)
      return true;
  return false;
}

bool GzScript::_has_static_method(const StringName &) const { return false; }

Variant
GzScript::_get_script_method_argument_count(const StringName &method) const
{
  if (!module)
    return Variant();
  for (uint32_t i = 0; i < module->get_descriptor()->method_count; ++i)
    if (StringName(gzscript::from_view(
            module->get_descriptor()->methods[i].name)) == method)
      return static_cast<int64_t>(
          module->get_descriptor()->methods[i].argument_count);
  return Variant();
}

Dictionary GzScript::_get_method_info(const StringName &method) const
{
  return Dictionary(MethodInfo(method));
}

bool GzScript::_is_tool() const { return false; }
bool GzScript::_is_valid() const { return valid; }
bool GzScript::_is_abstract() const { return false; }
ScriptLanguage *GzScript::_get_language() const
{
  return GzLanguage::get_singleton();
}
bool GzScript::_has_script_signal(const StringName &signal) const
{
  if (!module)
    return false;
  const GzScriptDescriptor *descriptor = module->get_descriptor();
  for (uint32_t i = 0; i < descriptor->signal_count; ++i)
    if (StringName(gzscript::from_view(descriptor->signals[i].name)) == signal)
      return true;
  return false;
}

TypedArray<Dictionary> GzScript::_get_script_signal_list() const
{
  TypedArray<Dictionary> result;
  if (!module)
    return result;
  const GzScriptDescriptor *descriptor = module->get_descriptor();
  for (uint32_t i = 0; i < descriptor->signal_count; ++i)
    result.push_back(Dictionary(signal_method_info(descriptor->signals[i])));
  return result;
}

bool GzScript::_has_property_default_value(const StringName &property) const
{
  return module && module->find_property(property) >= 0;
}

Variant
GzScript::_get_property_default_value(const StringName &property) const
{
  if (!module)
    return Variant();

  return module->get_property_defaults().get(property, Variant());
}

void GzScript::_update_placeholder(void *placeholder) const
{
  if (!placeholder || !module)
    return;

  // TypedArray and Dictionary copies are copy-on-write. Keeping local mutable
  // handles avoids relying on const _native_ptr() overloads across godot-cpp
  // versions while retaining the cached backing data.
  TypedArray<Dictionary> properties = module->get_script_property_list();
  Dictionary defaults = module->get_property_defaults();

  gdextension_interface::placeholder_script_instance_update(
      placeholder, properties._native_ptr(), defaults._native_ptr());
}

void GzScript::_update_exports()
{
  if (module)
  {
    for (void *placeholder : placeholders)
      _update_placeholder(placeholder);
  }

  emit_changed();
}

TypedArray<Dictionary> GzScript::_get_script_method_list() const
{
  TypedArray<Dictionary> result;
  if (!module)
    return result;
  for (uint32_t i = 0; i < module->get_descriptor()->method_count; ++i)
    result.push_back(Dictionary(MethodInfo(
        StringName(gzscript::from_view(
            module->get_descriptor()->methods[i].name)))));
  return result;
}

TypedArray<Dictionary> GzScript::_get_script_property_list() const
{
  return module ? module->get_script_property_list()
                : TypedArray<Dictionary>();
}

int32_t GzScript::_get_member_line(const StringName &) const { return -1; }
Dictionary GzScript::_get_constants() const { return {}; }
TypedArray<StringName> GzScript::_get_members() const { return {}; }
bool GzScript::_is_placeholder_fallback_enabled() const { return true; }
Variant GzScript::_get_rpc_config() const { return Dictionary(); }
