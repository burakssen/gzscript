#pragma once

#include <godot_cpp/classes/resource_format_loader.hpp>
#include <godot_cpp/classes/resource_format_saver.hpp>

class GzResourceLoader : public godot::ResourceFormatLoader {
  GDCLASS(GzResourceLoader, godot::ResourceFormatLoader)

protected:
  static void _bind_methods();

public:
  godot::PackedStringArray _get_recognized_extensions() const override;
  bool _handles_type(const godot::StringName &type) const override;
  godot::String _get_resource_type(const godot::String &path) const override;
  godot::Variant _load(const godot::String &path,
                       const godot::String &original_path, bool use_sub_threads,
                       int32_t cache_mode) const override;
};

class GzResourceSaver : public godot::ResourceFormatSaver {
  GDCLASS(GzResourceSaver, godot::ResourceFormatSaver)

protected:
  static void _bind_methods();

public:
  godot::Error _save(const godot::Ref<godot::Resource> &resource,
                     const godot::String &path, uint32_t flags) override;
  bool _recognize(const godot::Ref<godot::Resource> &resource) const override;
  godot::PackedStringArray _get_recognized_extensions(
      const godot::Ref<godot::Resource> &resource) const override;
};
