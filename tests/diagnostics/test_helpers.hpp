#pragma once

// Minimal assertion harness for the engine-independent diagnostics tests.
// Each test binary defines its own main() and calls run_all_tests().

#include <cstdio>
#include <string>

namespace gztest {

inline int &failures() {
  static int count = 0;
  return count;
}

inline void check_impl(bool condition, const char *file, int line,
                       const char *expression) {
  if (!condition) {
    ++failures();
    std::printf("FAIL %s:%d: %s\n", file, line, expression);
  }
}

inline void check_eq_impl(const std::string &actual, const std::string &expected,
                          const char *file, int line, const char *expression) {
  if (actual != expected) {
    ++failures();
    std::printf("FAIL %s:%d: %s\n  actual:   %s\n  expected: %s\n", file, line,
                expression, actual.c_str(), expected.c_str());
  }
}

} // namespace gztest

#define GZ_CHECK(cond)                                                         \
  gztest::check_impl((cond), __FILE__, __LINE__, #cond)
#define GZ_CHECK_EQ_STR(actual, expected)                                      \
  gztest::check_eq_impl((actual), (expected), __FILE__, __LINE__,              \
                        #actual " == " #expected)
#define GZ_TEST_MAIN(name)                                                     \
  int main() {                                                                 \
    run_all_tests();                                                           \
    if (gztest::failures() == 0) {                                             \
      std::printf("[PASS] %s\n", name);                                        \
      return 0;                                                                \
    }                                                                          \
    std::printf("[FAIL] %s (%d assertions)\n", name, gztest::failures());      \
    return 1;                                                                  \
  }
