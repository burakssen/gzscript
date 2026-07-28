#include "gz_build_manager.hpp"

#include "gz_script.hpp"

#include "gz_language.hpp"
#include "gz_process_utils.hpp"
#include "gz_value_codec.hpp"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/hashing_context.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/thread.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <unordered_set>
#include <utility>
#include <vector>

using namespace godot;

GzBuildManager *GzBuildManager::singleton = nullptr;

namespace
{
  constexpr const char *ZIG_PATH_SETTING = "gzscript/compiler/zig_path";
  constexpr const char *ZIG_OPTIMIZATION_SETTING =
      "gzscript/compiler/optimization";
  constexpr const char *CACHE_FORMAT_VERSION = "5";
  constexpr uint64_t COMPILER_TIMEOUT_MSEC = 120'000;
  constexpr uint64_t PROCESS_KILL_GRACE_MSEC = 1'000;
  constexpr int64_t PIPE_READ_LIMIT = 64 * 1024;
  constexpr std::size_t COMPILER_OUTPUT_LIMIT = 64 * 1024;
  constexpr const char *OUTPUT_TRUNCATED = "\n[gzscript: compiler output truncated]";
  constexpr const char *ADAPTER_SOURCE =
      "const std = @import(\"std\");\n"
      "const gd = @import(\"godot\");\n"
      "const Script = @import(\"user_script\");\n"
      "const Adapter = gd.ScriptAdapter(Script);\n"
      "export fn gzscript_script_init(api: *const gd.abi.EngineApi, out: "
      "**const gd.abi.ScriptDescriptor) callconv(.c) gd.abi.Status {\n"
      "    return gd.initialize(api, out, &Adapter.descriptor);\n"
      "}\n"
      "pub const std_options = std.Options{\n"
      "    .logFn = log,\n"
      "};\n"
      "pub fn log(\n"
      "    comptime message_level: std.log.Level,\n"
      "    comptime scope: @EnumLiteral(),\n"
      "    comptime format: []const u8,\n"
      "    args: anytype,\n"
      ") void {\n"
      "    const color = switch (message_level) {\n"
      "        .err => \"red\",\n"
      "        .warn => \"gold\",\n"
      "        .info => \"green\",\n"
      "        .debug => \"cyan\",\n"
      "    };\n"
      "    const prefix = \"[color=\" ++ color ++ \"]\" ++ \"[\" ++ @tagName(scope) ++ \"]\" ++ \"[/color] \";\n"
      "    gd.log.info(prefix ++ format, args);\n"
      "}\n";

  String zig_path(const String &relative)
  {
    return ProjectSettings::get_singleton()->globalize_path(
        "res://addons/gzscript/zig/" + relative);
  }

  bool write_text(const String &path, const String &contents)
  {
    Ref<FileAccess> file = FileAccess::open(path, FileAccess::WRITE);
    return file.is_valid() && file->store_string(contents);
  }

  bool cache_stamp_matches(const String &output, const String &stamp_path,
                           const String &source_hash)
  {
    if (!FileAccess::file_exists(output) ||
        !FileAccess::file_exists(stamp_path))
      return false;
    const PackedStringArray stamp =
        FileAccess::get_file_as_string(stamp_path).split("\n", false);
    return stamp.size() == 2 && stamp[0] == source_hash &&
           stamp[1] == FileAccess::get_sha256(output);
  }

  void append_identity(String &identity, const String &label,
                       const String &value)
  {
    identity += label + String(":") + String::num_int64(value.length()) +
                String(":") + value + String("\n");
  }

  bool append_source_tree(const String &root, const String &relative,
                          bool include_non_zig, String &fingerprint,
                          String &error)
  {
    String directory_path = relative.is_empty() ? root : root.path_join(relative);
    Ref<DirAccess> directory = DirAccess::open(directory_path);
    if (directory.is_null())
    {
      error = "Unable to read Zig source directory: " + directory_path;
      return false;
    }

    PackedStringArray files = directory->get_files();
    files.sort();
    for (int64_t i = 0; i < files.size(); ++i)
    {
      String file = files[i];
      if (file == ".DS_Store" || file.get_extension() == "uid")
        continue;
      if (!include_non_zig && file.get_extension() != "zig")
        continue;
      String relative_path =
          relative.is_empty() ? file : relative.path_join(file);
      String hash = FileAccess::get_sha256(root.path_join(relative_path));
      if (hash.is_empty())
      {
        error =
            "Unable to fingerprint Zig source: " + root.path_join(relative_path);
        return false;
      }
      append_identity(fingerprint, relative_path, hash);
    }

    PackedStringArray directories = directory->get_directories();
    directories.sort();
    for (int64_t i = 0; i < directories.size(); ++i)
    {
      String child = directories[i];
      if (child == ".git" || child == ".godot" || child == ".zig-cache" ||
          child == "zig-out")
        continue;
      String child_relative =
          relative.is_empty() ? child : relative.path_join(child);
      if (!append_source_tree(root, child_relative, include_non_zig,
                              fingerprint, error))
        return false;
    }
    return true;
  }

