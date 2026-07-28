#include "gz_lsp_client.hpp"

#include "gz_build_manager.hpp"
#include "gz_language.hpp"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstdlib>

using namespace godot;

namespace
{
  constexpr const char *ZLS_PATH_SETTING =
      "gzscript/language_server/zls_path";
  constexpr uint64_t INITIALIZE_TIMEOUT_MSEC = 5'000;
  constexpr uint64_t REQUEST_TIMEOUT_MSEC = 5'000;
  constexpr uint64_t RESTART_BACKOFF_MSEC = 1'000;
  constexpr std::size_t STDERR_LIMIT = 16 * 1024;

  std::string key(const String &value)
  {
    CharString utf8 = value.utf8();
    return std::string(utf8.get_data(), utf8.length());
  }

  String zls_executable()
  {
    ProjectSettings *settings = ProjectSettings::get_singleton();
    String configured = settings->get_setting(ZLS_PATH_SETTING, String());
    if (!configured.is_empty())
      return configured;
    String environment = OS::get_singleton()->get_environment(
        "GZSCRIPT_ZLS_PATH");
    if (!environment.is_empty())
      return environment;

    OS *os = OS::get_singleton();
    String home = os->get_environment("HOME");
    if (home.is_empty())
      home = os->get_environment("USERPROFILE");
    String executable = os->get_name() == "Windows" ? "zls.exe" : "zls";
    String zvm_path = home.path_join(".zvm/bin").path_join(executable);
    if (!home.is_empty() && FileAccess::file_exists(zvm_path))
      return zvm_path;
    return executable;
  }

  Dictionary zls_configuration()
  {
    Dictionary configuration;
    configuration["zig_exe_path"] = GzBuildManager::get_zig_executable();
    configuration["enable_snippets"] = false;
    configuration["enable_argument_placeholders"] = false;
    configuration["enable_build_on_save"] = false;
    configuration["semantic_tokens"] = "none";
    return configuration;
  }

  int32_t completion_kind(int64_t kind)
  {
    switch (kind)
    {
    case 2:
    case 3:
    case 4:
      return GzLanguage::CODE_COMPLETION_KIND_FUNCTION;
    case 5:
    case 10:
      return GzLanguage::CODE_COMPLETION_KIND_MEMBER;
    case 6:
      return GzLanguage::CODE_COMPLETION_KIND_VARIABLE;
    case 7:
    case 8:
    case 9:
      return GzLanguage::CODE_COMPLETION_KIND_CLASS;
    case 13:
      return GzLanguage::CODE_COMPLETION_KIND_ENUM;
    case 14:
      return GzLanguage::CODE_COMPLETION_KIND_KEYWORD;
    case 20:
    case 21:
      return GzLanguage::CODE_COMPLETION_KIND_CONSTANT;
    default:
      return GzLanguage::CODE_COMPLETION_KIND_PLAIN_TEXT;
    }
  }
} // namespace

GzLspClient::GzLspClient(GzLanguage *owner) : language(owner)
{
  ProjectSettings *settings = ProjectSettings::get_singleton();
  if (!settings->has_setting(ZLS_PATH_SETTING))
    settings->set_setting(ZLS_PATH_SETTING, String());
  settings->set_initial_value(ZLS_PATH_SETTING, String());
  settings->set_as_basic(ZLS_PATH_SETTING, true);

  Dictionary property;
  property["name"] = ZLS_PATH_SETTING;
  property["type"] = Variant::STRING;
  property["hint"] = PROPERTY_HINT_GLOBAL_FILE;
  settings->add_property_info(property);
}

GzLspClient::~GzLspClient()
{
  if (pid > 0 && OS::get_singleton()->is_process_running(pid))
    OS::get_singleton()->kill(pid);
  if (stdio_pipe.is_valid())
    stdio_pipe->close();
  if (stderr_pipe.is_valid())
    stderr_pipe->close();
}

