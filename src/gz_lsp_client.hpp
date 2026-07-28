#pragma once

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <string>
#include <unordered_map>

class GzLanguage;

class GzLspClient
{
  enum class State
  {
    STOPPED,
    INITIALIZING,
    READY,
    FAILED,
  };

  struct Query
  {
    godot::String code;
    godot::String path;
    godot::String source;
    godot::String uri;
    int32_t line = 0;
    int32_t character = 0;
  };

  struct Document
  {
    godot::String source;
    int32_t version = 0;
  };

  struct Request
  {
    enum class Kind
    {
      INITIALIZE,
      COMPLETION,
      DEFINITION,
    } kind;
    Query query;
    uint64_t sent_at_msec = 0;
  };

  GzLanguage *language = nullptr;
  State state = State::STOPPED;
  godot::Ref<godot::FileAccess> stdio_pipe;
  godot::Ref<godot::FileAccess> stderr_pipe;
  std::string input;
  std::string stderr_output;
  int32_t pid = -1;
  int64_t next_request_id = 1;
  uint64_t started_at_msec = 0;
  uint64_t failed_at_msec = 0;
  uint64_t completion_due_msec = 0;
  int32_t consecutive_restarts = 0;
  std::unordered_map<int64_t, Request> requests;
  std::unordered_map<std::string, Document> documents;
  Query pending_completion;
  Query pending_definition;
  Query cached_completion_query;
  Query cached_definition_query;
  godot::Array cached_completion_options;
  godot::Dictionary cached_definition;
  bool has_pending_completion = false;
  bool completion_in_flight = false;
  bool has_pending_definition = false;
  bool has_cached_completion = false;
  bool has_cached_definition = false;

  static Query make_query(const godot::String &code,
                          const godot::String &path);
  static godot::Dictionary position(const Query &query);
  static bool same_query(const Query &left, const Query &right);
  static godot::String path_to_uri(const godot::String &path);
  static godot::String uri_to_path(const godot::String &uri);
  static godot::Array completion_options(const godot::Variant &result);
  static godot::Dictionary definition_result(const godot::Variant &result);
  static void drain(const godot::Ref<godot::FileAccess> &pipe,
                    std::string &output);

  bool start();
  void fail(const godot::String &message);
  void send(const godot::Dictionary &message);
  int64_t request(const godot::String &method, const godot::Variant &params,
                  Request request);
  void notify(const godot::String &method, const godot::Variant &params);
  void synchronize(const Query &query);
  void send_completion(const Query &query);
  void send_definition(const Query &query);
  void handle(const godot::Dictionary &message);
  void handle_response(int64_t id, const godot::Dictionary &message);
  void handle_server_request(const godot::Dictionary &message);
  void parse_messages();

public:
  explicit GzLspClient(GzLanguage *owner);
  ~GzLspClient();

  godot::Array complete(const godot::String &code,
                        const godot::String &path);
  godot::Dictionary lookup(const godot::String &code,
                           const godot::String &path);
  void pump();
};
