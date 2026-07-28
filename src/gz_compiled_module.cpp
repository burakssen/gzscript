#include "gz_compiled_module.hpp"
#include "gz_value_codec.hpp"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/gdextension_interface_loader.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#ifdef WINDOWS_ENABLED
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

using namespace godot;

namespace
{
  void log_info(GzStringView message)
  {
    UtilityFunctions::print_rich(gzscript::from_view(message));
  }

  void log_error(GzStringView message)
  {
    UtilityFunctions::printerr(gzscript::from_view(message));
  }

  // Own keys because method names can originate in unloadable script modules.
  static thread_local std::unordered_map<std::string, StringName>
      method_name_cache;

  StringName get_cached_name(GzStringView view)
  {
    std::string key(view.ptr, view.len);
    auto it = method_name_cache.find(key);
    if (it != method_name_cache.end())
      return it->second;

    StringName name(gzscript::from_view(view));
    method_name_cache.emplace(std::move(key), name);
    return name;
  }

  bool string_view_equal(GzStringView lhs, GzStringView rhs)
  {
    if (lhs.len != rhs.len)
      return false;
    if (lhs.len == 0)
      return true;
    if (!lhs.ptr || !rhs.ptr)
      return false;
    return std::memcmp(lhs.ptr, rhs.ptr, lhs.len) == 0;
  }

  bool default_value_equal(const GzValue &lhs, const GzValue &rhs)
  {
    bool lhs_valid = false;
    bool rhs_valid = false;
    Variant lhs_variant = gzscript::to_variant(lhs, &lhs_valid);
    Variant rhs_variant = gzscript::to_variant(rhs, &rhs_valid);
    return lhs_valid && rhs_valid && lhs_variant == rhs_variant;
  }

  PropertyInfo inspector_property_info(
      const GzScriptDescriptor *descriptor,
      const GzInspectorEntryDescriptor &entry)
  {
    if (entry.kind != GZ_INSPECTOR_ENTRY_PROPERTY)
    {
      PropertyUsageFlags usage = PROPERTY_USAGE_NONE;
      if (entry.kind == GZ_INSPECTOR_ENTRY_CATEGORY)
        usage = PROPERTY_USAGE_CATEGORY;
      else if (entry.kind == GZ_INSPECTOR_ENTRY_GROUP)
        usage = PROPERTY_USAGE_GROUP;
      else if (entry.kind == GZ_INSPECTOR_ENTRY_SUBGROUP)
        usage = PROPERTY_USAGE_SUBGROUP;

      return PropertyInfo(
          Variant::NIL,
          StringName(gzscript::from_view(entry.name)),
          PROPERTY_HINT_NONE,
          gzscript::from_view(entry.prefix),
          usage);
    }

    const GzPropertyDescriptor &property =
        descriptor->properties[entry.property_index];
    const PropertyHint godot_hint =
        static_cast<PropertyHint>(property.hint);

    String hint_string;
    if (godot_hint == PROPERTY_HINT_RANGE)
    {
      hint_string = String::num(property.range_min) + "," +
                    String::num(property.range_max) + "," +
                    String::num(property.range_step);
    }
    else
    {
      hint_string = gzscript::from_view(property.hint_string);
    }

    return PropertyInfo(
        gzscript::variant_type(property.type),
        StringName(gzscript::from_view(property.name)),
        godot_hint,
        hint_string,
        PROPERTY_USAGE_DEFAULT,
        StringName(gzscript::from_view(property.class_name)));
  }

