#include "diagnostics/gz_diagnostic_store.hpp"

#include "diagnostics/gz_diagnostic_path.hpp"

#include <algorithm>
#include <sstream>

namespace {

GzSourceRange normalize_range(GzSourceRange range, uint64_t *normalized) {
  const auto before_start =
      (static_cast<uint64_t>(range.start.line) << 32) | range.start.column;
  const auto before_end =
      (static_cast<uint64_t>(range.end.line) << 32) | range.end.column;
  if (before_end < before_start) {
    range.end = range.start;
    if (normalized) {
      ++(*normalized);
    }
  }
  return range;
}

void append_dump_line(std::ostringstream &out, const GzDiagnostic &diagnostic) {
  out << "    " << gz_diagnostic_severity_name(diagnostic.severity) << " "
      << diagnostic.range.start.line << ":" << diagnostic.range.start.column;
  if (!diagnostic.code.empty()) {
    out << " [" << diagnostic.code << "]";
  }
  out << " " << diagnostic.message << " (" << diagnostic.origin.name << ")\n";
}

} // namespace

GzDiagnosticStore::Generation
GzDiagnosticStore::open_document(const std::string &path) {
  const std::string key = gz_normalize_document_path(path);
  std::lock_guard<std::mutex> lock(mutex_);
  DocumentState &state = documents_[key];
  if (state.generation == 0) {
    state.generation = 1;
  }
  return state.generation;
}

GzDiagnosticStore::Generation
GzDiagnosticStore::advance_generation(const std::string &path) {
  const std::string key = gz_normalize_document_path(path);
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = documents_.find(key);
  if (it == documents_.end()) {
    return 0;
  }
  ++it->second.generation;
  return it->second.generation;
}

GzDiagnosticStore::Generation
GzDiagnosticStore::current_generation(const std::string &path) const {
  const std::string key = gz_normalize_document_path(path);
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = documents_.find(key);
  return it == documents_.end() ? 0 : it->second.generation;
}

bool GzDiagnosticStore::close_document(const std::string &path) {
  const std::string key = gz_normalize_document_path(path);
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = documents_.find(key);
  if (it == documents_.end()) {
    return false;
  }
  it->second.closed = true;
  return true;
}

std::vector<GzDiagnostic> GzDiagnosticStore::normalize_batch(
    std::vector<GzDiagnostic> diagnostics, const std::string &document_key,
    uint64_t *normalized_count) {
  for (GzDiagnostic &diagnostic : diagnostics) {
    diagnostic.document_path = document_key;
    diagnostic.range = normalize_range(diagnostic.range, normalized_count);
    if (diagnostic.origin.name.empty()) {
      diagnostic.origin.name = gz_diagnostic_source_name(diagnostic.origin.kind);
    }
  }
  std::sort(diagnostics.begin(), diagnostics.end(), gz_diagnostic_less);
  diagnostics.erase(std::unique(diagnostics.begin(), diagnostics.end()),
                    diagnostics.end());
  return diagnostics;
}

void GzDiagnosticStore::mark_changed_locked(const std::string &document_key) {
  if (changed_set_.insert(document_key).second) {
    changed_order_.push_back(document_key);
  }
}

GzDiagnosticUpdateResult
GzDiagnosticStore::replace(const GzDiagnosticUpdate &update) {
  const std::string key = gz_normalize_document_path(update.document_path);
  uint64_t normalized = 0;
  std::vector<GzDiagnostic> batch =
      normalize_batch(update.diagnostics, key, &normalized);
  if (normalized > 0) {
    ranges_normalized_.fetch_add(normalized, std::memory_order_relaxed);
  }

  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = documents_.find(key);
  if (it == documents_.end()) {
    unknown_rejected_.fetch_add(1, std::memory_order_relaxed);
    return GzDiagnosticUpdateResult::UnknownDocument;
  }
  DocumentState &state = it->second;
  if (update.generation < state.generation) {
    stale_rejected_.fetch_add(1, std::memory_order_relaxed);
    return GzDiagnosticUpdateResult::Stale;
  }
  if (update.generation > state.generation) {
    future_rejected_.fetch_add(1, std::memory_order_relaxed);
    return GzDiagnosticUpdateResult::FutureGeneration;
  }
  std::vector<GzDiagnostic> &current = state.by_source[update.source];
  if (current == batch) {
    updates_noop_.fetch_add(1, std::memory_order_relaxed);
    return GzDiagnosticUpdateResult::Applied;
  }
  current = std::move(batch);
  mark_changed_locked(key);
  replaces_applied_.fetch_add(1, std::memory_order_relaxed);
  return GzDiagnosticUpdateResult::Applied;
}