GzLspClient::Query GzLspClient::make_query(const String &code,
                                           const String &path)
{
  Query query;
  query.code = code;
  query.path = path;
  query.uri = path_to_uri(path);
  int64_t caret = code.find(String::chr(0xFFFF));
  if (caret < 0)
    caret = code.length();
  query.source = code.remove_char(0xFFFF);
  for (int64_t index = 0; index < caret; ++index)
  {
    char32_t character = code[index];
    if (character == '\n')
    {
      ++query.line;
      query.character = 0;
    }
    else
    {
      // LSP positions use UTF-16 code units.
      query.character += character > 0xFFFF ? 2 : 1;
    }
  }
  return query;
}

Dictionary GzLspClient::position(const Query &query)
{
  Dictionary result;
  result["line"] = query.line;
  result["character"] = query.character;
  return result;
}

bool GzLspClient::same_query(const Query &left, const Query &right)
{
  return left.uri == right.uri && left.source == right.source &&
         left.line == right.line && left.character == right.character;
}

String GzLspClient::path_to_uri(const String &path)
{
  String absolute = ProjectSettings::get_singleton()
                        ->globalize_path(path)
                        .replace("\\", "/");
  String encoded = absolute.uri_encode()
                       .replace("%2F", "/")
                       .replace("%3A", ":");
  if (absolute.begins_with("//"))
    return "file:" + encoded;
  return (absolute.begins_with("/") ? String("file://")
                                     : String("file:///")) + encoded;
}

String GzLspClient::uri_to_path(const String &uri)
{
  if (!uri.begins_with("file://"))
    return {};
  String payload = uri.trim_prefix("file://");
  String absolute = (payload.begins_with("/") ? payload : "//" + payload)
                        .uri_decode();
  if (OS::get_singleton()->get_name() == "Windows" &&
      absolute.length() >= 3 && absolute[0] == '/' && absolute[2] == ':')
    absolute = absolute.substr(1);
  return ProjectSettings::get_singleton()->localize_path(absolute);
}

void GzLspClient::drain(const Ref<FileAccess> &pipe, std::string &output)
{
  if (pipe.is_null())
    return;
  int64_t available = pipe->get_length();
  if (available <= 0)
    return;
  PackedByteArray bytes = pipe->get_buffer(available);
  if (!bytes.is_empty())
    output.append(reinterpret_cast<const char *>(bytes.ptr()), bytes.size());
}

bool GzLspClient::start()
{
  if (state == State::READY || state == State::INITIALIZING)
    return true;
  if (state == State::FAILED)
  {
    if (consecutive_restarts >= 1 ||
        Time::get_singleton()->get_ticks_msec() - failed_at_msec <
            RESTART_BACKOFF_MSEC)
      return false;
    ++consecutive_restarts;
    state = State::STOPPED;
  }

  Dictionary process = OS::get_singleton()->execute_with_pipe(
      zls_executable(), PackedStringArray(), false);
  if (process.is_empty())
  {
    fail("Unable to start ZLS. Configure " + String(ZLS_PATH_SETTING) + ".");
    return false;
  }
  stdio_pipe = process["stdio"];
  stderr_pipe = process["stderr"];
  pid = process["pid"];
  state = State::INITIALIZING;
  started_at_msec = Time::get_singleton()->get_ticks_msec();

  Dictionary capabilities;
  Dictionary completion_item;
  completion_item["snippetSupport"] = false;
  Dictionary completion;
  completion["completionItem"] = completion_item;
  Dictionary text_document;
  text_document["completion"] = completion;
  text_document["definition"] = Dictionary();
  capabilities["textDocument"] = text_document;

  Dictionary params;
  params["processId"] = OS::get_singleton()->get_process_id();
  params["rootUri"] = path_to_uri("res://");
  Dictionary workspace;
  workspace["uri"] = params["rootUri"];
  workspace["name"] = ProjectSettings::get_singleton()->get_setting(
      "application/config/name", String("Godot Project"));
  Array workspaces;
  workspaces.push_back(workspace);
  params["workspaceFolders"] = workspaces;
  params["capabilities"] = capabilities;
  params["initializationOptions"] = zls_configuration();
  request("initialize", params,
          Request{Request::Kind::INITIALIZE, Query()});
  return true;
}

