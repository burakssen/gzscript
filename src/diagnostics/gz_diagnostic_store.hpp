#pragma once

// Single source of truth for source-code diagnostics.
//
// Threading contract (hard invariant):
// - Producer threads may update the store; the Godot main thread may query
//   it and drain the changed-document queue.
// - The store never calls Godot/engine APIs and never invokes callbacks
//   while holding its lock. Producers submit complete batches; consumers
//   work exclusively from immutable snapshots.
// - Engine-independent (std-only): unit-testable without Godot.
//
// Generation contract:
// - Documents are explicitly registered (open_document, generation starts
//   at 1); every content change advances it. Diagnostics carry the
//   generation they were produced for.
// - replace() applies only when update.generation == current generation.
//   Older updates are Stale, unknown documents/future generations are
//   rejected so late async results can never overwrite newer state or
//   resurrect removed documents.

#include "gz_diagnostic.hpp"

#include <atomic>
#include <cstdint>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

enum class GzDiagnosticUpdateResult {
  Applied = 0,
  Stale = 1,
  UnknownDocument = 2,
  FutureGeneration = 3,
};

// Complete, generation-tagged diagnostic set from one producer. Producers
// must construct the batch fully, then submit it atomically.
struct GzDiagnosticUpdate {
  std::string document_path;
  uint64_t generation = 0;
  GzDiagnosticSource source = GzDiagnosticSource::GzScript;
  std::vector<GzDiagnostic> diagnostics;
};

struct GzDiagnosticStoreStats {
  uint64_t replaces_applied = 0;
  uint64_t stale_rejected = 0;
  uint64_t future_rejected = 0;
  uint64_t unknown_rejected = 0;
  uint64_t updates_noop = 0;
  uint64_t ranges_normalized = 0;
};

class GzDiagnosticStore {
public:
  using Generation = uint64_t;

  GzDiagnosticStore() = default;
  GzDiagnosticStore(const GzDiagnosticStore &) = delete;
  GzDiagnosticStore &operator=(const GzDiagnosticStore &) = delete;

  // Registers (or returns) a document; new documents start at generation 1.
  Generation open_document(const std::string &path);
  // Advances the content generation; returns the new generation (0 when the
  // document is not tracked).
  Generation advance_generation(const std::string &path);
  // Current generation, or 0 when the document is not tracked.
  Generation current_generation(const std::string &path) const;
  // Marks a tracked document closed (tab closed, file still exists).
  // Diagnostics are kept and updates are still accepted.
  bool close_document(const std::string &path);

  // Atomically replaces one source's diagnostics for a generation.
  // Empty diagnostics clear that source. Identical replacements are
  // accepted without marking the document changed.
  GzDiagnosticUpdateResult replace(const GzDiagnosticUpdate &update);

  void clear_source(const std::string &path, GzDiagnosticSource source);
  void clear_document(const std::string &path);
  void clear_all_from_source(GzDiagnosticSource source);
  // Erases diagnostics, generation tracking, and producer metadata.
  void remove_document(const std::string &path);

  // Stable combined snapshot (all sources, deterministic order).
  GzDiagnosticSnapshot snapshot(const std::string &path) const;
  // Stable snapshot for one source only.
  GzDiagnosticSnapshot snapshot_source(const std::string &path,
                                       GzDiagnosticSource source) const;

  // Drains deduplicated changed-document keys (insertion order).
  std::vector<std::string> take_changed_documents();

  GzDiagnosticStoreStats stats() const;
  size_t tracked_document_count() const;
  // Debug-only dump for logs; not a stable format.
  std::string debug_dump() const;

private:
  struct DocumentState {
    Generation generation = 0;
    bool closed = false;
    std::map<GzDiagnosticSource, std::vector<GzDiagnostic>> by_source;
  };

  static std::vector<GzDiagnostic>
  normalize_batch(std::vector<GzDiagnostic> diagnostics,
                  const std::string &document_key, uint64_t *normalized_count);
  void mark_changed_locked(const std::string &document_key);

  mutable std::mutex mutex_;
  std::unordered_map<std::string, DocumentState> documents_;
  std::vector<std::string> changed_order_;
  std::set<std::string> changed_set_;

  std::atomic<uint64_t> replaces_applied_{0};
  std::atomic<uint64_t> stale_rejected_{0};
  std::atomic<uint64_t> future_rejected_{0};
  std::atomic<uint64_t> unknown_rejected_{0};
  std::atomic<uint64_t> updates_noop_{0};
  std::atomic<uint64_t> ranges_normalized_{0};
};
