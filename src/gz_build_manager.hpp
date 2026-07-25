#pragma once

#include "gz_compiled_module.hpp"
#include "gz_script.hpp"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/object.hpp>

#include <cstdint>
#include <deque>
#include <memory>
#include <string>

class GzBuildManager : public godot::Object {
  GDCLASS(GzBuildManager, godot::Object)

  static GzBuildManager *singleton;
  godot::String last_diagnostics;
  uint64_t next_request_id = 1;

  struct CompilePlan {
    godot::String resource_path;
    godot::String source;
    godot::String key;
    godot::String output;
    godot::String compile_output;
    godot::String generated;
    godot::String zig_executable;
    godot::PackedStringArray arguments;
    bool needs_compile = false;
  };

  struct CompileRequest {
    godot::Ref<GzScript> script;
    godot::String resource_path;
    godot::String source;
    uint64_t generation = 0;
  };

  struct ActiveCompile {
    CompileRequest request;
    CompilePlan plan;
    godot::Ref<godot::FileAccess> stdout_pipe;
    godot::Ref<godot::FileAccess> stderr_pipe;
    std::string output;
    int32_t pid = -1;
  };

  std::deque<CompileRequest> pending;
  std::unique_ptr<ActiveCompile> active;

  bool prepare(const godot::String &resource_path,
               const godot::String &source, uint64_t request_id,
               CompilePlan &plan);
  std::shared_ptr<GzCompiledModule> finish(const CompilePlan &plan,
                                            int exit_code,
                                            const godot::String &output);
  void start_next();
  void complete_active(int exit_code);
  static void drain(const godot::Ref<godot::FileAccess> &pipe,
                     std::string &output);

protected:
  static void _bind_methods();

public:
  GzBuildManager();
  ~GzBuildManager();

  static GzBuildManager *get_singleton() { return singleton; }
  static godot::String get_zig_executable();

  std::shared_ptr<GzCompiledModule> compile(const godot::String &resource_path,
                                            const godot::String &source);
  void queue_compile(const godot::Ref<GzScript> &script);
  void queue_all();
  void pump();
  void wait_for_all();
  bool compile_path(const godot::String &resource_path);
  bool compile_all();
  bool is_compiling() const;
  godot::String get_last_diagnostics() const { return last_diagnostics; }
};
