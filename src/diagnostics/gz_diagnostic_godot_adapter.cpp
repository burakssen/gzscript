#include "diagnostics/gz_diagnostic_godot_adapter.hpp"

#include "diagnostics/gz_diagnostic_path.hpp"

#include <godot_cpp/classes/project_settings.hpp>

#include <algorithm>
#include <cstdint>
#include <limits>

namespace gzdiagnostics {
namespace {

int64_t clamp_position(uint32_t value) {
  return static_cast<int64_t>(
      std::min<uint64_t>(value, static_cast<uint64_t>(
                                    std::numeric_limits<int32_t>::max())));
}

// Godot ScriptError lines/columns are one-based; the store is zero-based.
int64_t godot_line(uint32_t zero_based) { return clamp_position(zero_based) + 1; }
int64_t godot_column(uint32_t zero_based) {
  return clamp_position(zero_based) + 1;
}

std::string to_utf8(const godot::String &value) {
  godot::CharString bytes = value.utf8();
  return std::string(bytes.get_data(), static_cast<size_t>(bytes.length()));
}

} // namespace

std::string store_key_for_godot_path(const godot::String &path) {
  if (path.is_empty()) {
    return {};
  }
  godot::String absolute = path;
  if (path.begins_with("res://")) {
    godot::ProjectSettings *settings = godot::ProjectSettings::get_singleton();
    if (!settings) {
      return {};
    }
    absolute = settings->globalize_path(path);
  }
  return gz_normalize_document_path(to_utf8(absolute));
}

bool godot_snapshot_valid(const GzDiagnosticSnapshot &snapshot) {
  return gz_diagnostic_snapshot_valid(snapshot);
}

godot::Array
godot_error_list(const GzDiagnosticSnapshot &snapshot,
                 const godot::String &display_path) {
  godot::Array errors;
  for (const GzDiagnostic &diagnostic : snapshot.diagnostics) {
    if (diagnostic.severity != GzDiagnosticSeverity::Error) {
      continue;
    }
    godot::Dictionary entry;
    entry["path"] = display_path;
    entry["line"] = godot_line(diagnostic.range.start.line);
    entry["column"] = godot_column(diagnostic.range.start.column);
    entry["message"] = godot::String::utf8(diagnostic.message.c_str(),
                                           diagnostic.message.size());
    errors.push_back(entry);
  }
  return errors;
}

godot::Array
godot_warning_list(const GzDiagnosticSnapshot &snapshot) {
  godot::Array warnings;
  for (const GzDiagnostic &diagnostic : snapshot.diagnostics) {
    if (diagnostic.severity == GzDiagnosticSeverity::Error) {
      continue;
    }
    godot::Dictionary entry;
    entry["start_line"] = godot_line(diagnostic.range.start.line);
    entry["end_line"] = godot_line(diagnostic.range.end.line);
    entry["string_code"] = godot::String::utf8(diagnostic.code.c_str(),
                                               diagnostic.code.size());
    entry["message"] = godot::String::utf8(diagnostic.message.c_str(),
                                           diagnostic.message.size());
    warnings.push_back(entry);
  }
  return warnings;
}

} // namespace gzdiagnostics