void GzDiagnosticStore::clear_source(const std::string &path,
                                     GzDiagnosticSource source) {
  const std::string key = gz_normalize_document_path(path);
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = documents_.find(key);
  if (it == documents_.end()) {
    return;
  }
  const auto stored = it->second.by_source.find(source);
  if (stored == it->second.by_source.end() || stored->second.empty()) {
    return;
  }
  stored->second.clear();
  mark_changed_locked(key);
}

void GzDiagnosticStore::clear_document(const std::string &path) {
  const std::string key = gz_normalize_document_path(path);
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = documents_.find(key);
  if (it == documents_.end()) {
    return;
  }
  bool had_any = false;
  for (auto &entry : it->second.by_source) {
    if (!entry.second.empty()) {
      entry.second.clear();
      had_any = true;
    }
  }
  if (had_any) {
    mark_changed_locked(key);
  }
}

void GzDiagnosticStore::clear_all_from_source(GzDiagnosticSource source) {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto &document : documents_) {
    const auto stored = document.second.by_source.find(source);
    if (stored != document.second.by_source.end() && !stored->second.empty()) {
      stored->second.clear();
      mark_changed_locked(document.first);
    }
  }
}

void GzDiagnosticStore::remove_document(const std::string &path) {
  const std::string key = gz_normalize_document_path(path);
  std::lock_guard<std::mutex> lock(mutex_);
  documents_.erase(key);
  changed_set_.erase(key);
  changed_order_.erase(
      std::remove(changed_order_.begin(), changed_order_.end(), key),
      changed_order_.end());
}

GzDiagnosticSnapshot
GzDiagnosticStore::snapshot(const std::string &path) const {
  const std::string key = gz_normalize_document_path(path);
  GzDiagnosticSnapshot result;
  result.document_path = key;
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = documents_.find(key);
  if (it == documents_.end()) {
    return result;
  }
  result.generation = it->second.generation;
  for (const auto &entry : it->second.by_source) {
    result.diagnostics.insert(result.diagnostics.end(), entry.second.begin(),
                              entry.second.end());
  }
  // Batches are stored sorted, but sources interleave: merge deterministically.
  // std::map iterates sources in enum order; stable sort keeps that grouping
  // for fully equal keys while ordering by position/severity/message.
  std::stable_sort(result.diagnostics.begin(), result.diagnostics.end(),
                   gz_diagnostic_less);
  return result;
}

GzDiagnosticSnapshot
GzDiagnosticStore::snapshot_source(const std::string &path,
                                   GzDiagnosticSource source) const {
  const std::string key = gz_normalize_document_path(path);
  GzDiagnosticSnapshot result;
  result.document_path = key;
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = documents_.find(key);
  if (it == documents_.end()) {
    return result;
  }
  result.generation = it->second.generation;
  const auto stored = it->second.by_source.find(source);
  if (stored != it->second.by_source.end()) {
    result.diagnostics = stored->second;
  }
  return result;
}

std::vector<std::string> GzDiagnosticStore::take_changed_documents() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::vector<std::string> result;
  result.swap(changed_order_);
  changed_set_.clear();
  return result;
}

GzDiagnosticStoreStats GzDiagnosticStore::stats() const {
  GzDiagnosticStoreStats result;
  result.replaces_applied = replaces_applied_.load(std::memory_order_relaxed);
  result.stale_rejected = stale_rejected_.load(std::memory_order_relaxed);
  result.future_rejected = future_rejected_.load(std::memory_order_relaxed);
  result.unknown_rejected = unknown_rejected_.load(std::memory_order_relaxed);
  result.updates_noop = updates_noop_.load(std::memory_order_relaxed);
  result.ranges_normalized =
      ranges_normalized_.load(std::memory_order_relaxed);
  return result;
}

size_t GzDiagnosticStore::tracked_document_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return documents_.size();
}

std::string GzDiagnosticStore::debug_dump() const {
  std::lock_guard<std::mutex> lock(mutex_);
  std::ostringstream out;
  out << "diagnostics:\n";
  for (const auto &document : documents_) {
    out << document.first << " generation=" << document.second.generation;
    if (document.second.closed) {
      out << " closed";
    }
    out << "\n";
    if (document.second.by_source.empty()) {
      out << "  none\n";
      continue;
    }
    for (const auto &entry : document.second.by_source) {
      out << "  " << gz_diagnostic_source_name(entry.first) << ":\n";
      if (entry.second.empty()) {
        out << "    none\n";
        continue;
      }
      for (const GzDiagnostic &diagnostic : entry.second) {
        append_dump_line(out, diagnostic);
      }
    }
  }
  return out.str();
}
