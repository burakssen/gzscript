// Store: replacement, clearing, source/document isolation, removal.
#include "diagnostics/gz_diagnostic_store.hpp"
#include "test_helpers.hpp"

#include <string>
#include <vector>

namespace {

GzDiagnostic make_diag(const std::string &message, uint32_t line,
                       GzDiagnosticSource source) {
  GzDiagnostic diagnostic;
  diagnostic.document_path = "/game/player.zig";
  diagnostic.range.start = {line, 0};
  diagnostic.range.end = {line, 0};
  diagnostic.origin.kind = source;
  diagnostic.message = message;
  return diagnostic;
}

GzDiagnosticUpdate make_update(const std::string &path, uint64_t generation,
                               GzDiagnosticSource source,
                               std::vector<GzDiagnostic> diagnostics) {
  GzDiagnosticUpdate update;
  update.document_path = path;
  update.generation = generation;
  update.source = source;
  update.diagnostics = std::move(diagnostics);
  return update;
}

void test_replace_means_replace() {
  GzDiagnosticStore store;
  GZ_CHECK(store.open_document("/game/player.zig") == 1);
  GZ_CHECK(store.replace(make_update("/game/player.zig", 1,
                                      GzDiagnosticSource::Zls,
                                      {make_diag("error A", 1,
                                                 GzDiagnosticSource::Zls)})) ==
           GzDiagnosticUpdateResult::Applied);
  GzDiagnosticSnapshot first = store.snapshot("/game/player.zig");
  GZ_CHECK(first.diagnostics.size() == 1);
  GZ_CHECK(store.replace(make_update("/game/player.zig", 1,
                                      GzDiagnosticSource::Zls,
                                      {make_diag("warning B", 2,
                                                 GzDiagnosticSource::Zls)})) ==
           GzDiagnosticUpdateResult::Applied);
  GzDiagnosticSnapshot second = store.snapshot("/game/player.zig");
  GZ_CHECK(second.diagnostics.size() == 1);
  GZ_CHECK(second.diagnostics[0].message == "warning B");
}

void test_empty_replacement_clears() {
  GzDiagnosticStore store;
  store.open_document("/game/player.zig");
  store.replace(make_update("/game/player.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("error A", 1,
                                       GzDiagnosticSource::Zls)}));
  GZ_CHECK(store.replace(make_update("/game/player.zig", 1,
                                      GzDiagnosticSource::Zls, {})) ==
           GzDiagnosticUpdateResult::Applied);
  GZ_CHECK(store.snapshot("/game/player.zig").diagnostics.empty());
}

void test_source_isolation() {
  GzDiagnosticStore store;
  store.open_document("/game/player.zig");
  store.replace(make_update("/game/player.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("warning A", 1,
                                       GzDiagnosticSource::Zls)}));
  store.replace(make_update("/game/player.zig", 1,
                            GzDiagnosticSource::ZigCompiler,
                            {make_diag("error B", 2,
                                       GzDiagnosticSource::ZigCompiler)}));
  GZ_CHECK(store.snapshot("/game/player.zig").diagnostics.size() == 2);
  store.clear_source("/game/player.zig", GzDiagnosticSource::Zls);
  GzDiagnosticSnapshot after = store.snapshot("/game/player.zig");
  GZ_CHECK(after.diagnostics.size() == 1);
  GZ_CHECK(after.diagnostics[0].message == "error B");
  GzDiagnosticSnapshot zls_only =
      store.snapshot_source("/game/player.zig", GzDiagnosticSource::Zls);
  GZ_CHECK(zls_only.diagnostics.empty());
  GzDiagnosticSnapshot compiler_only = store.snapshot_source(
      "/game/player.zig", GzDiagnosticSource::ZigCompiler);
  GZ_CHECK(compiler_only.diagnostics.size() == 1);
}

void test_document_isolation() {
  GzDiagnosticStore store;
  store.open_document("/game/foo.zig");
  store.open_document("/game/bar.zig");
  store.replace(make_update("/game/foo.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("error A", 1,
                                       GzDiagnosticSource::Zls)}));
  store.replace(make_update("/game/bar.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("warning B", 1,
                                       GzDiagnosticSource::Zls)}));
  store.clear_document("/game/foo.zig");
  GZ_CHECK(store.snapshot("/game/foo.zig").diagnostics.empty());
  GZ_CHECK(store.snapshot("/game/bar.zig").diagnostics.size() == 1);
  // Clearing keeps generation tracking: the document is still known.
  GZ_CHECK(store.current_generation("/game/foo.zig") == 1);
}

void test_remove_document() {
  GzDiagnosticStore store;
  store.open_document("/game/foo.zig");
  store.replace(make_update("/game/foo.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("error A", 1,
                                       GzDiagnosticSource::Zls)}));
  store.remove_document("/game/foo.zig");
  GZ_CHECK(store.snapshot("/game/foo.zig").diagnostics.empty());
  GZ_CHECK(store.current_generation("/game/foo.zig") == 0);
  GZ_CHECK(store.tracked_document_count() == 0);
}

void test_unknown_document_rejected() {
  GzDiagnosticStore store;
  GZ_CHECK(store.replace(make_update("/game/ghost.zig", 1,
                                      GzDiagnosticSource::Zls,
                                      {make_diag("error A", 1,
                                                 GzDiagnosticSource::Zls)})) ==
           GzDiagnosticUpdateResult::UnknownDocument);
  GZ_CHECK(store.tracked_document_count() == 0);
  GZ_CHECK(store.stats().unknown_rejected == 1);
}

void test_clear_all_from_source() {
  GzDiagnosticStore store;
  store.open_document("/game/a.zig");
  store.open_document("/game/b.zig");
  store.replace(make_update("/game/a.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("a", 1, GzDiagnosticSource::Zls)}));
  store.replace(make_update("/game/b.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("b", 1, GzDiagnosticSource::Zls)}));
  store.replace(make_update("/game/b.zig", 1,
                            GzDiagnosticSource::ZigCompiler,
                            {make_diag("c", 1,
                                       GzDiagnosticSource::ZigCompiler)}));
  store.clear_all_from_source(GzDiagnosticSource::Zls);
  GZ_CHECK(store.snapshot("/game/a.zig").diagnostics.empty());
  GZ_CHECK(store.snapshot("/game/b.zig").diagnostics.size() == 1);
}

void test_origin_name_defaults() {
  GzDiagnosticStore store;
  store.open_document("/game/player.zig");
  GzDiagnostic without_name;
  without_name.document_path = "/game/player.zig";
  without_name.range.start = {0, 0};
  without_name.range.end = {0, 0};
  without_name.origin.kind = GzDiagnosticSource::ZigCompiler;
  without_name.message = "broken";
  store.replace(
      make_update("/game/player.zig", 1, GzDiagnosticSource::ZigCompiler,
                  {without_name}));
  GzDiagnosticSnapshot snapshot = store.snapshot("/game/player.zig");
  GZ_CHECK(snapshot.diagnostics.size() == 1);
  GZ_CHECK_EQ_STR(snapshot.diagnostics[0].origin.name, "zig");
}

void run_all_tests() {
  test_replace_means_replace();
  test_empty_replacement_clears();
  test_source_isolation();
  test_document_isolation();
  test_remove_document();
  test_unknown_document_rejected();
  test_clear_all_from_source();
  test_origin_name_defaults();
}

} // namespace

GZ_TEST_MAIN("diagnostics/store")