  struct SourceDependency
  {
    String path;
    bool import = false;
  };

  bool source_dependencies(const String &source,
                           std::vector<SourceDependency> &dependencies)
  {
    for (int64_t index = 0; index < source.length();)
    {
      if (source[index] == '/' && index + 1 < source.length() &&
          source[index + 1] == '/')
      {
        int64_t newline = source.find("\n", index + 2);
        index = newline < 0 ? source.length() : newline + 1;
        continue;
      }
      if (source[index] == '"' || source[index] == '\'')
      {
        const char32_t quote = source[index++];
        while (index < source.length())
        {
          if (source[index] == '\\')
          {
            index += 2;
            continue;
          }
          if (source[index++] == quote)
            break;
        }
        continue;
      }

      bool is_import = source.substr(index, 7) == "@import";
      bool is_embed = source.substr(index, 10) == "@embedFile";
      if (!is_import && !is_embed)
      {
        ++index;
        continue;
      }
      index += is_import ? 7 : 10;
      while (index < source.length() &&
             (source[index] == ' ' || source[index] == '\t' ||
              source[index] == '\r' || source[index] == '\n'))
        ++index;
      if (index >= source.length() || source[index++] != '(')
        return false;
      while (index < source.length() &&
             (source[index] == ' ' || source[index] == '\t' ||
              source[index] == '\r' || source[index] == '\n'))
        ++index;
      if (index >= source.length() || source[index++] != '"')
        return false;
      const int64_t start = index;
      while (index < source.length() && source[index] != '"')
      {
        if (source[index] == '\\')
          return false;
        ++index;
      }
      if (index >= source.length())
        return false;
      dependencies.push_back({source.substr(start, index - start), is_import});
      ++index;
    }
    return true;
  }

  bool append_dependencies(const String &source_path, String &fingerprint,
                           String &error)
  {
    std::vector<SourceDependency> pending{
        {source_path.simplify_path(), true}};
    std::unordered_set<std::string> visited;
    bool first = true;
    while (!pending.empty())
    {
      SourceDependency current = pending.back();
      pending.pop_back();
      String path = current.path;
      CharString path_utf8 = path.utf8();
      std::string visit_key(path_utf8.get_data(), path_utf8.length());
      visit_key += current.import ? "#import" : "#embed";
      if (!visited.emplace(std::move(visit_key)).second)
        continue;

      if (!first)
      {
        String hash = FileAccess::get_sha256(path);
        if (hash.is_empty())
        {
          error = "Unable to fingerprint Zig dependency: " + path;
          return false;
        }
        append_identity(fingerprint, path, hash);
      }
      first = false;
      if (!current.import)
        continue;

      std::vector<SourceDependency> dependencies;
      if (!source_dependencies(FileAccess::get_file_as_string(path),
                               dependencies))
        return false;
      for (const SourceDependency &dependency : dependencies)
      {
        if (dependency.import &&
            dependency.path.find("/") < 0 &&
            dependency.path.get_extension() != "zig")
          continue;
        pending.push_back(
            {path.get_base_dir().path_join(dependency.path).simplify_path(),
             dependency.import});
      }
    }
    return true;
  }

  String normalize_source(const String &str)
  {
    return str.replace("\r\n", "\n").strip_edges();
  }

  bool valid_optimization(const String &optimization)
  {
    return optimization == "Debug" || optimization == "ReleaseSafe" ||
           optimization == "ReleaseFast" || optimization == "ReleaseSmall";
  }

  String platform_name()
  {
    String name = OS::get_singleton()->get_name();
    if (name == "macOS")
      return "macos";
    if (name == "Linux")
      return "linux";
    if (name == "Windows")
      return "windows";
    return {};
  }

  String module_extension(const String &platform)
  {
    if (platform == "macos")
      return ".dylib";
    if (platform == "linux")
      return ".so";
    if (platform == "windows")
      return ".dll";
    return {};
  }

  String zig_target(const String &platform, const String &architecture)
  {
    String zig_architecture;
    if (architecture == "x86_64")
      zig_architecture = "x86_64";
    else if (architecture == "x86_32")
      zig_architecture = "x86";
    else if (architecture == "arm64")
      zig_architecture = "aarch64";
    else if (architecture == "arm32")
      zig_architecture = "arm";
    else if (architecture == "rv64")
      zig_architecture = "riscv64";
    else if (architecture == "ppc64")
      zig_architecture = "powerpc64le";
    else if (architecture == "loongarch64")
      zig_architecture = "loongarch64";
    else
      return {};

    if (platform == "linux")
      return zig_architecture + "-linux-gnu";
    if (platform == "windows")
      return zig_architecture + "-windows-gnu";
    if (platform == "macos" &&
        (architecture == "x86_64" || architecture == "arm64"))
      return zig_architecture + "-macos";
    return {};
  }
} // namespace

