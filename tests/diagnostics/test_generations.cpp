// Generations: stale/future rejection, same-generation updates, deletion.
#include "diagnostics/gz_diagnostic_store.hpp"
#include "test_helpers.hpp"

#include <string>
#include <vector>

namespace {

GzDiagnostic make_diag(const std::string &message, uint32_t line) {
  GzDiagnostic diagnostic;
  diagnostic.document_path = "/game/player.zig";
  diagnostic.range.start = {line, 0};
  diagnostic.range.end = {line, 0};
  diagnostic.origin.kind = GzDiagnosticSource::Zls;
  diagnostic.message = message;
  return diagnostic;
}

GzDiagnosticUpdate make_update(const std::string &path, uint64_t generation,
                               std::vector<GzDiagnostic> diagnostics) {
  GzDiagnosticUpdate update;
  update.document_path = path;
  update.generation = generation;
  update.source = GzDiagnosticSource::Zls;
  update.diagnostics = std::move(diagnostics);
  return update;
}

void test_generation_lifecycle() {
  GzDiagnosticStore store;
  GZ_CHECK(store.open_document("/game/player.zig") == 1);
  GZ_CHECK(store.open_document("/game/player.zig") == 1);
  GZ_CHECK(store.advance_generation("/game/player.zig") == 2);
  GZ_CHECK(store.advance_generation("/game/player.zig") == 3);
  GZ_CHECK(store.current_generation("/game/player.zig") == 3);
  GZ_CHECK(store.current_generation("/game/missing.zig") == 0);
  GZ_CHECK(store.advance_generation("/game/missing.zig") == 0);
}

void test_stale_update_rejected() {
  GzDiagnosticStore store;
  store.open_document("/game/player.zig");
  GZ_CHECK(store.replace(make_update("/game/player.zig", 1,
                                      {make_diag("error A", 1)})) ==
           GzDiagnosticUpdateResult::Applied);
  GZ_CHECK(store.advance_generation("/game/player.zig") == 2);
  GZ_CHECK(store.replace(make_update("/game/player.zig", 1,
                                      {make_diag("warning OLD", 2)})) ==
           GzDiagnosticUpdateResult::Stale);
  GzDiagnosticSnapshot snapshot = store.snapshot("/game/player.zig");
  GZ_CHECK(snapshot.diagnostics.size() == 1);
  GZ_CHECK(snapshot.diagnostics[0].message == "error A");
  GZ_CHECK(snapshot.generation == 2);
  GZ_CHECK(store.stats().stale_rejected == 1);
}

void test_same_generation_latest_wins() {
  GzDiagnosticStore store;
  store.open_document("/game/player.zig");
  store.replace(make_update("/game/player.zig", 1, {make_diag("A", 1)}));
  GZ_CHECK(store.replace(make_update("/game/player.zig", 1, {make_diag("B", 2)})) ==
           GzDiagnosticUpdateResult::Applied);
  GzDiagnosticSnapshot snapshot = store.snapshot("/game/player.zig");
  GZ_CHECK(snapshot.diagnostics.size() == 1);
  GZ_CHECK(snapshot.diagnostics[0].message == "B");
}

void test_sources_coexist_at_same_generation() {
  GzDiagnosticStore store;
  store.open_document("/game/player.zig");
  GzDiagnosticUpdate zls = make_update("/game/player.zig", 1,
                                       {make_diag("zls warning", 1)});
  zls.source = GzDiagnosticSource::Zls;
  GzDiagnosticUpdate compiler = make_update("/game/player.zig", 1,
                                            {make_diag("zig error", 2)});
  compiler.source = GzDiagnosticSource::ZigCompiler;
  compiler.diagnostics[0].origin.kind = GzDiagnosticSource::ZigCompiler;
  GZ_CHECK(store.replace(zls) == GzDiagnosticUpdateResult::Applied);
  GZ_CHECK(store.replace(compiler) == GzDiagnosticUpdateResult::Applied);
  GZ_CHECK(store.snapshot("/game/player.zig").diagnostics.size() == 2);
}

void test_future_generation_rejected() {
  GzDiagnosticStore store;
  store.open_document("/game/player.zig");
  GZ_CHECK(store.replace(make_update("/game/player.zig", 11,
                                      {make_diag("future", 1)})) ==
           GzDiagnosticUpdateResult::FutureGeneration);
  GZ_CHECK(store.current_generation("/game/player.zig") == 1);
  GZ_CHECK(store.snapshot("/game/player.zig").diagnostics.empty());
  GZ_CHECK(store.stats().future_rejected == 1);
}

void test_removed_document_rejects_late_update() {
  GzDiagnosticStore store;
  store.open_document("/game/player.zig");
  store.advance_generation("/game/player.zig");
  store.advance_generation("/game/player.zig");
  store.advance_generation("/game/player.zig");
  store.advance_generation("/game/player.zig");
  // Generation is now 5; the producer started work earlier.
  store.remove_document("/game/player.zig");
  GZ_CHECK(store.replace(make_update("/game/player.zig", 5,
                                      {make_diag("late", 1)})) ==
           GzDiagnosticUpdateResult::UnknownDocument);
  GZ_CHECK(store.tracked_document_count() == 0);
  GZ_CHECK(store.current_generation("/game/player.zig") == 0);
}

void test_close_keeps_document_usable() {
  GzDiagnosticStore store;
  store.open_document("/game/player.zig");
  GZ_CHECK(store.close_document("/game/player.zig"));
  GZ_CHECK(!store.close_document("/game/missing.zig"));
  GZ_CHECK(store.replace(make_update("/game/player.zig", 1,
                                      {make_diag("still here", 1)})) ==
           GzDiagnosticUpdateResult::Applied);
  GZ_CHECK(store.snapshot("/game/player.zig").diagnostics.size() == 1);
  GZ_CHECK(store.debug_dump().find("closed") != std::string::npos);
}

void run_all_tests() {
  test_generation_lifecycle();
  test_stale_update_rejected();
  test_same_generation_latest_wins();
  test_sources_coexist_at_same_generation();
  test_future_generation_rejected();
  test_removed_document_rejects_late_update();
  test_close_keeps_document_usable();
}

} // namespace

GZ_TEST_MAIN("diagnostics/generations")
