#pragma once

#include "abi/gzscript_abi.h"

#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <cstdint>
#include <memory>
#include <vector>

class GzCompiledModule
{
  void *handle = nullptr;
  const GzScriptDescriptor *descriptor = nullptr;
  godot::String path;

  // Hot-path metadata, owned by the compiled-module wrapper rather than the
  // unloadable Zig library.
  std::vector<godot::StringName> property_names;
  godot::HashMap<godot::StringName, uint32_t> property_indices;

  // Cached Inspector/export metadata. Constructing PropertyInfo dictionaries
  // and converting default values is relatively expensive, so do it once when
  // the module is loaded.
  std::vector<godot::PropertyInfo> inspector_properties;
  godot::TypedArray<godot::Dictionary> script_property_list;
  godot::Dictionary property_defaults;

public:
  ~GzCompiledModule();

  static std::shared_ptr<GzCompiledModule> load(const godot::String &path,
                                                godot::String &error);

  const GzScriptDescriptor *get_descriptor() const { return descriptor; }
  const godot::String &get_path() const { return path; }

  const std::vector<godot::StringName> &get_property_names() const
  {
    return property_names;
  }

  int32_t find_property(const godot::StringName &name) const;

  const std::vector<godot::PropertyInfo> &get_inspector_properties() const
  {
    return inspector_properties;
  }

  const godot::TypedArray<godot::Dictionary> &get_script_property_list() const
  {
    return script_property_list;
  }

  const godot::Dictionary &get_property_defaults() const
  {
    return property_defaults;
  }

  // Includes Inspector layout, property metadata, and default values. This is
  // used to avoid rebuilding every placeholder when only executable code
  // changed.
  bool has_same_exports(const GzCompiledModule &other) const;
};