String GzBuildManager::get_zig_executable()
{
  ProjectSettings *settings = ProjectSettings::get_singleton();
  if (settings && settings->has_setting(ZIG_PATH_SETTING))
  {
    String configured = settings->get_setting(ZIG_PATH_SETTING, String());
    if (!configured.is_empty())
    {
      return configured;
    }
  }

  OS *os = OS::get_singleton();
  if (os)
  {
    String from_environment = os->get_environment("GZSCRIPT_ZIG_PATH");
    if (!from_environment.is_empty())
    {
      return from_environment;
    }

    String home = os->get_environment("HOME");
    if (home.is_empty())
      home = os->get_environment("USERPROFILE");
    String executable = os->get_name() == "Windows" ? "zig.exe" : "zig";
    String zvm_path = home.path_join(".zvm/bin").path_join(executable);
    if (!home.is_empty() && FileAccess::file_exists(zvm_path))
      return zvm_path;
    return executable;
  }
  return "zig";
}

void GzBuildManager::_bind_methods()
{
  ClassDB::bind_method(D_METHOD("compile_path", "resource_path"),
                       &GzBuildManager::compile_path);
  ClassDB::bind_method(D_METHOD("compile_all"), &GzBuildManager::compile_all);
  ClassDB::bind_method(D_METHOD("queue_all"), &GzBuildManager::queue_all);
  ClassDB::bind_method(D_METHOD("queue_saved", "script", "saved_path"),
                       &GzBuildManager::queue_saved);
  ClassDB::bind_method(D_METHOD("pump"), &GzBuildManager::pump);
  ClassDB::bind_method(D_METHOD("is_compiling"),
                       &GzBuildManager::is_compiling);
  ClassDB::bind_method(D_METHOD("get_last_diagnostics"),
                       &GzBuildManager::get_last_diagnostics);
  ADD_SIGNAL(MethodInfo("script_compiled"));
}

GzBuildManager::GzBuildManager()
{
  singleton = this;

  ProjectSettings *settings = ProjectSettings::get_singleton();
  if (!settings->has_setting(ZIG_PATH_SETTING))
  {
    settings->set_setting(ZIG_PATH_SETTING, String());
  }
  settings->set_initial_value(ZIG_PATH_SETTING, String());
  settings->set_as_basic(ZIG_PATH_SETTING, true);

  Dictionary zig_property_info;
  zig_property_info["name"] = ZIG_PATH_SETTING;
  zig_property_info["type"] = Variant::STRING;
  zig_property_info["hint"] = PROPERTY_HINT_GLOBAL_FILE;
  settings->add_property_info(zig_property_info);

  if (!settings->has_setting(ZIG_OPTIMIZATION_SETTING))
    settings->set_setting(ZIG_OPTIMIZATION_SETTING, String("Debug"));
  settings->set_initial_value(ZIG_OPTIMIZATION_SETTING, String("Debug"));
  settings->set_as_basic(ZIG_OPTIMIZATION_SETTING, true);

  Dictionary optimization_property_info;
  optimization_property_info["name"] = ZIG_OPTIMIZATION_SETTING;
  optimization_property_info["type"] = Variant::STRING;
  optimization_property_info["hint"] = PROPERTY_HINT_ENUM;
  optimization_property_info["hint_string"] =
      "Debug,ReleaseSafe,ReleaseFast,ReleaseSmall";
  settings->add_property_info(optimization_property_info);
}

GzBuildManager::~GzBuildManager()
{
  if (active)
  {
    gz_terminate_process_tree(active->pid);
    while (OS::get_singleton()->is_process_running(active->pid))
    {
      gz_terminate_process_tree(active->pid);
      OS::get_singleton()->delay_msec(1);
    }
    DirAccess::remove_absolute(active->plan.compile_output);
    DirAccess::remove_absolute(active->plan.generated);
  }
  pending.clear();
  active.reset();
  if (singleton == this)
  {
    singleton = nullptr;
  }
}

