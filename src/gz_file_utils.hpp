#pragma once

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

class GzFileLock final {
public:
  enum class Result { ACQUIRED, BUSY, ERROR };

private:
  intptr_t handle = -1;
  godot::String last_error;

public:
  GzFileLock() = default;
  ~GzFileLock();
  GzFileLock(const GzFileLock &) = delete;
  GzFileLock &operator=(const GzFileLock &) = delete;

  Result try_lock(const godot::String &path);
  bool lock(const godot::String &path, uint64_t timeout_msec);
  const godot::String &get_last_error() const { return last_error; }
};

godot::Error gz_atomic_replace(const godot::String &source,
                               const godot::String &destination);
godot::Error gz_sync_file(const godot::String &path);
godot::Error gz_sync_parent_directory(const godot::String &path);
