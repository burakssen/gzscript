#pragma once

// Phase 1 lifecycle infrastructure.
//
// Intended ownership graph (see register_types.cpp shutdown ordering):
//
//   GzRuntime (extension init/term level)
//   ├── GzBuildManager  (owns compiler child processes, compile queue)
//   ├── GzLanguage      (owns GzLspClient; registered script language)
//   └── GzCompiledModule (shared ownership: GzScript current + GzScriptInstance pinned)
//
// Key invariant: a compiled native module must remain loaded for as long as
// any script instance can execute code from it. GzScript and GzScriptInstance
// therefore each hold a std::shared_ptr<GzCompiledModule>; dlclose() happens
// exactly once, in ~GzCompiledModule().
//
// Global shutdown barrier: once gz_shutdown_begin() runs, pumps and frames
// must stop accepting new work (no new compiles, LSP requests, module loads).

#include <atomic>
#include <cstdint>

#ifdef DEBUG_ENABLED
#include <godot_cpp/variant/utility_functions.hpp>
#endif

// Set to 1 to enable verbose lifecycle tracing (compiled out by default).
#ifndef GZ_LIFECYCLE_TRACE
#define GZ_LIFECYCLE_TRACE 0
#endif

#if GZ_LIFECYCLE_TRACE
#define GZ_TRACE(category, object_id, operation)                               \
  godot::UtilityFunctions::print("[GZ][", category, "][", object_id, "] ",     \
                                 operation)
#else
#define GZ_TRACE(category, object_id, operation) ((void)0)
#endif

namespace gz_lifecycle {

// Global shutdown barrier. Set once when extension termination begins;
// never cleared. Components check it before starting new work.
inline std::atomic<bool> &shutdown_requested() {
  static std::atomic<bool> flag{false};
  return flag;
}

inline bool is_shutting_down() {
  return shutdown_requested().load(std::memory_order_acquire);
}

// Returns true for the single caller that wins the shutdown race.
inline bool begin_shutdown() {
  bool expected = false;
  return shutdown_requested().compare_exchange_strong(expected, true,
                                                      std::memory_order_acq_rel);
}

// Monotonic debug IDs (debug builds use them in traces; release keeps the
// counter for the shutdown summary only).
inline std::atomic<uint64_t> &next_debug_id() {
  static std::atomic<uint64_t> counter{1};
  return counter;
}

inline uint64_t allocate_debug_id() {
  return next_debug_id().fetch_add(1, std::memory_order_relaxed);
}

// Debug-only global counters verified at shutdown.
struct Counters {
  std::atomic<int64_t> scripts{0};
  std::atomic<int64_t> instances{0};
  std::atomic<int64_t> modules{0};
  std::atomic<int64_t> compile_jobs{0};
  std::atomic<int64_t> lsp_processes{0};
};

inline Counters &counters() {
  static Counters instance;
  return instance;
}

} // namespace gz_lifecycle
