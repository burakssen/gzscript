#include "gz_compiled_module.hpp"
#include "gz_value_codec.hpp"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#ifdef WINDOWS_ENABLED
#include <windows.h>
#else
#include <dlfcn.h>
#endif
#include <string>
#include <unordered_map>
#include <vector>

using namespace godot;

namespace {
void log_info(GzStringView message) {
  UtilityFunctions::print_rich(gzscript::from_view(message));
}

void log_error(GzStringView message) {
  UtilityFunctions::printerr(gzscript::from_view(message));
}

// Own keys because method names can originate in unloadable script modules.
static thread_local std::unordered_map<std::string, StringName>
    method_name_cache;

StringName get_cached_name(GzStringView view) {
  std::string key(view.ptr, view.len);
  auto it = method_name_cache.find(key);
  if (it != method_name_cache.end()) {
    return it->second;
  }
  StringName name(gzscript::from_view(view));
  method_name_cache.emplace(std::move(key), name);
  return name;
}

GzStatus object_call(uint64_t object_id, GzStringView method,
                     const GzValue *arguments, uint32_t argument_count,
                     GzValue *result) {
  Object *object = ObjectDB::get_instance(object_id);
  if (!object || !result || (argument_count > 0 && !arguments)) {
    return GZ_STATUS_INVALID_ARGUMENT;
  }

  // Keep common calls allocation-free.
  constexpr uint32_t STACK_LIMIT = 8;
  Variant stack_values[STACK_LIMIT];
  const Variant *stack_pointers[STACK_LIMIT];

  std::vector<Variant> heap_values;
  std::vector<const Variant *> heap_pointers;

  Variant *values_ptr = stack_values;
  const Variant **pointers_ptr = stack_pointers;

  if (argument_count > STACK_LIMIT) {
    heap_values.resize(argument_count);
    heap_pointers.resize(argument_count);
    values_ptr = heap_values.data();
    pointers_ptr = heap_pointers.data();
  }

  for (uint32_t i = 0; i < argument_count; ++i) {
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
  switch (call_error.error) {
  case GDEXTENSION_CALL_OK:
    static thread_local CharString string_storage;
    bool valid;
    *result = gzscript::from_variant(call_result, &string_storage, &valid);
    if (!valid)
      return GZ_STATUS_TYPE_MISMATCH;
    return GZ_STATUS_OK;
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
                            const GzValue *arguments, uint32_t argument_count) {
  Object *object = ObjectDB::get_instance(object_id);
  if (!object || (argument_count > 0 && !arguments))
    return GZ_STATUS_INVALID_ARGUMENT;

  std::vector<Variant> values(argument_count + 1);
  std::vector<const Variant *> pointers(argument_count + 1);
  values[0] = get_cached_name(signal);
  pointers[0] = &values[0];
  for (uint32_t i = 0; i < argument_count; ++i) {
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
      pointers.size(), &result, &error);
  return error.error == GDEXTENSION_CALL_OK &&
                 static_cast<Error>(static_cast<int64_t>(result)) == OK
             ? GZ_STATUS_OK
             : GZ_STATUS_SCRIPT_ERROR;
}

void *get_method_bind(GzStringView class_name, GzStringView method_name,
                      int64_t hash) {
  StringName c_name(gzscript::from_view(class_name));
  StringName m_name(gzscript::from_view(method_name));
  return (void *)::godot::gdextension_interface::classdb_get_method_bind(
      c_name._native_ptr(), m_name._native_ptr(), hash);
}

GzStatus object_ptrcall(void *method_bind, uint64_t object_id,
                        const void *const *arguments, void *result) {
  Object *object = ObjectDB::get_instance(object_id);
  if (!object || !method_bind) {
    return GZ_STATUS_INVALID_ARGUMENT;
  }
  ::godot::gdextension_interface::object_method_bind_ptrcall(
      (GDExtensionMethodBindPtr)method_bind, object->_owner,
      (GDExtensionConstTypePtr *)arguments, (GDExtensionTypePtr)result);
  return GZ_STATUS_OK;
}

void close_library(void *handle) {
#ifdef WINDOWS_ENABLED
  FreeLibrary(reinterpret_cast<HMODULE>(handle));
#else
  dlclose(handle);
#endif
}

void *open_library(const String &path, String &error) {
#ifdef WINDOWS_ENABLED
  Char16String wide_path = path.utf16();
  HMODULE handle =
      LoadLibraryW(reinterpret_cast<const wchar_t *>(wide_path.get_data()));
  if (!handle)
    error = "LoadLibraryW failed with error " +
            String::num_int64(static_cast<int64_t>(GetLastError()));
  return reinterpret_cast<void *>(handle);
#else
  CharString native_path = path.utf8();
  void *handle = dlopen(native_path.get_data(), RTLD_NOW | RTLD_LOCAL);
  if (!handle)
    error = String::utf8(dlerror());
  return handle;
#endif
}

GzScriptInit find_init(void *handle) {
#ifdef WINDOWS_ENABLED
  return reinterpret_cast<GzScriptInit>(GetProcAddress(
      reinterpret_cast<HMODULE>(handle), "gzscript_script_init"));
#else
  return reinterpret_cast<GzScriptInit>(dlsym(handle, "gzscript_script_init"));
#endif
}

const GzEngineApi engine_api = {
    GZSCRIPT_ABI_VERSION, sizeof(GzEngineApi), log_info,        log_error,
    object_call,          object_emit_signal,  get_method_bind, object_ptrcall,
};

} // namespace

GzCompiledModule::~GzCompiledModule() {
  if (handle)
    close_library(handle);
}

std::shared_ptr<GzCompiledModule> GzCompiledModule::load(const String &p_path,
                                                         String &error) {
  void *handle = open_library(p_path, error);
  if (!handle)
    return {};

  GzScriptInit init = find_init(handle);
  if (!init) {
    error = "Compiled Zig script does not export gzscript_script_init";
    close_library(handle);
    return {};
  }

  const GzScriptDescriptor *descriptor = nullptr;
  if (init(&engine_api, &descriptor) != GZ_STATUS_OK || !descriptor) {
    error = "Compiled Zig script initialization failed";
    close_library(handle);
    return {};
  }
  if (descriptor->abi_version != GZSCRIPT_ABI_VERSION ||
      descriptor->struct_size != sizeof(GzScriptDescriptor)) {
    error = "Compiled Zig script ABI does not match gzscript";
    close_library(handle);
    return {};
  }
  if (!descriptor->create_instance || !descriptor->destroy_instance ||
      !descriptor->call_method || !descriptor->get_property ||
      !descriptor->set_property || !descriptor->notification ||
      (descriptor->method_count > 0 && !descriptor->methods) ||
      (descriptor->property_count > 0 && !descriptor->properties) ||
      (descriptor->signal_count > 0 && !descriptor->signals)) {
    error = "Compiled Zig script descriptor is incomplete";
    close_library(handle);
    return {};
  }

  auto module = std::make_shared<GzCompiledModule>();
  module->handle = handle;
  module->descriptor = descriptor;
  module->path = p_path;

  // Cache property names used by every instance get/set.
  for (uint32_t i = 0; i < descriptor->property_count; ++i) {
    module->property_names.push_back(
        StringName(gzscript::from_view(descriptor->properties[i].name)));
  }

  return module;
}
