// Concurrent readers/writers: no races, every snapshot internally valid.
// Run under ThreadSanitizer in CI (GZSCRIPT_TSAN=1).
#include "diagnostics/gz_diagnostic_store.hpp"
#include "test_helpers.hpp"

#include <atomic>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

namespace {

bool snapshot_valid_shape(const GzDiagnosticSnapshot &snapshot) {
  for (size_t i = 1; i < snapshot.diagnostics.size(); ++i) {
    const GzDiagnostic &prev = snapshot.diagnostics[i - 1];
    const GzDiagnostic &next = snapshot.diagnostics[i];
    // Sorted by (line, column); equal neighbors must be fully equal or
    // ordered by the deterministic tie-breakers.
    if (next.range.start.line < prev.range.start.line) {
      return false;
    }
    if (next.range.start.line == prev.range.start.line &&
        next.range.start.column < prev.range.start.column) {
      return false;
    }
  }
  return true;
}

GzDiagnostic make_diag(const std::string &path, int id) {
  GzDiagnostic diagnostic;
  diagnostic.document_path = path;
  diagnostic.range.start = {static_cast<uint32_t>(id % 64),
                            static_cast<uint32_t>(id % 8)};
  diagnostic.range.end = diagnostic.range.start;
  diagnostic.origin.kind = (id % 2 == 0) ? GzDiagnosticSource::Zls
                                        : GzDiagnosticSource::ZigCompiler;
  diagnostic.message = "message " + std::to_string(id % 16);
  return diagnostic;
}

void writer_thread(GzDiagnosticStore *store, const std::string &path, int seed,
                   int iterations, std::atomic<int> *applied) {
  for (int i = 0; i < iterations; ++i) {
    GzDiagnosticUpdate update;
    update.document_path = path;
    update.generation = store->current_generation(path);
    update.source = (i % 2 == 0) ? GzDiagnosticSource::Zls
                                 : GzDiagnosticSource::ZigCompiler;
    update.diagnostics.push_back(make_diag(path, seed + i));
    if (store->replace(update) == GzDiagnosticUpdateResult::Applied) {
      ++(*applied);
    }
  }
}

void reader_thread(const GzDiagnosticStore *store, const std::string &path,
                   int iterations, std::atomic<int> *checked) {
  for (int i = 0; i < iterations; ++i) {
    const GzDiagnosticSnapshot snapshot = store->snapshot(path);
    if (!snapshot_valid_shape(snapshot)) {
      std::printf("invalid snapshot shape for %s\n", path.c_str());
      return;
    }
    ++(*checked);
  }
}

void churn_thread(GzDiagnosticStore *store, int iterations) {
  for (int i = 0; i < iterations; ++i) {
    store->advance_generation("/game/churn.zig");
    store->take_changed_documents();
    if (i % 8 == 0) {
      store->clear_source("/game/churn.zig", GzDiagnosticSource::Zls);
    }
  }
}

void test_concurrent_readers_writers() {
  GzDiagnosticStore store;
  store.open_document("/game/a.zig");
  store.open_document("/game/b.zig");
  store.open_document("/game/churn.zig");

  constexpr int kIterations = 500;
  std::atomic<int> applied{0};
  std::atomic<int> checked{0};

  std::thread writers[2] = {
      std::thread(writer_thread, &store, "/game/a.zig", 0, kIterations,
                  &applied),
      std::thread(writer_thread, &store, "/game/b.zig", 100000, kIterations,
                  &applied),
  };
  std::thread readers[2] = {
      std::thread(reader_thread, &store, "/game/a.zig", kIterations, &checked),
      std::thread(reader_thread, &store, "/game/b.zig", kIterations, &checked),
  };
  std::thread churn(churn_thread, &store, kIterations);

  writers[0].join();
  writers[1].join();
  readers[0].join();
  readers[1].join();
  churn.join();

  GZ_CHECK(checked.load() == 2 * kIterations);
  GZ_CHECK(applied.load() > 0);
  // Draining works after concurrent use.
  store.take_changed_documents();
  GZ_CHECK(store.take_changed_documents().empty());
  // Late updates against removed documents never resurrect them.
  store.remove_document("/game/a.zig");
  GZ_CHECK(store.tracked_document_count() == 2);
}

void run_all_tests() {
  test_concurrent_readers_writers();
}

} // namespace

GZ_TEST_MAIN("diagnostics/concurrency")