void GzLspClient::fail(const String &message)
{
  if (state != State::FAILED)
    UtilityFunctions::printerr("gzscript: ", message);
  state = State::FAILED;
  failed_at_msec = Time::get_singleton()->get_ticks_msec();
  has_pending_completion = false;
  has_pending_definition = false;
  requests.clear();
  documents.clear();
  if (pid > 0 && OS::get_singleton()->is_process_running(pid))
    OS::get_singleton()->kill(pid);
  pid = -1;
  if (stdio_pipe.is_valid())
    stdio_pipe->close();
  if (stderr_pipe.is_valid())
    stderr_pipe->close();
  stdio_pipe.unref();
  stderr_pipe.unref();
  input.clear();
}

void GzLspClient::send(const Dictionary &message)
{
  if (stdio_pipe.is_null())
    return;
  CharString body = JSON::stringify(message).utf8();
  std::string frame = "Content-Length: " +
                      std::to_string(body.length()) + "\r\n\r\n";
  frame.append(body.get_data(), body.length());
  stdio_pipe->store_buffer(
      reinterpret_cast<const uint8_t *>(frame.data()), frame.size());
  stdio_pipe->flush();
}

int64_t GzLspClient::request(const String &method, const Variant &params,
                             Request pending)
{
  int64_t id = next_request_id++;
  Dictionary message;
  message["jsonrpc"] = "2.0";
  message["id"] = id;
  message["method"] = method;
  message["params"] = params;
  pending.sent_at_msec = Time::get_singleton()->get_ticks_msec();
  requests.emplace(id, std::move(pending));
  send(message);
  return id;
}

void GzLspClient::notify(const String &method, const Variant &params)
{
  Dictionary message;
  message["jsonrpc"] = "2.0";
  message["method"] = method;
  message["params"] = params;
  send(message);
}

void GzLspClient::synchronize(const Query &query)
{
  auto [iterator, inserted] = documents.try_emplace(key(query.uri));
  Document &document = iterator->second;
  if (!inserted && document.source == query.source)
    return;
  document.source = query.source;
  ++document.version;

  Dictionary text_document;
  text_document["uri"] = query.uri;
  text_document["version"] = document.version;
  Dictionary params;
  if (inserted)
  {
    text_document["languageId"] = "zig";
    text_document["text"] = query.source;
    params["textDocument"] = text_document;
    notify("textDocument/didOpen", params);
    return;
  }

  Dictionary change;
  change["text"] = query.source;
  Array changes;
  changes.push_back(change);
  params["textDocument"] = text_document;
  params["contentChanges"] = changes;
  notify("textDocument/didChange", params);
}

void GzLspClient::send_completion(const Query &query)
{
  synchronize(query);
  Dictionary text_document;
  text_document["uri"] = query.uri;
  Dictionary params;
  params["textDocument"] = text_document;
  params["position"] = position(query);
  request("textDocument/completion", params,
          Request{Request::Kind::COMPLETION, query});
}

void GzLspClient::send_definition(const Query &query)
{
  synchronize(query);
  Dictionary text_document;
  text_document["uri"] = query.uri;
  Dictionary params;
  params["textDocument"] = text_document;
  params["position"] = position(query);
  request("textDocument/definition", params,
          Request{Request::Kind::DEFINITION, query});
}

