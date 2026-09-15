// Path normalization: identity, separators, dot segments, URIs, schemes.
#include "diagnostics/gz_diagnostic_path.hpp"
#include "test_helpers.hpp"

#include <string>

namespace {

void test_basic_identity() {
  GZ_CHECK_EQ_STR(gz_normalize_document_path("/game/scripts/player.zig"),
                  "/game/scripts/player.zig");
  GZ_CHECK_EQ_STR(gz_normalize_document_path("scripts/player.zig"),
                  "scripts/player.zig");
}

void test_duplicate_separators() {
  GZ_CHECK_EQ_STR(gz_normalize_document_path("/game//scripts///player.zig"),
                  "/game/scripts/player.zig");
}

void test_dot_segments() {
  GZ_CHECK_EQ_STR(gz_normalize_document_path("/game/./scripts/player.zig"),
                  "/game/scripts/player.zig");
  GZ_CHECK_EQ_STR(gz_normalize_document_path("/game/a/../scripts/player.zig"),
                  "/game/scripts/player.zig");
  GZ_CHECK_EQ_STR(gz_normalize_document_path("a/./b/../c.zig"), "a/c.zig");
}

void test_trailing_slash() {
  GZ_CHECK_EQ_STR(gz_normalize_document_path("/game/scripts/"),
                  "/game/scripts");
}

void test_file_uri() {
  GZ_CHECK_EQ_STR(gz_normalize_document_path("file:///game/scripts/p.zig"),
                  "/game/scripts/p.zig");
  GZ_CHECK_EQ_STR(gz_normalize_document_path("file:///game/my%20dir/p.zig"),
                  "/game/my dir/p.zig");
}

void test_scheme_preserved() {
  // res:// mapping is the Godot adapter's job; normalization must not
  // mangle the scheme.
  GZ_CHECK_EQ_STR(gz_normalize_document_path("res://scripts/player.zig"),
                  "res://scripts/player.zig");
  GZ_CHECK_EQ_STR(gz_normalize_document_path("res://a/./b.zig"),
                  "res://a/b.zig");
}

void test_equivalent_forms_agree() {
  const std::string canonical =
      gz_normalize_document_path("/game/scripts/player.zig");
  GZ_CHECK_EQ_STR(gz_normalize_document_path("/game/./scripts//player.zig"),
                  canonical);
  GZ_CHECK_EQ_STR(gz_normalize_document_path("file:///game/scripts/player.zig"),
                  canonical);
}

void test_idempotent() {
  const std::string once =
      gz_normalize_document_path("/game/a/../b/./c.zig");
  GZ_CHECK_EQ_STR(gz_normalize_document_path(once), once);
}

void test_windows_forms() {
#ifdef _WIN32
  GZ_CHECK_EQ_STR(gz_normalize_document_path("C:\\Project\\scripts\\foo.zig"),
                  "C:/Project/scripts/foo.zig");
  GZ_CHECK_EQ_STR(
      gz_normalize_document_path("c:/Project/scripts/foo.zig"),
      "C:/Project/scripts/foo.zig");
  GZ_CHECK_EQ_STR(gz_normalize_document_path("file:///C:/Project/f.zig"),
                  "C:/Project/f.zig");
#else
  // Documented: backslashes are only separators on Windows.
  GZ_CHECK_EQ_STR(gz_normalize_document_path("/game/a\\b.zig"),
                  "/game/a\\b.zig");
#endif
}

void run_all_tests() {
  test_basic_identity();
  test_duplicate_separators();
  test_dot_segments();
  test_trailing_slash();
  test_file_uri();
  test_scheme_preserved();
  test_equivalent_forms_agree();
  test_idempotent();
  test_windows_forms();
}

} // namespace

GZ_TEST_MAIN("diagnostics/paths")
