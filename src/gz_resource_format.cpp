#include "gz_resource_format.hpp"

#include "gz_build_manager.hpp"
#include "gz_file_utils.hpp"
#include "gz_script.hpp"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/classes/thread.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace
{
  Error save_text_safely(const String &path, const String &contents)
  {
    const String absolute =
        ProjectSettings::get_singleton()->globalize_path(path);
    const String suffix = ".gzscript-" +
                          String::num_int64(OS::get_singleton()->get_process_id()) +
                          "-" + String::num_int64(
                                    Time::get_singleton()->get_ticks_usec());
    const String temporary = absolute + suffix + ".tmp";
    Ref<FileAccess> file = FileAccess::open(temporary, FileAccess::WRITE);
    if (file.is_null() || !file->store_string(contents))
    {
      DirAccess::remove_absolute(temporary);
      return ERR_CANT_CREATE;
    }
    file->flush();
    const Error write_error = file->get_error();
    file->close();
    if (write_error != OK)
    {
      DirAccess::remove_absolute(temporary);
      return write_error;
    }

    const Error sync_error = gz_sync_file(temporary);
    if (sync_error != OK)
    {
      DirAccess::remove_absolute(temporary);
      return sync_error;
    }
    if (FileAccess::get_file_as_string(temporary) != contents)
    {
      DirAccess::remove_absolute(temporary);
      return ERR_FILE_CORRUPT;
    }

    const Error publish_error = gz_atomic_replace(temporary, absolute);
    if (publish_error != OK)
    {
      DirAccess::remove_absolute(temporary);
      return publish_error;
    }
    return gz_sync_parent_directory(absolute);
  }
} // namespace

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
  script->set_active_path(path);
  script->set_source(file->get_as_text());
  if (Engine::get_singleton()->is_editor_hint())
    GzBuildManager::get_singleton()->queue_compile(script);
  else
    script->reload(false);
  return script;
}

void GzResourceSaver::_bind_methods() {}

Error GzResourceSaver::_save(const Ref<Resource> &resource, const String &path,
                              uint32_t flags)
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
  const Error save_error = save_text_safely(path, script->get_source_code());
  if (save_error != OK)
    return save_error;
  if ((flags & ResourceSaver::FLAG_CHANGE_PATH) != 0)
  {
    script->set_active_path(path);
    script->call_deferred("_apply_active_path");
  }
  else if (!script->get_active_path().is_empty())
    script->set_path_cache(script->get_active_path());
  // Persistence success is independent from compilation diagnostics.
  GzBuildManager *build_manager = GzBuildManager::get_singleton();
  build_manager->queue_saved(script, path);
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