Array GzLspClient::completion_options(const Variant &result)
{
  Array items;
  if (result.get_type() == Variant::ARRAY)
    items = result;
  else if (result.get_type() == Variant::DICTIONARY)
  {
    Dictionary list = result;
    Variant value = list.get("items", Array());
    if (value.get_type() == Variant::ARRAY)
      items = value;
  }

  Array options;
  for (int64_t index = 0; index < items.size(); ++index)
  {
    if (items[index].get_type() != Variant::DICTIONARY)
      continue;
    Dictionary item = items[index];
    String display = item.get("label", String());
    String insertion = item.get("insertText", display);
    Variant edit_value = item.get("textEdit", Variant());
    if (edit_value.get_type() == Variant::DICTIONARY)
    {
      Dictionary edit = edit_value;
      insertion = edit.get("newText", insertion);
    }
    if (display.is_empty() || insertion.is_empty() ||
        int64_t(item.get("insertTextFormat", 1)) == 2)
      continue;

    Dictionary option;
    option["kind"] = completion_kind(item.get("kind", 1));
    option["display"] = display;
    option["insert_text"] = insertion;
    option["font_color"] = Color(1, 1, 1, 1);
    option["icon"] = Variant();
    option["default_value"] = Variant();
    option["location"] = GzLanguage::LOCATION_OTHER_USER_CODE;
    options.push_back(option);
  }
  return options;
}

Dictionary GzLspClient::definition_result(const Variant &result)
{
  Variant location_value = result;
  if (result.get_type() == Variant::ARRAY)
  {
    Array locations = result;
    if (locations.is_empty())
      return {};
    location_value = locations[0];
  }
  if (location_value.get_type() != Variant::DICTIONARY)
    return {};
  Dictionary location = location_value;
  String uri = location.get("uri", String());
  Dictionary range = location.get("range", Dictionary());
  Dictionary start = range.get("start", Dictionary());
  if (uri.is_empty() || !start.has("line"))
    return {};
  Dictionary definition;
  definition["script_path"] = uri_to_path(uri);
  definition["location"] = int64_t(start["line"]) + 1;
  return definition;
}

void GzLspClient::handle_response(int64_t id, const Dictionary &message)
{
  auto iterator = requests.find(id);
  if (iterator == requests.end())
    return;
  Request pending = std::move(iterator->second);
  requests.erase(iterator);
  if (message.has("error"))
  {
    if (pending.kind == Request::Kind::COMPLETION &&
        same_query(pending.query, pending_completion))
      has_pending_completion = false;
    if (pending.kind == Request::Kind::DEFINITION &&
        same_query(pending.query, pending_definition))
      has_pending_definition = false;
    return;
  }
  Variant result = message.get("result", Variant());

  if (pending.kind == Request::Kind::INITIALIZE)
  {
    if (result.get_type() == Variant::DICTIONARY)
    {
      Dictionary initialize_result = result;
      Dictionary server = initialize_result.get("serverInfo", Dictionary());
      String version = server.get("version", String());
      if (!version.is_empty() && !version.begins_with("0.16."))
      {
        fail("ZLS " + version +
             " is incompatible with gzscript's Zig 0.16 toolchain");
        return;
      }
    }
    Dictionary initialized;
    notify("initialized", initialized);
    state = State::READY;
    consecutive_restarts = 0;
    if (has_pending_completion)
      send_completion(pending_completion);
    if (has_pending_definition)
      send_definition(pending_definition);
    return;
  }
  if (pending.kind == Request::Kind::COMPLETION)
  {
    if (!has_pending_completion ||
        !same_query(pending.query, pending_completion))
      return;
    cached_completion_query = pending.query;
    cached_completion_options = completion_options(result);
    has_cached_completion = true;
    has_pending_completion = false;
    language->emit_signal("completion_ready", pending.query.path);
    return;
  }
  if (!has_pending_definition ||
      !same_query(pending.query, pending_definition))
    return;
  cached_definition_query = pending.query;
  cached_definition = definition_result(result);
  has_cached_definition = true;
  has_pending_definition = false;
}

void GzLspClient::handle_server_request(const Dictionary &message)
{
  Dictionary response;
  response["jsonrpc"] = "2.0";
  response["id"] = message["id"];
  String method = message.get("method", String());
  if (method == "workspace/configuration")
  {
    Dictionary params = message.get("params", Dictionary());
    Array items = params.get("items", Array());
    Array configurations;
    for (int64_t index = 0; index < items.size(); ++index)
      configurations.push_back(zls_configuration());
    response["result"] = configurations;
  }
  else
  {
    response["result"] = Variant();
  }
  send(response);
}

