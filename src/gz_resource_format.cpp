#include "gz_resource_format.hpp"

#include "gz_script.hpp"

#include <godot_cpp/classes/file_access.hpp>

using namespace godot;

void GzResourceLoader::_bind_methods() {}
PackedStringArray GzResourceLoader::_get_recognized_extensions() const {
  return PackedStringArray({"zig"});
}
bool GzResourceLoader::_handles_type(const StringName &type) const {
  return type == StringName("Script") || type == StringName("ZigScript");
}
String GzResourceLoader::_get_resource_type(const String &path) const {
  return path.get_extension() == "zig" ? "ZigScript" : String();
}

Variant GzResourceLoader::_load(const String &path, const String &, bool,
                                int32_t) const {
  Ref<GzScript> script;
  script.instantiate();
  script->set_path(path);
  script->set_source(FileAccess::get_file_as_string(path));
  script->reload(false);
  return script;
}

void GzResourceSaver::_bind_methods() {}

Error GzResourceSaver::_save(const Ref<Resource> &resource, const String &path,
                             uint32_t) {
  Ref<GzScript> script = resource;
  if (script.is_null())
    return ERR_INVALID_PARAMETER;
  Ref<FileAccess> file = FileAccess::open(path, FileAccess::WRITE);
  if (file.is_null() || !file->store_string(script->get_source_code()))
    return ERR_CANT_CREATE;
  file->flush();
  file->close();
  script->set_path(path);
  return script->reload(false);
}

bool GzResourceSaver::_recognize(const Ref<Resource> &resource) const {
  return Object::cast_to<GzScript>(resource.ptr()) != nullptr;
}
PackedStringArray GzResourceSaver::_get_recognized_extensions(
    const Ref<Resource> &resource) const {
  return _recognize(resource) ? PackedStringArray({"zig"})
                              : PackedStringArray();
}