bool GzBuildManager::prepare(const String &resource_path, const String &source,
                             uint64_t request_id, CompilePlan &plan)
{
  if (!Thread::is_main_thread())
  {
    UtilityFunctions::printerr(
        "gzscript: Zig scripts must be compiled on the main thread");
    return false;
  }
  last_diagnostics = String();
  String project_root =
      ProjectSettings::get_singleton()->globalize_path("res://");
  String cache_root = project_root.path_join(".godot/gzscript");
  String platform = platform_name();
  String architecture = Engine::get_singleton()->get_architecture_name();
  String target = zig_target(platform, architecture);
  String extension = module_extension(platform);
  if (platform.is_empty() || extension.is_empty() || target.is_empty())
  {
    last_diagnostics = "gzscript runtime compilation does not support target " +
                       platform + "-" + architecture;
    UtilityFunctions::printerr("gzscript: ", last_diagnostics);
    return false;
  }
  String module_directory =
      cache_root.path_join("modules/" + platform + "-" + architecture);
  Error directory_error = DirAccess::make_dir_recursive_absolute(
      cache_root.path_join("generated"));
  if (directory_error == OK)
    directory_error =
        DirAccess::make_dir_recursive_absolute(module_directory);
  if (directory_error != OK)
  {
    last_diagnostics = "Unable to create gzscript cache directories (Error " +
                       String::num_int64(directory_error) + ")";
    UtilityFunctions::printerr("gzscript: ", last_diagnostics);
    return false;
  }

  String source_path =
      ProjectSettings::get_singleton()->globalize_path(resource_path);
  if (!FileAccess::file_exists(source_path))
  {
    last_diagnostics = "Zig script not found: " + source_path;
    UtilityFunctions::printerr("gzscript: ", last_diagnostics);
    return false;
  }
  String normalized_source = normalize_source(source);
  if (normalize_source(FileAccess::get_file_as_string(source_path)) !=
      normalized_source)
  {
    last_diagnostics = "Zig source for " + resource_path +
                       " does not match the file on disk; save it before "
                       "compiling";
    UtilityFunctions::printerr("gzscript: ", last_diagnostics);
    return false;
  }

  ProjectSettings *settings = ProjectSettings::get_singleton();
  String optimization =
      settings->get_setting(ZIG_OPTIMIZATION_SETTING, String("Debug"));
  if (!valid_optimization(optimization))
  {
    last_diagnostics = "Unsupported Zig optimization mode: " + optimization;
    UtilityFunctions::printerr("gzscript: ", last_diagnostics);
    return false;
  }

  String zig_executable = get_zig_executable();
  // ponytail: Cache zig version — spawning a subprocess per prepare() costs ~200-500ms.
  if (cached_zig_executable != zig_executable || cached_zig_version.is_empty())
  {
    String version_result;
    int version_exit = run_process(zig_executable,
                                   PackedStringArray({"version"}),
                                   version_result);
    version_result = version_result.strip_edges();
    if (version_exit != 0 || version_result.is_empty())
    {
      last_diagnostics = "Unable to query Zig compiler version from " +
                         zig_executable + " (exit " +
                         String::num_int64(version_exit) + ")";
      if (!version_result.is_empty())
        last_diagnostics += "\n" + version_result;
      UtilityFunctions::printerr("gzscript: ", last_diagnostics);
      return false;
    }
    cached_zig_executable = zig_executable;
    cached_zig_version = version_result;
  }
  String zig_version = cached_zig_version;
  if (zig_version != "0.16.0")
  {
    last_diagnostics = "Zig " + zig_version +
                       " is incompatible with gzscript; expected Zig 0.16.0";
    UtilityFunctions::printerr("gzscript: ", last_diagnostics);
    return false;
  }

  String user_fingerprint;
  String fingerprint_error;
  if (!append_dependencies(source_path, user_fingerprint, fingerprint_error))
  {
    user_fingerprint = String();
    fingerprint_error = String();
    if (!append_source_tree(source_path.get_base_dir(), String(), true,
                            user_fingerprint, fingerprint_error))
    {
      last_diagnostics = fingerprint_error;
      UtilityFunctions::printerr("gzscript: ", last_diagnostics);
      return false;
    }
  }
  String sdk_fingerprint;
  String sdk_root = zig_path(String());
  if (!append_source_tree(sdk_root, String(), false, sdk_fingerprint,
                          fingerprint_error))
  {
    last_diagnostics = fingerprint_error;
    UtilityFunctions::printerr("gzscript: ", last_diagnostics);
    return {};
  }

  String identity;
  append_identity(identity, "cache_format", CACHE_FORMAT_VERSION);
  append_identity(identity, "resource_path", source_path.simplify_path());
  append_identity(identity, "source", normalized_source);
  append_identity(identity, "user_tree", user_fingerprint);
  append_identity(identity, "sdk_tree", sdk_fingerprint);
  append_identity(identity, "adapter", ADAPTER_SOURCE);
  append_identity(identity, "abi", String::num_int64(GZSCRIPT_ABI_VERSION));
  append_identity(identity, "zig_executable", zig_executable);
  append_identity(identity, "zig_version", zig_version);
  append_identity(identity, "platform", platform);
  append_identity(identity, "architecture", architecture);
  append_identity(identity, "zig_target", target);
  append_identity(identity, "optimization", optimization);
  plan.resource_path = resource_path;
  plan.source = source;
  plan.key = identity.sha256_text();
  plan.generated = cache_root.path_join(
      "generated/script_" + plan.key + "_" +
      String::num_int64(OS::get_singleton()->get_process_id()) + "_" +
      String::num_int64(request_id) + ".zig");
  plan.output =
      module_directory.path_join("script_" + plan.key + extension);
  plan.hash_path = plan.output + ".hash";
  plan.lock_path = plan.output + ".lock";
  plan.stamp_output = plan.hash_path + "." +
                      String::num_int64(OS::get_singleton()->get_process_id()) +
                      "." + String::num_int64(request_id) + ".tmp";

  String source_hash = identity.sha256_text();
  plan.needs_compile =
      !cache_stamp_matches(plan.output, plan.hash_path, source_hash);

  plan.zig_executable = zig_executable;
  plan.compile_output = cache_root.path_join(
      "compile_" + plan.key + "_" +
      String::num_int64(OS::get_singleton()->get_process_id()) + "_" +
      String::num_int64(request_id) + extension);
  String compiler_cache = cache_root.path_join(
      "zig-cache/" +
      String::num_int64(OS::get_singleton()->get_process_id()));
  Error compiler_cache_error =
      DirAccess::make_dir_recursive_absolute(compiler_cache);
  if (compiler_cache_error != OK)
  {
    last_diagnostics = "Unable to create Zig compiler cache directories "
                       "(Error " +
                       String::num_int64(compiler_cache_error) + ")";
    UtilityFunctions::printerr("gzscript: ", last_diagnostics);
    return false;
  }

  plan.arguments.push_back("build-lib");
  plan.arguments.push_back("-dynamic");
  plan.arguments.push_back("-target");
  plan.arguments.push_back(target);
  plan.arguments.push_back("-O");
  plan.arguments.push_back(optimization);
  plan.arguments.push_back("--cache-dir");
  plan.arguments.push_back(compiler_cache);
  plan.arguments.push_back("-femit-bin=" + plan.compile_output);
  plan.arguments.push_back("--dep");
  plan.arguments.push_back("godot");
  plan.arguments.push_back("--dep");
  plan.arguments.push_back("user_script");
  plan.arguments.push_back("-Mroot=" + plan.generated);
  plan.arguments.push_back("--dep");
  plan.arguments.push_back("godot");
  plan.arguments.push_back("-target");
  plan.arguments.push_back(target);
  plan.arguments.push_back("-Muser_script=" + source_path);
  plan.arguments.push_back("-target");
  plan.arguments.push_back(target);
  plan.arguments.push_back("-Mgodot=" + zig_path("godot.zig"));
  plan.source_hash = source_hash;
  return true;
}

