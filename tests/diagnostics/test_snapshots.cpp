// Snapshots: ordering, dedup, changed-document queue semantics.
#include "diagnostics/gz_diagnostic_store.hpp"
#include "test_helpers.hpp"

#include <string>
#include <vector>

namespace {

GzDiagnostic make_diag(const std::string &path, const std::string &message,
                       uint32_t line, uint32_t column,
                       GzDiagnosticSeverity severity,
                       GzDiagnosticSource source) {
  GzDiagnostic diagnostic;
  diagnostic.document_path = path;
  diagnostic.range.start = {line, column};
  diagnostic.range.end = {line, column};
  diagnostic.severity = severity;
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

void test_snapshot_sorted_deterministically() {
  GzDiagnosticStore store;
  store.open_document("/game/a.zig");
  store.replace(make_update("/game/a.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("/game/a.zig", "l50", 50, 0,
                                       GzDiagnosticSeverity::Error,
                                       GzDiagnosticSource::Zls),
                             make_diag("/game/a.zig", "l1", 1, 0,
                                       GzDiagnosticSeverity::Error,
                                       GzDiagnosticSource::Zls),
                             make_diag("/game/a.zig", "l20", 20, 0,
                                       GzDiagnosticSeverity::Error,
                                       GzDiagnosticSource::Zls),
                             make_diag("/game/a.zig", "l1c2", 1, 2,
                                       GzDiagnosticSeverity::Error,
                                       GzDiagnosticSource::Zls)}));
  GzDiagnosticSnapshot snapshot = store.snapshot("/game/a.zig");
  GZ_CHECK(snapshot.diagnostics.size() == 4);
  GZ_CHECK(snapshot.diagnostics[0].message == "l1");
  GZ_CHECK(snapshot.diagnostics[1].message == "l1c2");
  GZ_CHECK(snapshot.diagnostics[2].message == "l20");
  GZ_CHECK(snapshot.diagnostics[3].message == "l50");
  GZ_CHECK(snapshot.generation == 1);
  GZ_CHECK_EQ_STR(snapshot.document_path, "/game/a.zig");
}

void test_exact_duplicates_collapse() {
  GzDiagnosticStore store;
  store.open_document("/game/a.zig");
  const GzDiagnostic dup =
      make_diag("/game/a.zig", "same", 3, 0, GzDiagnosticSeverity::Error,
                GzDiagnosticSource::Zls);
  store.replace(make_update("/game/a.zig", 1, GzDiagnosticSource::Zls,
                            {dup, dup, dup}));
  GZ_CHECK(store.snapshot("/game/a.zig").diagnostics.size() == 1);
}

void test_position_distinguishes_duplicates() {
  GzDiagnosticStore store;
  store.open_document("/game/a.zig");
  store.replace(make_update(
      "/game/a.zig", 1, GzDiagnosticSource::Zls,
      {make_diag("/game/a.zig", "unused x", 3, 0,
                 GzDiagnosticSeverity::Warning, GzDiagnosticSource::Zls),
       make_diag("/game/a.zig", "unused x", 9, 0,
                 GzDiagnosticSeverity::Warning, GzDiagnosticSource::Zls)}));
  GZ_CHECK(store.snapshot("/game/a.zig").diagnostics.size() == 2);
}

void test_sources_not_deduplicated_against_each_other() {
  GzDiagnosticStore store;
  store.open_document("/game/a.zig");
  store.replace(make_update(
      "/game/a.zig", 1, GzDiagnosticSource::Zls,
      {make_diag("/game/a.zig", "expected type", 4, 1,
                 GzDiagnosticSeverity::Error, GzDiagnosticSource::Zls)}));
  GzDiagnosticUpdate compiler = make_update(
      "/game/a.zig", 1, GzDiagnosticSource::ZigCompiler,
      {make_diag("/game/a.zig", "expected type", 4, 1,
                 GzDiagnosticSeverity::Error, GzDiagnosticSource::Zls)});
  compiler.diagnostics[0].origin.kind = GzDiagnosticSource::ZigCompiler;
  store.replace(compiler);
  GZ_CHECK(store.snapshot("/game/a.zig").diagnostics.size() == 2);
}

void test_changed_queue_coalesces() {
  GzDiagnosticStore store;
  store.open_document("/game/foo.zig");
  store.open_document("/game/bar.zig");
  store.replace(make_update("/game/foo.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("/game/foo.zig", "a", 1, 0,
                                       GzDiagnosticSeverity::Error,
                                       GzDiagnosticSource::Zls)}));
  store.replace(make_update("/game/foo.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("/game/foo.zig", "b", 2, 0,
                                       GzDiagnosticSeverity::Error,
                                       GzDiagnosticSource::Zls)}));
  store.replace(make_update("/game/foo.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("/game/foo.zig", "c", 3, 0,
                                       GzDiagnosticSeverity::Error,
                                       GzDiagnosticSource::Zls)}));
  store.replace(make_update("/game/bar.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("/game/bar.zig", "d", 1, 0,
                                       GzDiagnosticSeverity::Error,
                                       GzDiagnosticSource::Zls)}));
  const std::vector<std::string> changed = store.take_changed_documents();
  GZ_CHECK(changed.size() == 2);
  GZ_CHECK(changed[0] == "/game/foo.zig");
  GZ_CHECK(changed[1] == "/game/bar.zig");
  GZ_CHECK(store.take_changed_documents().empty());
}

void test_clearing_marks_changed() {
  GzDiagnosticStore store;
  store.open_document("/game/foo.zig");
  store.replace(make_update("/game/foo.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("/game/foo.zig", "a", 1, 0,
                                       GzDiagnosticSeverity::Error,
                                       GzDiagnosticSource::Zls)}));
  GZ_CHECK(!store.take_changed_documents().empty());
  store.clear_document("/game/foo.zig");
  const std::vector<std::string> changed = store.take_changed_documents();
  GZ_CHECK(changed.size() == 1);
  GZ_CHECK(changed[0] == "/game/foo.zig");
}

void test_noop_update_skips_notification() {
  GzDiagnosticStore store;
  store.open_document("/game/foo.zig");
  store.replace(make_update("/game/foo.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("/game/foo.zig", "a", 1, 0,
                                       GzDiagnosticSeverity::Error,
                                       GzDiagnosticSource::Zls)}));
  GZ_CHECK(!store.take_changed_documents().empty());
  store.replace(make_update("/game/foo.zig", 1, GzDiagnosticSource::Zls,
                            {make_diag("/game/foo.zig", "a", 1, 0,
                                       GzDiagnosticSeverity::Error,
                                       GzDiagnosticSource::Zls)}));
  GZ_CHECK(store.take_changed_documents().empty());
  GZ_CHECK(store.stats().updates_noop == 1);
}

void run_all_tests() {
  test_snapshot_sorted_deterministically();
  test_exact_duplicates_collapse();
  test_position_distinguishes_duplicates();
  test_sources_not_deduplicated_against_each_other();
  test_changed_queue_coalesces();
  test_clearing_marks_changed();
  test_noop_update_skips_notification();
}

} // namespace

GZ_TEST_MAIN("diagnostics/snapshots")
