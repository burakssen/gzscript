#include "gz_script.hpp"

#include "gz_build_manager.hpp"
#include "gz_language.hpp"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/wrapped.hpp>
#include <godot_cpp/core/gdextension_interface_loader.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/templates/list.hpp>

#include <string>
#include <vector>

using namespace godot;

std::unordered_set<GzScript *> GzScript::scripts;

namespace {
struct InstanceData {
  Object *owner = nullptr;
  Ref<GzScript> script;
  std::shared_ptr<GzCompiledModule> module;
  void *zig_instance = nullptr;
};

String view_string(GzStringView value) {
  return String::utf8(value.ptr, static_cast<int64_t>(value.len));
}

Variant value_variant(const GzValue &value) {
  switch (value.type) {
  case GZ_VALUE_BOOL:
    return value.data.boolean;
  case GZ_VALUE_INT:
    return value.data.integer;
  case GZ_VALUE_FLOAT:
    return value.data.floating;
  case GZ_VALUE_STRING:
    return view_string(value.data.string);
  case GZ_VALUE_VECTOR2:
    return Vector2(value.data.vector2.x, value.data.vector2.y);
  case GZ_VALUE_OBJECT:
    return ObjectDB::get_instance(value.data.object_id);
  default:
    return Variant();
  }
}

GzValue variant_value(const Variant &value,
                      CharString *string_storage = nullptr) {
  GzValue result{};
  switch (value.get_type()) {
  case Variant::BOOL:
    result.type = GZ_VALUE_BOOL;
    result.data.boolean = value;
    break;
  case Variant::INT:
    result.type = GZ_VALUE_INT;
    result.data.integer = value;
    break;
  case Variant::FLOAT:
    result.type = GZ_VALUE_FLOAT;
    result.data.floating = value;
    break;
  case Variant::STRING:
    if (string_storage) {
      *string_storage = String(value).utf8();
      result.type = GZ_VALUE_STRING;
      result.data.string = {string_storage->get_data(),
                            static_cast<size_t>(string_storage->length())};
    }
    break;
  case Variant::VECTOR2: {
    Vector2 vector = value;
    result.type = GZ_VALUE_VECTOR2;
    result.data.vector2 = {vector.x, vector.y};
    break;
  }
  case Variant::OBJECT: {
    Object *object = value;
    result.type = GZ_VALUE_OBJECT;
    result.data.object_id = object ? object->get_instance_id() : 0;
    break;
  }
  default:
    result.type = GZ_VALUE_NIL;
  }
  return result;
}

Variant::Type variant_type(uint32_t type) {
  switch (type) {
  case GZ_VALUE_BOOL:
    return Variant::BOOL;
  case GZ_VALUE_INT:
    return Variant::INT;
  case GZ_VALUE_FLOAT:
    return Variant::FLOAT;
  case GZ_VALUE_STRING:
    return Variant::STRING;
  case GZ_VALUE_VECTOR2:
    return Variant::VECTOR2;
  case GZ_VALUE_OBJECT:
    return Variant::OBJECT;
  default:
    return Variant::NIL;
  }
}

void append_properties(List<PropertyInfo> &result,
                       const GzScriptDescriptor *descriptor) {
  for (uint32_t i = 0; i < descriptor->property_count; ++i) {
    const GzPropertyDescriptor &property = descriptor->properties[i];
    if (property.category.len > 0)
      result.push_back(
          PropertyInfo(Variant::NIL, StringName(view_string(property.category)),
                       PROPERTY_HINT_NONE, "", PROPERTY_USAGE_CATEGORY));
    String hint = property.hint == GZ_PROPERTY_HINT_RANGE
                      ? String::num(property.range_min) + "," +
                            String::num(property.range_max) + "," +
                            String::num(property.range_step)
                      : String();
    result.push_back(PropertyInfo(
        variant_type(property.type), StringName(view_string(property.name)),
        property.hint == GZ_PROPERTY_HINT_RANGE ? PROPERTY_HINT_RANGE
                                                : PROPERTY_HINT_NONE,
        hint));
  }
}

int property_index(InstanceData *data, const StringName &name) {
  const GzScriptDescriptor *descriptor = data->module->get_descriptor();
  for (uint32_t i = 0; i < descriptor->property_count; ++i) {
    if (StringName(view_string(descriptor->properties[i].name)) == name)
      return i;
  }
  return -1;
}

GDExtensionBool instance_set(void *pointer, GDExtensionConstStringNamePtr name,
                             GDExtensionConstVariantPtr value) {
  auto *data = static_cast<InstanceData *>(pointer);
  int index = property_index(data, *reinterpret_cast<const StringName *>(name));
  if (index < 0)
    return false;
  CharString string_storage;
  GzValue converted =
      variant_value(*reinterpret_cast<const Variant *>(value), &string_storage);
  return data->module->get_descriptor()->set_property(
             data->zig_instance, index, &converted) == GZ_STATUS_OK;
}

GDExtensionBool instance_get(void *pointer, GDExtensionConstStringNamePtr name,
                             GDExtensionVariantPtr result) {
  auto *data = static_cast<InstanceData *>(pointer);
  int index = property_index(data, *reinterpret_cast<const StringName *>(name));
  if (index < 0)
    return false;
  GzValue value{};
  if (data->module->get_descriptor()->get_property(data->zig_instance, index,
                                                   &value) != GZ_STATUS_OK)
    return false;
  *reinterpret_cast<Variant *>(result) = value_variant(value);
  return true;
}

const GDExtensionPropertyInfo *instance_get_property_list(void *pointer,
                                                          uint32_t *count) {
  auto *data = static_cast<InstanceData *>(pointer);
  auto *properties = memnew(List<PropertyInfo>);
  append_properties(*properties, data->module->get_descriptor());
  if (properties->is_empty()) {
    memdelete(properties);
    *count = 0;
    return nullptr;
  }
  return internal::create_c_property_list(properties, count);
}
void instance_free_property_list(void *, const GDExtensionPropertyInfo *list,
                                 uint32_t) {
  if (list)
    internal::free_c_property_list(const_cast<GDExtensionPropertyInfo *>(list));
}
GDExtensionBool instance_property_can_revert(void *,
                                             GDExtensionConstStringNamePtr) {
  return false;
}
GDExtensionBool instance_property_get_revert(void *,
                                             GDExtensionConstStringNamePtr,
                                             GDExtensionVariantPtr) {
  return false;
}
GDExtensionObjectPtr instance_get_owner(void *pointer) {
  return static_cast<InstanceData *>(pointer)->owner->_owner;
}
void instance_get_property_state(void *,
                                 GDExtensionScriptInstancePropertyStateAdd,
                                 void *) {}
const GDExtensionMethodInfo *instance_get_method_list(void *, uint32_t *count) {
  *count = 0;
  return nullptr;
}
void instance_free_method_list(void *, const GDExtensionMethodInfo *,
                               uint32_t) {}

GDExtensionVariantType
instance_get_property_type(void *pointer, GDExtensionConstStringNamePtr name,
                           GDExtensionBool *valid) {
  auto *data = static_cast<InstanceData *>(pointer);
  int index = property_index(data, *reinterpret_cast<const StringName *>(name));
  *valid = index >= 0;
  return index >= 0
             ? static_cast<GDExtensionVariantType>(variant_type(
                   data->module->get_descriptor()->properties[index].type))
             : GDEXTENSION_VARIANT_TYPE_NIL;
}

GDExtensionBool instance_has_method(void *pointer,
                                    GDExtensionConstStringNamePtr name) {
  auto *data = static_cast<InstanceData *>(pointer);
  StringName requested = *reinterpret_cast<const StringName *>(name);
  const GzScriptDescriptor *descriptor = data->module->get_descriptor();
  for (uint32_t i = 0; i < descriptor->method_count; ++i)
    if (StringName(view_string(descriptor->methods[i].name)) == requested)
      return true;
  return false;
}

GDExtensionInt instance_get_method_argument_count(
    void *pointer, GDExtensionConstStringNamePtr name, GDExtensionBool *valid) {
  auto *data = static_cast<InstanceData *>(pointer);
  StringName requested = *reinterpret_cast<const StringName *>(name);
  const GzScriptDescriptor *descriptor = data->module->get_descriptor();
  for (uint32_t i = 0; i < descriptor->method_count; ++i) {
    if (StringName(view_string(descriptor->methods[i].name)) == requested) {
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
                   GDExtensionCallError *error) {
  auto *data = static_cast<InstanceData *>(pointer);
  std::vector<GzValue> values(argument_count);
  std::vector<CharString> strings(argument_count);
  for (GDExtensionInt i = 0; i < argument_count; ++i)
    values[i] = variant_value(*reinterpret_cast<const Variant *>(arguments[i]),
                              &strings[i]);
  CharString method_name =
      String(*reinterpret_cast<const StringName *>(method)).utf8();
  GzValue return_value{};
  GzStatus status = data->module->get_descriptor()->call_method(
      data->zig_instance,
      {method_name.get_data(), static_cast<size_t>(method_name.length())},
      values.empty() ? nullptr : values.data(), argument_count, &return_value);
  if (status == GZ_STATUS_OK) {
    *reinterpret_cast<Variant *>(result) = value_variant(return_value);
    error->error = GDEXTENSION_CALL_OK;
  } else {
    error->error = status == GZ_STATUS_METHOD_NOT_FOUND
                       ? GDEXTENSION_CALL_ERROR_INVALID_METHOD
                       : GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
  }
}

void instance_notification(void *pointer, int32_t what,
                           GDExtensionBool reversed) {
  auto *data = static_cast<InstanceData *>(pointer);
  data->module->get_descriptor()->notification(data->zig_instance, what,
                                               reversed);
}

void instance_to_string(void *, GDExtensionBool *valid,
                        GDExtensionStringPtr result) {
  *valid = true;
  *reinterpret_cast<String *>(result) = "<ZigScriptInstance>";
}

void instance_refcount_incremented(void *) {}
GDExtensionBool instance_refcount_decremented(void *) { return true; }
GDExtensionObjectPtr instance_get_script(void *pointer) {
  return static_cast<InstanceData *>(pointer)->script->_owner;
}
GDExtensionBool instance_is_placeholder(void *) { return false; }
GDExtensionScriptLanguagePtr instance_get_language(void *) {
  return GzLanguage::get_singleton()->_owner;
}

void instance_free(void *pointer) {
  auto *data = static_cast<InstanceData *>(pointer);
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

void GzScript::_bind_methods() {}
GzScript::GzScript() { scripts.insert(this); }
GzScript::~GzScript() { scripts.erase(this); }
bool GzScript::_editor_can_reload_from_file() { return true; }
bool GzScript::_can_instantiate() const { return valid && module != nullptr; }
Ref<Script> GzScript::_get_base_script() const { return {}; }
StringName GzScript::_get_global_name() const { return {}; }
bool GzScript::_inherits_script(const Ref<Script> &) const { return false; }

StringName GzScript::_get_instance_base_type() const {
  return module ? StringName(view_string(module->get_descriptor()->base_class))
                : StringName("Node");
}

void *GzScript::_instance_create(Object *owner) const {
  if (!module || !owner)
    return nullptr;
  auto *data = new InstanceData;
  data->owner = owner;
  data->script = Ref<GzScript>(const_cast<GzScript *>(this));
  data->module = module;
  if (module->get_descriptor()->create_instance(
          owner->get_instance_id(), &data->zig_instance) != GZ_STATUS_OK) {
    delete data;
    return nullptr;
  }
  return gdextension_interface::script_instance_create3(&instance_info, data);
}

void *GzScript::_placeholder_instance_create(Object *owner) const {
  void *placeholder = gdextension_interface::placeholder_script_instance_create(
      GzLanguage::get_singleton()->_owner, const_cast<GzScript *>(this)->_owner,
      owner->_owner);
  GzScript *script = const_cast<GzScript *>(this);
  script->placeholders.insert(placeholder);
  script->_update_exports();
  return placeholder;
}

void GzScript::_placeholder_erased(void *placeholder) {
  placeholders.erase(placeholder);
}

bool GzScript::_has_source_code() const { return true; }
String GzScript::_get_source_code() const { return source; }
void GzScript::_set_source_code(const String &code) { source = code; }

Error GzScript::_reload(bool) {
  auto next = GzBuildManager::get_singleton()->compile(get_path(), source);
  if (!next) {
    valid = false;
    emit_changed();
    return ERR_COMPILATION_FAILED;
  }
  module = std::move(next);
  valid = true;
  _update_exports();
  return OK;
}

StringName GzScript::_get_doc_class_name() const { return {}; }
TypedArray<Dictionary> GzScript::_get_documentation() const { return {}; }

bool GzScript::_has_method(const StringName &method) const {
  if (!module)
    return false;
  for (uint32_t i = 0; i < module->get_descriptor()->method_count; ++i)
    if (StringName(view_string(module->get_descriptor()->methods[i].name)) ==
        method)
      return true;
  return false;
}

bool GzScript::_has_static_method(const StringName &) const { return false; }

Variant
GzScript::_get_script_method_argument_count(const StringName &method) const {
  if (!module)
    return Variant();
  for (uint32_t i = 0; i < module->get_descriptor()->method_count; ++i)
    if (StringName(view_string(module->get_descriptor()->methods[i].name)) ==
        method)
      return static_cast<int64_t>(
          module->get_descriptor()->methods[i].argument_count);
  return Variant();
}

Dictionary GzScript::_get_method_info(const StringName &method) const {
  return Dictionary(MethodInfo(method));
}

bool GzScript::_is_tool() const { return false; }
bool GzScript::_is_valid() const { return valid; }
bool GzScript::_is_abstract() const { return false; }
ScriptLanguage *GzScript::_get_language() const {
  return GzLanguage::get_singleton();
}
bool GzScript::_has_script_signal(const StringName &) const { return false; }
TypedArray<Dictionary> GzScript::_get_script_signal_list() const { return {}; }

bool GzScript::_has_property_default_value(const StringName &property) const {
  if (!module)
    return false;
  for (uint32_t i = 0; i < module->get_descriptor()->property_count; ++i)
    if (StringName(view_string(module->get_descriptor()->properties[i].name)) ==
        property)
      return true;
  return false;
}

Variant
GzScript::_get_property_default_value(const StringName &property) const {
  if (!module)
    return Variant();
  for (uint32_t i = 0; i < module->get_descriptor()->property_count; ++i)
    if (StringName(view_string(module->get_descriptor()->properties[i].name)) ==
        property)
      return value_variant(
          module->get_descriptor()->properties[i].default_value);
  return Variant();
}

void GzScript::_update_exports() {
  TypedArray<Dictionary> properties = _get_script_property_list();
  Dictionary defaults;
  if (module) {
    const GzScriptDescriptor *descriptor = module->get_descriptor();
    for (uint32_t i = 0; i < descriptor->property_count; ++i) {
      const GzPropertyDescriptor &property = descriptor->properties[i];
      defaults[StringName(view_string(property.name))] =
          value_variant(property.default_value);
    }
  }
  for (void *placeholder : placeholders)
    gdextension_interface::placeholder_script_instance_update(
        placeholder, properties._native_ptr(), defaults._native_ptr());
  emit_changed();
}

TypedArray<Dictionary> GzScript::_get_script_method_list() const {
  TypedArray<Dictionary> result;
  if (!module)
    return result;
  for (uint32_t i = 0; i < module->get_descriptor()->method_count; ++i)
    result.push_back(Dictionary(MethodInfo(
        StringName(view_string(module->get_descriptor()->methods[i].name)))));
  return result;
}

TypedArray<Dictionary> GzScript::_get_script_property_list() const {
  TypedArray<Dictionary> result;
  if (!module)
    return result;
  List<PropertyInfo> properties;
  append_properties(properties, module->get_descriptor());
  for (const PropertyInfo &property : properties)
    result.push_back(Dictionary(property));
  return result;
}

int32_t GzScript::_get_member_line(const StringName &) const { return -1; }
Dictionary GzScript::_get_constants() const { return {}; }
TypedArray<StringName> GzScript::_get_members() const { return {}; }
bool GzScript::_is_placeholder_fallback_enabled() const { return true; }
Variant GzScript::_get_rpc_config() const { return Dictionary(); }