void GzLspClient::handle(const Dictionary &message)
{
  if (message.has("method") && message.has("id"))
  {
    handle_server_request(message);
    return;
  }
  if (message.has("id"))
    handle_response(message["id"], message);
}

void GzLspClient::parse_messages()
{
  while (true)
  {
    std::size_t header_end = input.find("\r\n\r\n");
    if (header_end == std::string::npos)
      return;
    std::size_t length_start = input.find("Content-Length:");
    if (length_start == std::string::npos || length_start > header_end)
    {
      input.erase(0, header_end + 4);
      continue;
    }
    length_start += 15;
    while (length_start < header_end && input[length_start] == ' ')
      ++length_start;
    char *end = nullptr;
    unsigned long length = std::strtoul(input.c_str() + length_start, &end, 10);
    if (end == input.c_str() + length_start)
    {
      input.erase(0, header_end + 4);
      continue;
    }
    std::size_t body_start = header_end + 4;
    if (input.size() - body_start < length)
      return;
    String body = String::utf8(input.data() + body_start, length);
    input.erase(0, body_start + length);
    Variant parsed = JSON::parse_string(body);
    if (parsed.get_type() == Variant::DICTIONARY)
      handle(parsed);
  }
}

Array GzLspClient::complete(const String &code, const String &path)
{
  if (path.is_empty())
    return {};
  Query query = make_query(code, path);
  if (has_cached_completion && same_query(query, cached_completion_query))
    return cached_completion_options;
  if (has_pending_completion && same_query(query, pending_completion))
    return {};
  pending_completion = query;
  has_pending_completion = true;
  if (start() && state == State::READY)
    send_completion(query);
  return {};
}

Dictionary GzLspClient::lookup(const String &code, const String &path)
{
  if (path.is_empty())
    return {};
  Query query = make_query(code, path);
  if (has_cached_definition && same_query(query, cached_definition_query))
    return cached_definition;
  if (has_pending_definition && same_query(query, pending_definition))
    return {};
  pending_definition = query;
  has_pending_definition = true;
  if (start() && state == State::READY)
    send_definition(query);
  return {};
}

void GzLspClient::pump()
{
  if (state != State::INITIALIZING && state != State::READY)
    return;
  drain(stdio_pipe, input);
  drain(stderr_pipe, stderr_output);
  if (stderr_output.size() > STDERR_LIMIT)
    stderr_output.erase(0, stderr_output.size() - STDERR_LIMIT);
  parse_messages();
  if (!OS::get_singleton()->is_process_running(pid))
  {
    fail("ZLS exited unexpectedly" +
         (stderr_output.empty()
              ? String()
              : String("\n") + String::utf8(stderr_output.data(),
                                             stderr_output.size())));
    return;
  }
  if (state == State::INITIALIZING &&
      Time::get_singleton()->get_ticks_msec() - started_at_msec >=
          INITIALIZE_TIMEOUT_MSEC)
  {
    fail("ZLS initialization timed out");
    return;
  }

  uint64_t now = Time::get_singleton()->get_ticks_msec();
  for (auto iterator = requests.begin(); iterator != requests.end();)
  {
    const Request &pending = iterator->second;
    if (pending.kind == Request::Kind::INITIALIZE ||
        now - pending.sent_at_msec < REQUEST_TIMEOUT_MSEC)
    {
      ++iterator;
      continue;
    }
    if (pending.kind == Request::Kind::COMPLETION &&
        same_query(pending.query, pending_completion))
      has_pending_completion = false;
    if (pending.kind == Request::Kind::DEFINITION &&
        same_query(pending.query, pending_definition))
      has_pending_definition = false;
    iterator = requests.erase(iterator);
  }
}
