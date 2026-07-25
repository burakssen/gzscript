#include "gz_resource_format.hpp"

#include "gz_build_manager.hpp"
#include "gz_script.hpp"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/thread.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void GzResourceLoader::_bind_methods() {}
PackedStringArray GzResourceLoader::_get_recognized_extensions() const
{
  return PackedStringArray({"zig"});
}
bool GzResourceLoader::_handles_type(const StringName &type) const
{
  return type == StringName("Script") || type == StringName("ZigScript");
}
String GzResourceLoader::_get_resource_type(const String &path) const
{
  return path.get_extension() == "zig" ? "ZigScript" : String();
}

Variant GzResourceLoader::_load(const String &path, const String &, bool,
                                int32_t) const
{
  if (!Thread::is_main_thread())
  {
    UtilityFunctions::printerr(
        "gzscript: threaded resource loading is not supported; load Zig "
        "scripts on the main thread");
    return Variant();
  }
  Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
  if (file.is_null())
    return Variant();
  Ref<GzScript> script;
  script.instantiate();
  script->set_path(path);
  script->set_source(file->get_as_text());
  script->reload(false);
  return script;
}

void GzResourceSaver::_bind_methods() {}

Error GzResourceSaver::_save(const Ref<Resource> &resource, const String &path,
                             uint32_t)
{
  if (!Thread::is_main_thread())
  {
    UtilityFunctions::printerr(
        "gzscript: threaded resource saving is not supported");
    return ERR_UNAVAILABLE;
  }
  Ref<GzScript> script = resource;
  if (script.is_null())
    return ERR_INVALID_PARAMETER;
  Ref<FileAccess> file = FileAccess::open(path, FileAccess::WRITE);
  if (file.is_null() || !file->store_string(script->get_source_code()))
    return ERR_CANT_CREATE;
  file->flush();
  file->close();
  script->set_path(path);
  // Persistence success is independent from compilation diagnostics.
  GzBuildManager::get_singleton()->queue_compile(script);
  return OK;
}

bool GzResourceSaver::_recognize(const Ref<Resource> &resource) const
{
  return Object::cast_to<GzScript>(resource.ptr()) != nullptr;
}
PackedStringArray GzResourceSaver::_get_recognized_extensions(
    const Ref<Resource> &resource) const
{
  return _recognize(resource) ? PackedStringArray({"zig"})
                              : PackedStringArray();
}
