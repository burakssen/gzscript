#pragma once

// Centralized document-identity normalization (engine-independent).
//
// The store keys every document by its normalized canonical path. Producers
// must agree on identity, so all normalization lives here — never copied
// into LSP/compiler/editor adapters.
//
// Scope split (deliberate):
// - This layer is PURE: separators, duplicate slashes, ./ and ../ segments,
//   file:// URIs (with percent-decoding), Windows drive-letter casing and
//   backslashes, trailing slashes. It never touches the engine.
// - `res://` mapping (ProjectSettings::globalize_path) requires the engine
//   and lives in the Godot adapter, which calls normalize_document_path()
//   afterwards. Store keys are therefore absolute filesystem paths.
// - Case sensitivity is preserved everywhere: no lowercasing. Windows callers
//   that need case-insensitive matching must handle it explicitly.

#include <string>

// Returns the canonical key for a document path. Idempotent.
std::string gz_normalize_document_path(const std::string &path);