std::shared_ptr<GzCompiledModule>
GzBuildManager::finish(const CompilePlan &plan, int exit_code,
                       const String &compiler_output)
{
  DirAccess::remove_absolute(plan.generated);
  DirAccess::remove_absolute(plan.stamp_output);
  last_diagnostics = compiler_output.strip_edges();
  if (exit_code != 0)
  {
    DirAccess::remove_absolute(plan.compile_output);
    last_diagnostics =
        "Compilation failed for " + plan.resource_path + " (exit " +
        String::num_int64(exit_code) + ")" +
        (last_diagnostics.is_empty() ? String()
                                     : String("\n") + last_diagnostics);
    UtilityFunctions::printerr("gzscript: ", last_diagnostics);
    return {};
  }

  if (plan.needs_compile)
  {
    const bool peer_published = cache_stamp_matches(
        plan.output, plan.hash_path, plan.source_hash);
    Error publish_error = OK;
    if (peer_published)
    {
      DirAccess::remove_absolute(plan.compile_output);
    }
    else
    {
      publish_error = gz_atomic_replace(plan.compile_output, plan.output);
    }
    if (publish_error != OK)
    {
      DirAccess::remove_absolute(plan.compile_output);
      last_diagnostics =
          "Failed to publish compiled module " + plan.output + " (Error " +
          String::num_int64(publish_error) + ")";
      UtilityFunctions::printerr("gzscript: ", last_diagnostics);
      return {};
    }
  }

  String error;
  auto module = GzCompiledModule::load(plan.output, error);
  DirAccess::remove_absolute(plan.compile_output);
  if (!module)
  {
    DirAccess::remove_absolute(plan.output);
    last_diagnostics = error;
    UtilityFunctions::printerr("gzscript: ", error);
  }
  else
  {
    last_diagnostics = String();
    // Write hash for fast-path caching
    if (!plan.source_hash.is_empty())
    {
      const String stamp = plan.source_hash + String("\n") +
                           FileAccess::get_sha256(plan.output) + String("\n");
      if (write_text(plan.stamp_output, stamp) &&
          gz_atomic_replace(plan.stamp_output, plan.hash_path) == OK)
      {
        DirAccess::remove_absolute(plan.stamp_output);
      }
      else
      {
        DirAccess::remove_absolute(plan.stamp_output);
        UtilityFunctions::printerr("gzscript: Unable to publish cache stamp ",
                                   plan.hash_path);
      }
    }
  }
  return module;
}

