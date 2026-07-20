#pragma once

#include "abi/gzscript_abi.h"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <memory>
#include <vector>

class GzCompiledModule {
  void *handle = nullptr;
  const GzScriptDescriptor *descriptor = nullptr;
  godot::String path;
  std::vector<godot::StringName> property_names;

public:
  ~GzCompiledModule();

  static std::shared_ptr<GzCompiledModule> load(const godot::String &path,
                                                godot::String &error);
  const GzScriptDescriptor *get_descriptor() const { return descriptor; }
  const godot::String &get_path() const { return path; }
  const std::vector<godot::StringName> &get_property_names() const { return property_names; }
};
