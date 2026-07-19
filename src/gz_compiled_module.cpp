#include "gz_compiled_module.hpp"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#ifdef WINDOWS_ENABLED
#include <windows.h>
#else
#include <dlfcn.h>
#endif
#include <string>

using namespace godot;

namespace {
String from_view(GzStringView value) {
  return String::utf8(value.ptr, static_cast<int64_t>(value.len));
}

GzStringView to_view(const CharString &value) {
  return {value.get_data(), static_cast<size_t>(value.length())};
}

Variant to_variant(const GzValue &value) {
  switch (value.type) {
  case GZ_VALUE_BOOL:
    return value.data.boolean;
  case GZ_VALUE_INT:
    return value.data.integer;
  case GZ_VALUE_FLOAT:
    return value.data.floating;
  case GZ_VALUE_STRING:
    return from_view(value.data.string);
  case GZ_VALUE_VECTOR2:
    return Vector2(value.data.vector2.x, value.data.vector2.y);
  case GZ_VALUE_OBJECT:
    return ObjectDB::get_instance(value.data.object_id);
  default:
    return Variant();
  }
}

GzValue from_variant(const Variant &value) {
  static thread_local CharString string_storage;
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
    string_storage = String(value).utf8();
    result.type = GZ_VALUE_STRING;
    result.data.string = to_view(string_storage);
    break;
  case Variant::VECTOR2: {
    result.type = GZ_VALUE_VECTOR2;
    Vector2 vector = value;
    result.data.vector2 = {vector.x, vector.y};
    break;
  }
  case Variant::OBJECT: {
    result.type = GZ_VALUE_OBJECT;
    Object *object = value;
    result.data.object_id = object ? object->get_instance_id() : 0;
    break;
  }
  default:
    result.type = GZ_VALUE_NIL;
  }
  return result;
}

void log_info(GzStringView message) {
  UtilityFunctions::print(from_view(message));
}

void log_error(GzStringView message) {
  UtilityFunctions::printerr(from_view(message));
}

GzStatus object_call(uint64_t object_id, GzStringView method,
                     const GzValue *arguments, uint32_t argument_count,
                     GzValue *result) {
  Object *object = ObjectDB::get_instance(object_id);
  if (!object || !result) {
    return GZ_STATUS_INVALID_ARGUMENT;
  }
  Array args;
  for (uint32_t i = 0; i < argument_count; ++i) {
    args.push_back(to_variant(arguments[i]));
  }
  *result = from_variant(object->callv(StringName(from_view(method)), args));
  return GZ_STATUS_OK;
}

GzStatus object_emit_signal(uint64_t object_id, GzStringView signal,
                            const GzValue *arguments, uint32_t argument_count) {
  Object *object = ObjectDB::get_instance(object_id);
  if (!object || (argument_count > 0 && !arguments))
    return GZ_STATUS_INVALID_ARGUMENT;
  Array args;
  args.push_back(StringName(from_view(signal)));
  for (uint32_t i = 0; i < argument_count; ++i)
    args.push_back(to_variant(arguments[i]));
  Variant result = object->callv("emit_signal", args);
  return static_cast<Error>(static_cast<int64_t>(result)) == OK
             ? GZ_STATUS_OK
             : GZ_STATUS_SCRIPT_ERROR;
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
    GZSCRIPT_ABI_VERSION, sizeof(GzEngineApi), log_info, log_error,
    object_call,          object_emit_signal,
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

  auto module = std::make_shared<GzCompiledModule>();
  module->handle = handle;
  module->descriptor = descriptor;
  module->path = p_path;
  return module;
}