std::shared_ptr<GzCompiledModule>
GzBuildManager::compile(const String &resource_path, const String &source)
{
  wait_for_all();
  for (int attempt = 0; attempt < 3; ++attempt)
  {
    CompilePlan plan;
    if (!prepare(resource_path, source, next_request_id++, plan))
      return {};
    auto cache_lock = std::make_unique<GzFileLock>();
    if (!cache_lock->lock(plan.lock_path, COMPILER_TIMEOUT_MSEC))
    {
      last_diagnostics = cache_lock->get_last_error();
      UtilityFunctions::printerr("gzscript: ", last_diagnostics);
      return {};
    }
    plan.needs_compile =
        !cache_stamp_matches(plan.output, plan.hash_path, plan.source_hash);
    if (!plan.needs_compile)
    {
      auto module = finish(plan, 0, String());
      if (module)
        return module;
      if (FileAccess::file_exists(plan.output))
        return {};
      continue;
    }
    if (!write_text(plan.generated, ADAPTER_SOURCE))
    {
      DirAccess::remove_absolute(plan.generated);
      last_diagnostics =
          "Unable to write generated Zig adapter: " + plan.generated;
      UtilityFunctions::printerr("gzscript: ", last_diagnostics);
      return {};
    }
    DirAccess::remove_absolute(plan.compile_output);
    String compiler_output;
    int exit_code = run_process(plan.zig_executable, plan.arguments,
                                compiler_output);
    if (exit_code != 0)
      return finish(plan, exit_code, compiler_output);

    CompilePlan current;
    if (!prepare(resource_path, source, next_request_id++, current))
    {
      DirAccess::remove_absolute(plan.compile_output);
      DirAccess::remove_absolute(plan.generated);
      return {};
    }
    if (current.key != plan.key)
    {
      DirAccess::remove_absolute(plan.compile_output);
      DirAccess::remove_absolute(plan.generated);
      continue;
    }
    return finish(plan, 0, compiler_output);
  }
  last_diagnostics = "Zig inputs changed repeatedly during compilation";
  UtilityFunctions::printerr("gzscript: ", last_diagnostics);
  return {};
}

void GzBuildManager::queue_compile(const Ref<GzScript> &script)
{
  if (!Thread::is_main_thread())
  {
    UtilityFunctions::printerr(
        "gzscript: Zig compilation must be queued on the main thread");
    return;
  }
  if (script.is_null() || script->get_path().is_empty())
    return;
  if (active && active->request.script.ptr() == script.ptr() &&
      active->request.resource_path == script->get_path() &&
      active->request.source == script->source)
    return;
  for (const CompileRequest &queued : pending)
    if (queued.script.ptr() == script.ptr() &&
        queued.resource_path == script->get_path() &&
        queued.source == script->source)
      return;
  CompileRequest request{script, script->get_path(), script->source,
                         ++script->compile_generation, nullptr};
  for (CompileRequest &queued : pending)
  {
    if (queued.script.ptr() == script.ptr())
    {
      queued = std::move(request);
      return;
    }
  }
  pending.push_back(std::move(request));
}

void GzBuildManager::queue_saved(const Ref<GzScript> &script,
                                 const String &saved_path)
{
  if (script.is_null() || script->get_path().is_empty())
    return;
  ProjectSettings *settings = ProjectSettings::get_singleton();
  const String script_path =
      settings->globalize_path(script->get_path()).simplify_path();
  const String target_path =
      settings->globalize_path(saved_path).simplify_path();
  if (script_path == target_path)
    queue_compile(script);
}

void GzBuildManager::queue_all()
{
  if (!Thread::is_main_thread())
  {
    UtilityFunctions::printerr(
        "gzscript: Zig compilation must be queued on the main thread");
    return;
  }
  for (GzScript *script : GzScript::get_scripts())
  {
    if (script->get_path().is_empty())
      continue;
    script->set_source(FileAccess::get_file_as_string(script->get_path()));
    queue_compile(Ref<GzScript>(script));
  }
}

bool GzBuildManager::is_compiling() const
{
  return Thread::is_main_thread() && (active != nullptr || !pending.empty());
}

