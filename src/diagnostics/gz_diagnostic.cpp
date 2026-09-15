#include "diagnostics/gz_diagnostic.hpp"

#include <functional>

namespace {

size_t hash_combine(size_t seed, size_t value) {
  // 64-bit FNV-1a style mixing; order-sensitive.
  seed ^= value + 0x9e3779b97f4a7c15ull + (seed << 6) + (seed >> 2);
  return seed;
}

bool position_less(const GzSourcePosition &lhs, const GzSourcePosition &rhs) {
  if (lhs.line != rhs.line) {
    return lhs.line < rhs.line;
  }
  return lhs.column < rhs.column;
}

bool position_equal(const GzSourcePosition &lhs,
                    const GzSourcePosition &rhs) {
  return lhs.line == rhs.line && lhs.column == rhs.column;
}

} // namespace

bool GzDiagnostic::operator==(const GzDiagnostic &other) const {
  return document_path == other.document_path &&
         position_equal(range.start, other.range.start) &&
         position_equal(range.end, other.range.end) &&
         severity == other.severity && origin.kind == other.origin.kind &&
         origin.name == other.origin.name && message == other.message &&
         code == other.code;
}

bool GzDiagnostic::operator!=(const GzDiagnostic &other) const {
  return !(*this == other);
}

int gz_diagnostic_severity_rank(GzDiagnosticSeverity severity) {
  switch (severity) {
  case GzDiagnosticSeverity::Error:
    return 0;
  case GzDiagnosticSeverity::Warning:
    return 1;
  case GzDiagnosticSeverity::Information:
    return 2;
  case GzDiagnosticSeverity::Hint:
    return 3;
  }
  return 4;
}

const char *gz_diagnostic_source_name(GzDiagnosticSource source) {
  switch (source) {
  case GzDiagnosticSource::Zls:
    return "zls";
  case GzDiagnosticSource::ZigCompiler:
    return "zig";
  case GzDiagnosticSource::GzScript:
    return "gzscript";
  }
  return "unknown";
}

const char *gz_diagnostic_severity_name(GzDiagnosticSeverity severity) {
  switch (severity) {
  case GzDiagnosticSeverity::Error:
    return "ERROR";
  case GzDiagnosticSeverity::Warning:
    return "WARNING";
  case GzDiagnosticSeverity::Information:
    return "INFO";
  case GzDiagnosticSeverity::Hint:
    return "HINT";
  }
  return "UNKNOWN";
}

bool gz_diagnostic_snapshot_valid(const GzDiagnosticSnapshot &snapshot) {
  for (const GzDiagnostic &diagnostic : snapshot.diagnostics) {
    if (diagnostic.severity == GzDiagnosticSeverity::Error) {
      return false;
    }
  }
  return true;
}

bool gz_diagnostic_less(const GzDiagnostic &lhs, const GzDiagnostic &rhs) {
  if (!position_equal(lhs.range.start, rhs.range.start)) {
    return position_less(lhs.range.start, rhs.range.start);
  }
  const int lhs_rank = gz_diagnostic_severity_rank(lhs.severity);
  const int rhs_rank = gz_diagnostic_severity_rank(rhs.severity);
  if (lhs_rank != rhs_rank) {
    return lhs_rank < rhs_rank;
  }
  if (lhs.origin.kind != rhs.origin.kind) {
    return lhs.origin.kind < rhs.origin.kind;
  }
  if (lhs.message != rhs.message) {
    return lhs.message < rhs.message;
  }
  if (lhs.code != rhs.code) {
    return lhs.code < rhs.code;
  }
  if (lhs.origin.name != rhs.origin.name) {
    return lhs.origin.name < rhs.origin.name;
  }
  return lhs.document_path < rhs.document_path;
}

size_t gz_diagnostic_hash(const GzDiagnostic &diagnostic) {
  std::hash<std::string> string_hash;
  size_t seed = string_hash(diagnostic.document_path);
  seed = hash_combine(seed, diagnostic.range.start.line);
  seed = hash_combine(seed, diagnostic.range.start.column);
  seed = hash_combine(seed, diagnostic.range.end.line);
  seed = hash_combine(seed, diagnostic.range.end.column);
  seed = hash_combine(seed, static_cast<size_t>(diagnostic.severity));
  seed = hash_combine(seed, static_cast<size_t>(diagnostic.origin.kind));
  seed = hash_combine(seed, string_hash(diagnostic.origin.name));
  seed = hash_combine(seed, string_hash(diagnostic.message));
  seed = hash_combine(seed, string_hash(diagnostic.code));
  return seed;
}