  GzStatus object_call(uint64_t object_id, GzStringView method,
                       const GzValue *arguments, uint32_t argument_count,
                       GzValue *result)
  {
    Object *object = ObjectDB::get_instance(object_id);
    if (!object || !result || (argument_count > 0 && !arguments))
      return GZ_STATUS_INVALID_ARGUMENT;

    // Keep common calls allocation-free.
    constexpr uint32_t STACK_LIMIT = 8;
    Variant stack_values[STACK_LIMIT];
    const Variant *stack_pointers[STACK_LIMIT];

    std::vector<Variant> heap_values;
    std::vector<const Variant *> heap_pointers;

    Variant *values_ptr = stack_values;
    const Variant **pointers_ptr = stack_pointers;

    if (argument_count > STACK_LIMIT)
    {
      heap_values.resize(argument_count);
      heap_pointers.resize(argument_count);
      values_ptr = heap_values.data();
      pointers_ptr = heap_pointers.data();
    }

    for (uint32_t i = 0; i < argument_count; ++i)
    {
      bool valid = false;
      values_ptr[i] = gzscript::to_variant(arguments[i], &valid);
      if (!valid)
        return GZ_STATUS_TYPE_MISMATCH;
      pointers_ptr[i] = &values_ptr[i];
    }

    Variant receiver = object;
    Variant call_result;
    GDExtensionCallError call_error{};
    receiver.callp(get_cached_name(method),
                   argument_count == 0 ? nullptr : pointers_ptr,
                   static_cast<int>(argument_count), call_result, call_error);

    switch (call_error.error)
    {
    case GDEXTENSION_CALL_OK:
    {
      static thread_local CharString string_storage;
      bool valid = false;
      *result = gzscript::from_variant(call_result, &string_storage, &valid);
      return valid ? GZ_STATUS_OK : GZ_STATUS_TYPE_MISMATCH;
    }
    case GDEXTENSION_CALL_ERROR_INVALID_METHOD:
      return GZ_STATUS_METHOD_NOT_FOUND;
    case GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT:
      return GZ_STATUS_TYPE_MISMATCH;
    case GDEXTENSION_CALL_ERROR_TOO_MANY_ARGUMENTS:
    case GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS:
    case GDEXTENSION_CALL_ERROR_INSTANCE_IS_NULL:
      return GZ_STATUS_INVALID_ARGUMENT;
    default:
      return GZ_STATUS_SCRIPT_ERROR;
    }
  }

  GzStatus object_emit_signal(uint64_t object_id, GzStringView signal,
                              const GzValue *arguments,
                              uint32_t argument_count)
  {
    Object *object = ObjectDB::get_instance(object_id);
    if (!object || (argument_count > 0 && !arguments))
      return GZ_STATUS_INVALID_ARGUMENT;

    std::vector<Variant> values(argument_count + 1);
    std::vector<const Variant *> pointers(argument_count + 1);
    values[0] = get_cached_name(signal);
    pointers[0] = &values[0];

    for (uint32_t i = 0; i < argument_count; ++i)
    {
      bool valid = false;
      values[i + 1] = gzscript::to_variant(arguments[i], &valid);
      if (!valid)
        return GZ_STATUS_TYPE_MISMATCH;
      pointers[i + 1] = &values[i + 1];
    }

    static GDExtensionMethodBindPtr method_bind =
        gdextension_interface::classdb_get_method_bind(
            Object::get_class_static()._native_ptr(),
            StringName("emit_signal")._native_ptr(), 4047867050);
    if (!method_bind)
      return GZ_STATUS_METHOD_NOT_FOUND;

    Variant result;
    GDExtensionCallError error{};
    gdextension_interface::object_method_bind_call(
        method_bind, object->_owner,
        reinterpret_cast<GDExtensionConstVariantPtr *>(pointers.data()),
        static_cast<GDExtensionInt>(pointers.size()), &result, &error);

    return error.error == GDEXTENSION_CALL_OK &&
                   static_cast<Error>(static_cast<int64_t>(result)) == OK
               ? GZ_STATUS_OK
               : GZ_STATUS_SCRIPT_ERROR;
  }

  void *get_method_bind(GzStringView class_name, GzStringView method_name,
                        int64_t hash)
  {
    StringName c_name(gzscript::from_view(class_name));
    StringName m_name(gzscript::from_view(method_name));

    GDExtensionMethodBindPtr method_bind =
        gdextension_interface::classdb_get_method_bind(
            c_name._native_ptr(),
            m_name._native_ptr(),
            hash);

    return const_cast<void *>(method_bind);
  }