void GzBuildManager::start_next()
{
  // ponytail: Serialize builds to avoid cache races and cap Zig memory use.
  while (!active && !pending.empty())
  {
    CompileRequest request = std::move(pending.front());
    pending.pop_front();
    if (request.generation != request.script->compile_generation)
      continue;

    const bool reused_plan = request.prepared != nullptr;
    CompilePlan plan;
    if (reused_plan)
      plan = std::move(*request.prepared);
    else if (!prepare(request.resource_path, request.source, next_request_id++,
                      plan))
    {
      request.script->valid = request.script->module != nullptr;
      request.script->emit_changed();
      continue;
    }
    auto cache_lock = std::make_unique<GzFileLock>();
    const GzFileLock::Result lock_result = cache_lock->try_lock(plan.lock_path);
    if (lock_result == GzFileLock::Result::BUSY)
    {
      request.prepared = std::make_unique<CompilePlan>(std::move(plan));
      pending.push_front(std::move(request));
      return;
    }
    if (lock_result == GzFileLock::Result::ERROR)
    {
      last_diagnostics = cache_lock->get_last_error();
      UtilityFunctions::printerr("gzscript: ", last_diagnostics);
      request.script->valid = request.script->module != nullptr;
      request.script->emit_changed();
      continue;
    }
    if (reused_plan)
    {
      CompilePlan current;
      if (!prepare(request.resource_path, request.source, next_request_id++,
                   current))
      {
        request.script->valid = request.script->module != nullptr;
        request.script->emit_changed();
        continue;
      }
      if (current.key != plan.key)
      {
        cache_lock.reset();
        request.prepared =
            std::make_unique<CompilePlan>(std::move(current));
        pending.push_front(std::move(request));
        return;
      }
      plan = std::move(current);
    }
    plan.needs_compile =
        !cache_stamp_matches(plan.output, plan.hash_path, plan.source_hash);
    if (!plan.needs_compile)
    {
      if (request.script->module &&
          request.script->module->get_path() == plan.output)
      {
        request.script->valid = true;
        continue;
      }
      auto module = finish(plan, 0, String());
      if (module)
      {
        request.script->publish_module(std::move(module));
        emit_signal("script_compiled");
      }
      else
      {
        if (!FileAccess::file_exists(plan.output))
          pending.push_front(std::move(request));
        else
        {
          request.script->valid = request.script->module != nullptr;
          request.script->emit_changed();
        }
      }
      continue;
    }
    if (!write_text(plan.generated, ADAPTER_SOURCE))
    {
      DirAccess::remove_absolute(plan.generated);
      last_diagnostics =
          "Unable to write generated Zig adapter: " + plan.generated;
      UtilityFunctions::printerr("gzscript: ", last_diagnostics);
      request.script->valid = request.script->module != nullptr;
      request.script->emit_changed();
      continue;
    }
    DirAccess::remove_absolute(plan.compile_output);
    Dictionary process = OS::get_singleton()->execute_with_pipe(
        plan.zig_executable, plan.arguments, false);
    if (process.is_empty())
    {
      DirAccess::remove_absolute(plan.generated);
      last_diagnostics = "Unable to start Zig compiler: " + plan.zig_executable;
      UtilityFunctions::printerr("gzscript: ", last_diagnostics);
      request.script->valid = request.script->module != nullptr;
      request.script->emit_changed();
      continue;
    }
    active = std::make_unique<ActiveCompile>();
    active->request = std::move(request);
    active->plan = std::move(plan);
    active->stdout_pipe = process["stdio"];
    active->stderr_pipe = process["stderr"];
    active->pid = process["pid"];
    gz_isolate_process(active->pid);
    active->started_at_msec = Time::get_singleton()->get_ticks_msec();
    active->cache_lock = std::move(cache_lock);
  }
}

void GzBuildManager::drain(const Ref<FileAccess> &pipe, std::string &output,
                           bool &truncated)
{
  if (pipe.is_null())
    return;
  int64_t available = pipe->get_length();
  if (available <= 0)
    return;
  PackedByteArray bytes =
      pipe->get_buffer(std::min<int64_t>(available, PIPE_READ_LIMIT));
  if (bytes.is_empty())
    return;
  const std::size_t remaining = output.size() < COMPILER_OUTPUT_LIMIT
                                    ? COMPILER_OUTPUT_LIMIT - output.size()
                                    : 0;
  const std::size_t retained =
      std::min<std::size_t>(remaining, bytes.size());
  output.append(reinterpret_cast<const char *>(bytes.ptr()), retained);
  truncated = truncated || retained < static_cast<std::size_t>(bytes.size());
}

int GzBuildManager::run_process(const String &executable,
                                const PackedStringArray &arguments,
                                String &output)
{
  Dictionary process =
      OS::get_singleton()->execute_with_pipe(executable, arguments, false);
  if (process.is_empty())
  {
    output = "Unable to start Zig compiler: " + executable;
    return 127;
  }

  Ref<FileAccess> stdout_pipe = process["stdio"];
  Ref<FileAccess> stderr_pipe = process["stderr"];
  const int32_t process_id = process["pid"];
  gz_isolate_process(process_id);
  const uint64_t started_at = Time::get_singleton()->get_ticks_msec();
  std::string retained;
  bool truncated = false;
  bool timed_out = false;
  while (OS::get_singleton()->is_process_running(process_id))
  {
    drain(stdout_pipe, retained, truncated);
    drain(stderr_pipe, retained, truncated);
    if (Time::get_singleton()->get_ticks_msec() - started_at >=
        COMPILER_TIMEOUT_MSEC)
    {
      gz_terminate_process_tree(process_id);
      timed_out = true;
      break;
    }
    OS::get_singleton()->delay_msec(1);
  }

  const uint64_t kill_deadline =
      Time::get_singleton()->get_ticks_msec() + PROCESS_KILL_GRACE_MSEC;
  while (timed_out && OS::get_singleton()->is_process_running(process_id) &&
         Time::get_singleton()->get_ticks_msec() < kill_deadline)
  {
    drain(stdout_pipe, retained, truncated);
    drain(stderr_pipe, retained, truncated);
    OS::get_singleton()->delay_msec(1);
  }
  // Do not release the cache lock or delete files while a timed-out compiler
  // can still write them. SIGKILL/TerminateProcess should make this brief.
  while (timed_out && OS::get_singleton()->is_process_running(process_id))
  {
    gz_terminate_process_tree(process_id);
    drain(stdout_pipe, retained, truncated);
    drain(stderr_pipe, retained, truncated);
    OS::get_singleton()->delay_msec(2);
  }
  drain(stdout_pipe, retained, truncated);
  drain(stderr_pipe, retained, truncated);
  if (stdout_pipe.is_valid())
    stdout_pipe->close();
  if (stderr_pipe.is_valid())
    stderr_pipe->close();
  if (truncated)
    retained += OUTPUT_TRUNCATED;
  if (timed_out)
    retained += "\nZig compiler timed out after " +
                std::to_string(COMPILER_TIMEOUT_MSEC) + " ms";
  output = String::utf8(retained.data(), retained.size());
  return timed_out ? 124
                   : OS::get_singleton()->get_process_exit_code(process_id);
}

