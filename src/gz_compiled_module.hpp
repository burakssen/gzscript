#pragma once

#include "abi/gzscript_abi.h"

#include <godot_cpp/variant/string.hpp>

#include <memory>

class GzCompiledModule {
  void *handle = nullptr;
  const GzScriptDescriptor *descriptor = nullptr;
  godot::String path;

public:
  ~GzCompiledModule();

  static std::shared_ptr<GzCompiledModule> load(const godot::String &path,
                                                godot::String &error);
  const GzScriptDescriptor *get_descriptor() const { return descriptor; }
  const godot::String &get_path() const { return path; }
};
