// Diagnostic model: severity, sources, equality, hashing, validity, order.
#include "diagnostics/gz_diagnostic.hpp"
#include "test_helpers.hpp"

#include <algorithm>
#include <string>
#include <vector>

namespace {

GzDiagnostic make_diag(const std::string &message, uint32_t line,
                       uint32_t column,
                       GzDiagnosticSeverity severity =
                           GzDiagnosticSeverity::Error,
                       GzDiagnosticSource source =
                           GzDiagnosticSource::Zls) {
  GzDiagnostic diagnostic;
  diagnostic.document_path = "/game/scripts/player.zig";
  diagnostic.range.start = {line, column};
  diagnostic.range.end = {line, column};
  diagnostic.severity = severity;
  diagnostic.origin.kind = source;
  diagnostic.message = message;
  return diagnostic;
}

void test_severity() {
  GZ_CHECK(gz_diagnostic_severity_rank(GzDiagnosticSeverity::Error) <
           gz_diagnostic_severity_rank(GzDiagnosticSeverity::Warning));
  GZ_CHECK(gz_diagnostic_severity_rank(GzDiagnosticSeverity::Warning) <
           gz_diagnostic_severity_rank(GzDiagnosticSeverity::Information));
  GZ_CHECK(gz_diagnostic_severity_rank(GzDiagnosticSeverity::Information) <
           gz_diagnostic_severity_rank(GzDiagnosticSeverity::Hint));
  GZ_CHECK_EQ_STR(gz_diagnostic_severity_name(GzDiagnosticSeverity::Error),
                  "ERROR");
  GZ_CHECK_EQ_STR(gz_diagnostic_severity_name(GzDiagnosticSeverity::Warning),
                  "WARNING");
}

void test_source_names() {
  GZ_CHECK_EQ_STR(gz_diagnostic_source_name(GzDiagnosticSource::Zls), "zls");
  GZ_CHECK_EQ_STR(gz_diagnostic_source_name(GzDiagnosticSource::ZigCompiler),
                  "zig");
  GZ_CHECK_EQ_STR(gz_diagnostic_source_name(GzDiagnosticSource::GzScript),
                  "gzscript");
}

void test_equality() {
  const GzDiagnostic base = make_diag("oops", 3, 4);
  GZ_CHECK(base == base);
  GzDiagnostic changed = base;
  changed.message = "different";
  GZ_CHECK(base != changed);
  changed = base;
  changed.range.start.column = 5;
  GZ_CHECK(base != changed);
  changed = base;
  changed.range.end.line = 9;
  GZ_CHECK(base != changed);
  changed = base;
  changed.severity = GzDiagnosticSeverity::Warning;
  GZ_CHECK(base != changed);
  changed = base;
  changed.origin.kind = GzDiagnosticSource::ZigCompiler;
  GZ_CHECK(base != changed);
  changed = base;
  changed.code = "E001";
  GZ_CHECK(base != changed);
  changed = base;
  changed.document_path = "/other.zig";
  GZ_CHECK(base != changed);
}

void test_hash_consistency() {
  const GzDiagnostic left = make_diag("oops", 3, 4);
  GzDiagnostic right = left;
  GZ_CHECK(gz_diagnostic_hash(left) == gz_diagnostic_hash(right));
  GZ_CHECK(std::hash<GzDiagnostic>{}(left) ==
           std::hash<GzDiagnostic>{}(right));
  right.message = "other";
  GZ_CHECK(gz_diagnostic_hash(left) != gz_diagnostic_hash(right));
}

void test_validity() {
  GzDiagnosticSnapshot empty;
  GZ_CHECK(gz_diagnostic_snapshot_valid(empty));
  GzDiagnosticSnapshot warnings;
  warnings.diagnostics.push_back(
      make_diag("unused", 1, 1, GzDiagnosticSeverity::Warning));
  warnings.diagnostics.push_back(
      make_diag("hint", 2, 2, GzDiagnosticSeverity::Hint));
  warnings.diagnostics.push_back(
      make_diag("info", 3, 3, GzDiagnosticSeverity::Information));
  GZ_CHECK(gz_diagnostic_snapshot_valid(warnings));
  GzDiagnosticSnapshot with_error = warnings;
  with_error.diagnostics.push_back(make_diag("broken", 0, 0));
  GZ_CHECK(!gz_diagnostic_snapshot_valid(with_error));
}

void test_ordering() {
  std::vector<GzDiagnostic> diagnostics = {
      make_diag("late", 50, 0),
      make_diag("early", 1, 0),
      make_diag("mid", 20, 0),
      make_diag("early-col", 1, 2),
      make_diag("warn-early", 1, 0, GzDiagnosticSeverity::Warning),
  };
  std::sort(diagnostics.begin(), diagnostics.end(), gz_diagnostic_less);
  GZ_CHECK(diagnostics[0].message == "early");
  GZ_CHECK(diagnostics[1].message == "warn-early");
  GZ_CHECK(diagnostics[2].message == "early-col");
  GZ_CHECK(diagnostics[3].message == "mid");
  GZ_CHECK(diagnostics[4].message == "late");
}

void run_all_tests() {
  test_severity();
  test_source_names();
  test_equality();
  test_hash_consistency();
  test_validity();
  test_ordering();
}

} // namespace

GZ_TEST_MAIN("diagnostics/model")
