#include "diagnostics/gz_diagnostic_path.hpp"

#include <vector>

namespace {

// Percent-decode %XX sequences; leaves malformed escapes untouched.
std::string uri_decode(const std::string &value) {
  std::string result;
  result.reserve(value.size());
  for (size_t i = 0; i < value.size(); ++i) {
    if (value[i] == '%' && i + 2 < value.size() + 1) {
      const auto hex_value = [](char digit) -> int {
        if (digit >= '0' && digit <= '9') {
          return digit - '0';
        }
        if (digit >= 'a' && digit <= 'f') {
          return digit - 'a' + 10;
        }
        if (digit >= 'A' && digit <= 'F') {
          return digit - 'A' + 10;
        }
        return -1;
      };
      const int high = (i + 1 < value.size()) ? hex_value(value[i + 1]) : -1;
      const int low = (i + 2 < value.size()) ? hex_value(value[i + 2]) : -1;
      if (high >= 0 && low >= 0) {
        result.push_back(static_cast<char>((high << 4) | low));
        i += 2;
        continue;
      }
    }
    result.push_back(value[i]);
  }
  return result;
}

} // namespace

std::string gz_normalize_document_path(const std::string &path) {
  std::string work = path;
  std::string scheme_prefix;

  // file:// URI support (LSP document identifiers).
  const std::string file_scheme = "file://";
  if (work.compare(0, file_scheme.size(), file_scheme) == 0) {
    work = uri_decode(work.substr(file_scheme.size()));
    // file:///abs and file://host/abs both reduce to an absolute path.
    if (!work.empty() && work[0] != '/' && work.find(':') == std::string::npos) {
      work = "/" + work;
    }
  } else {
    // Preserve other URI-like schemes (notably res://, which the Godot
    // adapter globalizes before normalizing) instead of mangling `://`.
    const size_t scheme_end = work.find("://");
    if (scheme_end != std::string::npos && scheme_end > 0) {
      bool is_scheme = true;
      for (size_t i = 0; i < scheme_end; ++i) {
        const char c = work[i];
        const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                        (i > 0 && ((c >= '0' && c <= '9') || c == '+' ||
                                   c == '-' || c == '.'));
        if (!ok) {
          is_scheme = false;
          break;
        }
      }
      if (is_scheme) {
        scheme_prefix = work.substr(0, scheme_end + 3);
        work = work.substr(scheme_end + 3);
        if (!work.empty() && work[0] == '/') {
          work = work.substr(1);
        }
      }
    }
  }

#ifdef _WIN32
  for (char &character : work) {
    if (character == '\\') {
      character = '/';
    }
  }
  // Normalize drive letters: C:/... and c:/... are the same document.
  if (is_drive_prefix(work, 0) && work[0] >= 'a' && work[0] <= 'z') {
    work[0] = static_cast<char>(work[0] - ('a' - 'A'));
  }
#endif

  // Collapse duplicate separators. On Windows a leading double slash marks
  // a UNC root and is preserved; elsewhere collapse fully.
  std::string collapsed;
  collapsed.reserve(work.size());
  const bool keep_leading_double =
#ifdef _WIN32
      work.size() >= 2 && work[0] == '/' && work[1] == '/';
#else
      false;
#endif
  for (size_t i = 0; i < work.size(); ++i) {
    if (work[i] == '/' && !collapsed.empty() && collapsed.back() == '/') {
      if (keep_leading_double && collapsed.size() == 1 && i == 1) {
        collapsed.push_back(work[i]);
        continue;
      }
      continue;
    }
    collapsed.push_back(work[i]);
  }
  work = collapsed;

  // Resolve ./ and ../ lexically (no filesystem access).
  const bool rooted = !work.empty() && work[0] == '/';
  const bool has_drive =
      work.size() >= 2 && work[1] == ':' &&
      ((work[0] >= 'a' && work[0] <= 'z') || (work[0] >= 'A' && work[0] <= 'Z'));
  std::vector<std::string> parts;
  std::string segment;
  for (size_t i = 0; i <= work.size(); ++i) {
    const char delimiter = (i < work.size()) ? work[i] : '/';
    if (delimiter == '/') {
      if (segment.empty() || segment == ".") {
        // Skip.
      } else if (segment == "..") {
        if (!parts.empty() && parts.back() != ".." && parts.back() != "/" &&
            !(parts.size() == 1 && has_drive)) {
          parts.pop_back();
        } else if (!rooted && !has_drive) {
          parts.push_back(segment);
        }
      } else {
        parts.push_back(segment);
      }
      segment.clear();
    } else {
      segment.push_back(delimiter);
    }
  }

  std::string result;
  if (rooted) {
    result.push_back('/');
  }
  for (size_t i = 0; i < parts.size(); ++i) {
    if (i > 0) {
      result.push_back('/');
    }
    result += parts[i];
  }
  if (result.empty()) {
    result = rooted ? std::string("/") : std::string(".");
  }
  return scheme_prefix + result;
}
