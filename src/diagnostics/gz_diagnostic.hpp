#pragma once

// Backend-neutral diagnostic model.
//
// Design rules (see docs/diagnostics.md):
// - Zero-based positions (LSP-aligned). Godot adapters convert to one-based.
// - Ranges are end-exclusive. Point diagnostics use start == end.
// - Diagnostics belong to source documents, never to script instances,
//   loaded modules, or cache keys.
// - This header is engine-independent (std-only) so the model and store can
//   be unit-tested without Godot. Godot conversion lives in
//   gz_diagnostic_godot_adapter.*.

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

enum class GzDiagnosticSeverity : uint8_t {
  Error = 0,
  Warning = 1,
  Information = 2,
  Hint = 3,
};

enum class GzDiagnosticSource : uint8_t {
  Zls = 0,
  ZigCompiler = 1,
  GzScript = 2,
};

// Zero-based source position. First line is {0, 0}.
struct GzSourcePosition {
  uint32_t line = 0;
  uint32_t column = 0;
};

// End-exclusive range: [start, end). A point diagnostic has start == end.
struct GzSourceRange {
  GzSourcePosition start;
  GzSourcePosition end;
};

struct GzDiagnosticOrigin {
  GzDiagnosticSource kind = GzDiagnosticSource::GzScript;
  // Stable human-readable producer name ("zls", "zig", "gzscript").
  std::string name;
};

struct GzDiagnostic {
  // Normalized canonical document key (see gz_diagnostic_path.hpp).
  std::string document_path;
  GzSourceRange range;
  GzDiagnosticSeverity severity = GzDiagnosticSeverity::Error;
  GzDiagnosticOrigin origin;
  std::string message;
  // Optional producer code ("" when none).
  std::string code;

  bool operator==(const GzDiagnostic &other) const;
  bool operator!=(const GzDiagnostic &other) const;
};

struct GzDiagnosticSnapshot {
  std::string document_path;
  uint64_t generation = 0;
  std::vector<GzDiagnostic> diagnostics;
};

int gz_diagnostic_severity_rank(GzDiagnosticSeverity severity);
const char *gz_diagnostic_source_name(GzDiagnosticSource source);
const char *gz_diagnostic_severity_name(GzDiagnosticSeverity severity);

// True when the snapshot contains no Error diagnostics.
bool gz_diagnostic_snapshot_valid(const GzDiagnosticSnapshot &snapshot);

// Deterministic ordering: start line, start column, severity rank, source,
// message. End position is intentionally not part of the order.
bool gz_diagnostic_less(const GzDiagnostic &lhs, const GzDiagnostic &rhs);

size_t gz_diagnostic_hash(const GzDiagnostic &diagnostic);

namespace std {
template <> struct hash<GzDiagnostic> {
  size_t operator()(const GzDiagnostic &diagnostic) const {
    return gz_diagnostic_hash(diagnostic);
  }
};
} // namespace std