void GzBuildManager::pump()
{
  if (!Thread::is_main_thread())
    return;
  start_next();
  if (!active)
    return;
  drain(active->stdout_pipe, active->output, active->output_truncated);
  drain(active->stderr_pipe, active->output, active->output_truncated);
  if (OS::get_singleton()->is_process_running(active->pid))
  {
    if (!active->timed_out &&
        Time::get_singleton()->get_ticks_msec() - active->started_at_msec <
            COMPILER_TIMEOUT_MSEC)
      return;
    if (!active->timed_out)
    {
      active->timed_out = true;
      active->output += "\nZig compiler timed out after " +
                        std::to_string(COMPILER_TIMEOUT_MSEC) + " ms";
    }
    gz_terminate_process_tree(active->pid);
    return;
  }
  drain(active->stdout_pipe, active->output, active->output_truncated);
  drain(active->stderr_pipe, active->output, active->output_truncated);
  complete_active(active->timed_out
                      ? 124
                      : OS::get_singleton()->get_process_exit_code(active->pid));
}

void GzBuildManager::complete_active(int exit_code)
{
  std::unique_ptr<ActiveCompile> completed = std::move(active);
  if (completed->output_truncated)
    completed->output += OUTPUT_TRUNCATED;
  if (completed->stdout_pipe.is_valid())
    completed->stdout_pipe->close();
  if (completed->stderr_pipe.is_valid())
    completed->stderr_pipe->close();
  Ref<GzScript> script = completed->request.script;
  if (completed->request.generation != script->compile_generation)
  {
    DirAccess::remove_absolute(completed->plan.compile_output);
    DirAccess::remove_absolute(completed->plan.generated);
    start_next();
    return;
  }

  if (exit_code == 0)
  {
    bool stale = false;
    for (const CompileRequest &queued : pending)
    {
      if (queued.script.ptr() == script.ptr())
      {
        stale = true;
        break;
      }
    }
    if (stale)
    {
      DirAccess::remove_absolute(completed->plan.compile_output);
      DirAccess::remove_absolute(completed->plan.generated);
      start_next();
      return;
    }

    CompilePlan current;
    if (!prepare(completed->request.resource_path, completed->request.source,
                 next_request_id++, current))
    {
      DirAccess::remove_absolute(completed->plan.compile_output);
      DirAccess::remove_absolute(completed->plan.generated);
      script->valid = script->module != nullptr;
      script->emit_changed();
      start_next();
      return;
    }
    if (current.key != completed->plan.key)
    {
      DirAccess::remove_absolute(completed->plan.compile_output);
      DirAccess::remove_absolute(completed->plan.generated);
      pending.push_front(std::move(completed->request));
      start_next();
      return;
    }
  }

  auto module = finish(completed->plan, exit_code,
                       String::utf8(completed->output.data(),
                                    completed->output.size()));
  // ponytail: Load modules and mutate Script state only on Godot's main thread.
  if (module)
  {
    script->publish_module(std::move(module));
    emit_signal("script_compiled");
  }
  else
  {
    script->valid = script->module != nullptr;
    script->emit_changed();
  }
  start_next();
}

void GzBuildManager::wait_for_all()
{
  if (!Thread::is_main_thread())
    return;
  while (is_compiling())
  {
    pump();
    if (is_compiling())
      OS::get_singleton()->delay_msec(1);
  }
}

bool GzBuildManager::compile_path(const String &resource_path)
{
  bool success = compile(resource_path,
                         FileAccess::get_file_as_string(resource_path)) != nullptr;
  if (success)
    emit_signal("script_compiled");
  return success;
}

bool GzBuildManager::compile_all()
{
  wait_for_all();
  last_diagnostics = String();
  bool success = true;
  String diagnostics;
  for (GzScript *script : GzScript::get_scripts())
  {
    if (script->get_path().is_empty())
      continue;
    script->set_source(FileAccess::get_file_as_string(script->get_path()));
    if (script->reload(false) != OK)
    {
      success = false;
      if (!diagnostics.is_empty())
        diagnostics += "\n\n";
      diagnostics += script->get_path() + ":\n" + last_diagnostics;
    }
  }
  if (!success)
    last_diagnostics = diagnostics;
  return success;
}