  GzStatus object_ptrcall(void *method_bind, uint64_t object_id,
                          const void *const *arguments, void *result)
  {
    Object *object = ObjectDB::get_instance(object_id);
    if (!object || !method_bind)
      return GZ_STATUS_INVALID_ARGUMENT;

    gdextension_interface::object_method_bind_ptrcall(
        reinterpret_cast<GDExtensionMethodBindPtr>(method_bind),
        object->_owner,
        (GDExtensionConstTypePtr *)arguments,
        reinterpret_cast<GDExtensionTypePtr>(result));
    return GZ_STATUS_OK;
  }

  uint64_t get_ticks_usec()
  {
    return Time::get_singleton()->get_ticks_usec();
  }

  void close_library(void *handle)
  {
#ifdef WINDOWS_ENABLED
    FreeLibrary(reinterpret_cast<HMODULE>(handle));
#else
    dlclose(handle);
#endif
  }

  void *open_library(const String &path, String &error)
  {
#ifdef WINDOWS_ENABLED
    Char16String wide_path = path.utf16();
    HMODULE handle =
        LoadLibraryW(reinterpret_cast<const wchar_t *>(wide_path.get_data()));
    if (!handle)
    {
      error = "LoadLibraryW failed with error " +
              String::num_int64(static_cast<int64_t>(GetLastError()));
    }
    return reinterpret_cast<void *>(handle);
#else
    CharString native_path = path.utf8();
    void *handle = dlopen(native_path.get_data(), RTLD_NOW | RTLD_LOCAL);
    if (!handle)
      error = String::utf8(dlerror());
    return handle;
#endif
  }

  GzScriptInit find_init(void *handle)
  {
#ifdef WINDOWS_ENABLED
    return reinterpret_cast<GzScriptInit>(GetProcAddress(
        reinterpret_cast<HMODULE>(handle), "gzscript_script_init"));
#else
    return reinterpret_cast<GzScriptInit>(
        dlsym(handle, "gzscript_script_init"));
#endif
  }

  const GzEngineApi engine_api = {
      GZSCRIPT_ABI_VERSION,
      sizeof(GzEngineApi),
      log_info,
      log_error,
      object_call,
      object_emit_signal,
      get_method_bind,
      object_ptrcall,
      get_ticks_usec,
  };

} // namespace

GzCompiledModule::~GzCompiledModule()
{
  if (handle)
    close_library(handle);
}

int32_t GzCompiledModule::find_property(const StringName &name) const
{
  const uint32_t *index = property_indices.getptr(name);
  return index ? static_cast<int32_t>(*index) : -1;
}

bool GzCompiledModule::has_same_exports(const GzCompiledModule &other) const
{
  if (!descriptor || !other.descriptor)
    return descriptor == other.descriptor;

  const GzScriptDescriptor *lhs = descriptor;
  const GzScriptDescriptor *rhs = other.descriptor;

  if (lhs->property_count != rhs->property_count ||
      lhs->inspector_entry_count != rhs->inspector_entry_count ||
      !string_view_equal(lhs->base_class, rhs->base_class))
  {
    return false;
  }

  for (uint32_t i = 0; i < lhs->inspector_entry_count; ++i)
  {
    const GzInspectorEntryDescriptor &lhs_entry = lhs->inspector_entries[i];
    const GzInspectorEntryDescriptor &rhs_entry = rhs->inspector_entries[i];

    if (lhs_entry.kind != rhs_entry.kind ||
        !string_view_equal(lhs_entry.name, rhs_entry.name) ||
        !string_view_equal(lhs_entry.prefix, rhs_entry.prefix))
    {
      return false;
    }

    if (lhs_entry.kind == GZ_INSPECTOR_ENTRY_PROPERTY &&
        lhs_entry.property_index != rhs_entry.property_index)
    {
      return false;
    }
  }

  for (uint32_t i = 0; i < lhs->property_count; ++i)
  {
    const GzPropertyDescriptor &lhs_property = lhs->properties[i];
    const GzPropertyDescriptor &rhs_property = rhs->properties[i];

    if (lhs_property.type != rhs_property.type ||
        lhs_property.hint != rhs_property.hint ||
        lhs_property.range_min != rhs_property.range_min ||
        lhs_property.range_max != rhs_property.range_max ||
        lhs_property.range_step != rhs_property.range_step ||
        !string_view_equal(lhs_property.name, rhs_property.name) ||
        !string_view_equal(lhs_property.hint_string,
                           rhs_property.hint_string) ||
        !string_view_equal(lhs_property.class_name,
                           rhs_property.class_name) ||
        !default_value_equal(lhs_property.default_value,
                             rhs_property.default_value))
    {
      return false;
    }
  }

  return true;
}

