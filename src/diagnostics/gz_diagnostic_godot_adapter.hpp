#pragma once

// Boundary between the engine-independent diagnostic store and Godot.
//
// Responsibilities (main thread only):
// - Map Godot-side paths (res://...) to canonical store keys via
//   ProjectSettings, then delegate identity to gz_normalize_document_path().
// - Convert snapshots to the exact Dictionary shapes Godot's
//   ScriptLanguageExtension::validate() translation expects (verified
//   against upstream core/object/script_language_extension.h):
//     errors:   [{path, line, column, message}] (one-based)
//     warnings: [{start_line, end_line, string_code, message}] (one-based)
// - Clamp positions into int32 range for the Godot Variant boundary.
//
// This adapter never stores state and never touches the store lock beyond
// the snapshot call itself.

#include "diagnostics/gz_diagnostic_store.hpp"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <string>

namespace gzdiagnostics {

// Store key for a Godot-side path. Returns "" when the path cannot be
// resolved (caller treats it as "no diagnostics").
std::string store_key_for_godot_path(const godot::String &path);

// Snapshot validity per Phase 4 semantics (no Error diagnostics).
bool godot_snapshot_valid(const GzDiagnosticSnapshot &snapshot);

godot::Array godot_error_list(const GzDiagnosticSnapshot &snapshot,
                              const godot::String &display_path);
godot::Array godot_warning_list(const GzDiagnosticSnapshot &snapshot);

} // namespace gzdiagnostics
