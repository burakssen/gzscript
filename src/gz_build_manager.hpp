#pragma once

#include "gz_compiled_module.hpp"

#include <godot_cpp/classes/object.hpp>

#include <memory>

class GzBuildManager : public godot::Object {
  GDCLASS(GzBuildManager, godot::Object)

  static GzBuildManager *singleton;
  godot::String last_diagnostics;

protected:
  static void _bind_methods();

public:
  GzBuildManager();
  ~GzBuildManager();

  static GzBuildManager *get_singleton() { return singleton; }
  static godot::String get_zig_executable();

  std::shared_ptr<GzCompiledModule> compile(const godot::String &resource_path,
                                            const godot::String &source);
  bool compile_path(const godot::String &resource_path);
  bool compile_all();
  godot::String get_last_diagnostics() const { return last_diagnostics; }
};