std::shared_ptr<GzCompiledModule>
GzCompiledModule::load(const String &p_path, String &error)
{
  void *handle = open_library(p_path, error);
  if (!handle)
    return {};

  GzScriptInit init = find_init(handle);
  if (!init)
  {
    error = "Compiled Zig script does not export gzscript_script_init";
    close_library(handle);
    return {};
  }

  const GzScriptDescriptor *descriptor = nullptr;
  if (init(&engine_api, &descriptor) != GZ_STATUS_OK || !descriptor)
  {
    error = "Compiled Zig script initialization failed";
    close_library(handle);
    return {};
  }

  if (descriptor->abi_version != GZSCRIPT_ABI_VERSION ||
      descriptor->struct_size != sizeof(GzScriptDescriptor))
  {
    error = "Compiled Zig script ABI does not match gzscript";
    close_library(handle);
    return {};
  }

  if (!descriptor->create_instance || !descriptor->destroy_instance ||
      !descriptor->call_method || !descriptor->get_property ||
      !descriptor->set_property || !descriptor->notification ||
      (descriptor->method_count > 0 && !descriptor->methods) ||
      (descriptor->property_count > 0 && !descriptor->properties) ||
      (descriptor->inspector_entry_count > 0 &&
       !descriptor->inspector_entries) ||
      (descriptor->signal_count > 0 && !descriptor->signals))
  {
    error = "Compiled Zig script descriptor is incomplete";
    close_library(handle);
    return {};
  }

  std::vector<bool> listed_properties(descriptor->property_count, false);
  for (uint32_t i = 0; i < descriptor->inspector_entry_count; ++i)
  {
    const GzInspectorEntryDescriptor &entry = descriptor->inspector_entries[i];
    if (entry.kind > GZ_INSPECTOR_ENTRY_SUBGROUP)
    {
      error = "Compiled Zig script has an invalid Inspector entry";
      close_library(handle);
      return {};
    }

    if (entry.kind != GZ_INSPECTOR_ENTRY_PROPERTY)
      continue;

    if (entry.property_index >= descriptor->property_count ||
        listed_properties[entry.property_index])
    {
      error = "Compiled Zig script has an invalid Inspector property index";
      close_library(handle);
      return {};
    }

    listed_properties[entry.property_index] = true;
  }

  for (bool listed : listed_properties)
  {
    if (!listed)
    {
      error = "Compiled Zig script Inspector layout omits a property";
      close_library(handle);
      return {};
    }
  }

  auto module = std::make_shared<GzCompiledModule>();
  module->handle = handle;
  module->descriptor = descriptor;
  module->path = p_path;

  module->property_names.reserve(descriptor->property_count);
  module->property_indices.reserve(descriptor->property_count);

  for (uint32_t i = 0; i < descriptor->property_count; ++i)
  {
    const GzPropertyDescriptor &property = descriptor->properties[i];
    StringName property_name(gzscript::from_view(property.name));

    if (module->property_indices.has(property_name))
    {
      error = "Compiled Zig script has duplicate property name: " +
              String(property_name);
      return {};
    }

    module->property_names.push_back(property_name);
    module->property_indices.insert(property_name, i);
    module->property_defaults[property_name] =
        gzscript::to_variant(property.default_value);
  }

  module->inspector_properties.reserve(descriptor->inspector_entry_count);
  for (uint32_t i = 0; i < descriptor->inspector_entry_count; ++i)
  {
    PropertyInfo property =
        inspector_property_info(descriptor, descriptor->inspector_entries[i]);
    module->inspector_properties.push_back(property);
    module->script_property_list.push_back(Dictionary(property));
  }

  return module;
}
