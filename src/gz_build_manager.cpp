#include "gz_build_manager.hpp"

#include "gz_script.hpp"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

GzBuildManager *GzBuildManager::singleton = nullptr;

namespace {
String zig_path(const String &relative) {
  return ProjectSettings::get_singleton()->globalize_path(
      "res://addons/gzscript/zig/" + relative);
}

bool write_text(const String &path, const String &contents) {
  Ref<FileAccess> file = FileAccess::open(path, FileAccess::WRITE);
  return file.is_valid() && file->store_string(contents);
}

String module_extension() { return ".dylib"; }
} // namespace

void GzBuildManager::_bind_methods() {
  ClassDB::bind_method(D_METHOD("compile_path", "resource_path"),
                       &GzBuildManager::compile_path);
  ClassDB::bind_method(D_METHOD("compile_all"), &GzBuildManager::compile_all);
  ClassDB::bind_method(D_METHOD("get_last_diagnostics"),
                       &GzBuildManager::get_last_diagnostics);
}

GzBuildManager::GzBuildManager() { singleton = this; }

GzBuildManager::~GzBuildManager() {
  if (singleton == this) {
    singleton = nullptr;
  }
}

std::shared_ptr<GzCompiledModule>
GzBuildManager::compile(const String &resource_path, const String &source) {
  String project_root =
      ProjectSettings::get_singleton()->globalize_path("res://");
  String cache_root = project_root.path_join(".godot/gzscript");
  DirAccess::make_dir_recursive_absolute(cache_root.path_join("generated"));
  DirAccess::make_dir_recursive_absolute(
      cache_root.path_join("modules/macos-aarch64"));

  String sdk_fingerprint =
      FileAccess::get_file_as_string("res://addons/gzscript/zig/godot.zig") +
      FileAccess::get_file_as_string("res://addons/gzscript/zig/adapter.zig") +
      FileAccess::get_file_as_string("res://addons/gzscript/zig/abi.zig");
  String key =
      (source + sdk_fingerprint + String::num_int64(GZSCRIPT_ABI_VERSION) +
       OS::get_singleton()->get_version() + "zig-0.16.0")
          .sha256_text()
          .substr(0, 16);
  String generated = cache_root.path_join("generated/script_" + key + ".zig");
  String output = cache_root.path_join("modules/macos-aarch64/script_" + key +
                                       module_extension());
  {
    String adapter =
        "const gd = @import(\"godot\");\n"
        "const Script = @import(\"user_script\");\n"
        "const Adapter = gd.ScriptAdapter(Script);\n"
        "export fn gzscript_script_init(api: *const gd.abi.EngineApi, out: "
        "**const gd.abi.ScriptDescriptor) callconv(.c) gd.abi.Status {\n"
        "    return gd.initialize(api, out, &Adapter.descriptor);\n"
        "}\n";
    if (!write_text(generated, adapter)) {
      last_diagnostics = "Unable to write generated Zig adapter";
      return {};
    }
  }

  if (!FileAccess::file_exists(output)) {
    PackedStringArray arguments;
    arguments.push_back("build-lib");
    arguments.push_back("-dynamic");
    arguments.push_back("-O");
    arguments.push_back("Debug");
    arguments.push_back("-femit-bin=" + output);
    arguments.push_back("--dep");
    arguments.push_back("godot");
    arguments.push_back("--dep");
    arguments.push_back("user_script");
    arguments.push_back("-Mroot=" + generated);
    arguments.push_back("--dep");
    arguments.push_back("godot");
    arguments.push_back(
        "-Muser_script=" +
        ProjectSettings::get_singleton()->globalize_path(resource_path));
    arguments.push_back("-Mgodot=" + zig_path("godot.zig"));

    Array output_lines;
    int exit_code =
        OS::get_singleton()->execute("zig", arguments, output_lines, true);
    last_diagnostics =
        output_lines.is_empty() ? String() : String(output_lines[0]);
    if (exit_code != 0) {
      DirAccess::remove_absolute(output);
      UtilityFunctions::printerr("gzscript: compilation failed for ",
                                 resource_path, "\n", last_diagnostics);
      return {};
    }
  }

  String error;
  auto module = GzCompiledModule::load(output, error);
  if (!module) {
    DirAccess::remove_absolute(output);
    last_diagnostics = error;
    UtilityFunctions::printerr("gzscript: ", error);
  }
  return module;
}

bool GzBuildManager::compile_path(const String &resource_path) {
  return compile(resource_path,
                 FileAccess::get_file_as_string(resource_path)) != nullptr;
}

bool GzBuildManager::compile_all() {
  bool success = true;
  for (GzScript *script : GzScript::get_scripts()) {
    if (script->get_path().is_empty())
      continue;
    script->set_source(FileAccess::get_file_as_string(script->get_path()));
    if (script->reload(false) != OK)
      success = false;
  }
  return success;
}
