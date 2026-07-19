#include "gz_build_manager.hpp"

#include "gz_script.hpp"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

GzBuildManager *GzBuildManager::singleton = nullptr;

namespace {
constexpr const char *ZIG_PATH_SETTING = "gzscript/compiler/zig_path";

String zig_path(const String &relative) {
  return ProjectSettings::get_singleton()->globalize_path(
      "res://addons/gzscript/zig/" + relative);
}

String zig_executable() {
  ProjectSettings *settings = ProjectSettings::get_singleton();
  String configured = settings->get_setting(ZIG_PATH_SETTING, String());
  if (!configured.is_empty()) {
    return configured;
  }

  OS *os = OS::get_singleton();
  String from_environment = os->get_environment("GZSCRIPT_ZIG_PATH");
  if (!from_environment.is_empty()) {
    return from_environment;
  }

  String home = os->get_environment("HOME");
  if (home.is_empty())
    home = os->get_environment("USERPROFILE");
  String executable = os->get_name() == "Windows" ? "zig.exe" : "zig";
  String zvm_path = home.path_join(".zvm/bin").path_join(executable);
  return !home.is_empty() && FileAccess::file_exists(zvm_path) ? zvm_path
                                                               : executable;
}

bool write_text(const String &path, const String &contents) {
  Ref<FileAccess> file = FileAccess::open(path, FileAccess::WRITE);
  return file.is_valid() && file->store_string(contents);
}

String platform_name() {
  String name = OS::get_singleton()->get_name();
  if (name == "macOS")
    return "macos";
  if (name == "Linux")
    return "linux";
  if (name == "Windows")
    return "windows";
  return {};
}

String module_extension(const String &platform) {
  if (platform == "macos")
    return ".dylib";
  if (platform == "linux")
    return ".so";
  if (platform == "windows")
    return ".dll";
  return {};
}
} // namespace

void GzBuildManager::_bind_methods() {
  ClassDB::bind_method(D_METHOD("compile_path", "resource_path"),
                       &GzBuildManager::compile_path);
  ClassDB::bind_method(D_METHOD("compile_all"), &GzBuildManager::compile_all);
  ClassDB::bind_method(D_METHOD("get_last_diagnostics"),
                       &GzBuildManager::get_last_diagnostics);
  ADD_SIGNAL(MethodInfo("script_compiled"));
}

GzBuildManager::GzBuildManager() {
  singleton = this;

  ProjectSettings *settings = ProjectSettings::get_singleton();
  if (!settings->has_setting(ZIG_PATH_SETTING)) {
    settings->set_setting(ZIG_PATH_SETTING, String());
  }
  settings->set_initial_value(ZIG_PATH_SETTING, String());
  settings->set_as_basic(ZIG_PATH_SETTING, true);

  Dictionary property_info;
  property_info["name"] = ZIG_PATH_SETTING;
  property_info["type"] = Variant::STRING;
  property_info["hint"] = PROPERTY_HINT_GLOBAL_FILE;
  settings->add_property_info(property_info);
}

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
  String platform = platform_name();
  String architecture = Engine::get_singleton()->get_architecture_name();
  String extension = module_extension(platform);
  if (platform.is_empty() || extension.is_empty()) {
    last_diagnostics = "gzscript runtime compilation is only supported on "
                       "macOS, Linux, and Windows";
    UtilityFunctions::printerr("gzscript: ", last_diagnostics);
    return {};
  }
  String module_directory =
      cache_root.path_join("modules/" + platform + "-" + architecture);
  DirAccess::make_dir_recursive_absolute(cache_root.path_join("generated"));
  DirAccess::make_dir_recursive_absolute(module_directory);

  String sdk_fingerprint;
  const char *sdk_files[] = {"abi.zig",   "adapter.zig",  "class.zig",
                             "godot.zig", "property.zig", "runtime.zig",
                             "signal.zig"};
  for (const char *file : sdk_files)
    sdk_fingerprint += FileAccess::get_file_as_string(
        "res://addons/gzscript/zig/" + String(file));
  String key =
      (source + sdk_fingerprint + String::num_int64(GZSCRIPT_ABI_VERSION) +
       platform + architecture + OS::get_singleton()->get_version() +
       "zig-0.16.0")
          .sha256_text()
          .substr(0, 16);
  String generated = cache_root.path_join("generated/script_" + key + ".zig");
  String output = module_directory.path_join("script_" + key + extension);
  String source_path =
      ProjectSettings::get_singleton()->globalize_path(resource_path);
  if (!FileAccess::file_exists(source_path)) {
    last_diagnostics = "Zig script not found: " + source_path;
    UtilityFunctions::printerr("gzscript: ", last_diagnostics);
    return {};
  }
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
    arguments.push_back("-Muser_script=" + source_path);
    arguments.push_back("-Mgodot=" + zig_path("godot.zig"));

    Array output_lines;
    int exit_code = OS::get_singleton()->execute(zig_executable(), arguments,
                                                 output_lines, true);
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
  } else {
    emit_signal("script_compiled");
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
