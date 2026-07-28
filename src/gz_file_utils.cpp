#include "gz_file_utils.hpp"

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/time.hpp>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#ifdef ERROR
#undef ERROR // ponytail: undefine WinGDI ERROR macro to avoid conflict with GzFileLock::Result::ERROR
#endif
#else
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#endif

using namespace godot;

GzFileLock::~GzFileLock()
{
#ifdef _WIN32
  if (handle != -1)
  {
    OVERLAPPED overlapped{};
    UnlockFileEx(reinterpret_cast<HANDLE>(handle), 0, MAXDWORD, MAXDWORD,
                 &overlapped);
    CloseHandle(reinterpret_cast<HANDLE>(handle));
  }
#else
  if (handle != -1)
  {
    flock(static_cast<int>(handle), LOCK_UN);
    close(static_cast<int>(handle));
  }
#endif
}

GzFileLock::Result GzFileLock::try_lock(const String &path)
{
  if (handle != -1)
    return Result::ACQUIRED;
#ifdef _WIN32
  Char16String native_path = path.utf16();
  HANDLE file = CreateFileW(
      reinterpret_cast<LPCWSTR>(native_path.get_data()),
      GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE)
  {
    last_error = "Unable to open lock file " + path + " (Windows error " +
                 String::num_int64(GetLastError()) + ")";
    return Result::ERROR;
  }
  OVERLAPPED overlapped{};
  if (!LockFileEx(file, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0,
                  MAXDWORD, MAXDWORD, &overlapped))
  {
    const DWORD error = GetLastError();
    CloseHandle(file);
    if (error == ERROR_LOCK_VIOLATION || error == ERROR_IO_PENDING)
      return Result::BUSY;
    last_error = "Unable to lock " + path + " (Windows error " +
                 String::num_int64(error) + ")";
    return Result::ERROR;
  }
  handle = reinterpret_cast<intptr_t>(file);
#else
  CharString native_path = path.utf8();
  const int file = open(native_path.get_data(), O_CREAT | O_RDWR, 0600);
  if (file < 0)
  {
    last_error = "Unable to open lock file " + path + ": " + strerror(errno);
    return Result::ERROR;
  }
  if (flock(file, LOCK_EX | LOCK_NB) != 0)
  {
    const int error = errno;
    close(file);
    if (error == EWOULDBLOCK || error == EAGAIN)
      return Result::BUSY;
    last_error = "Unable to lock " + path + ": " + strerror(error);
    return Result::ERROR;
  }
  handle = file;
#endif
  last_error = String();
  return Result::ACQUIRED;
}

bool GzFileLock::lock(const String &path, uint64_t timeout_msec)
{
  const uint64_t deadline =
      Time::get_singleton()->get_ticks_msec() + timeout_msec;
  while (true)
  {
    const Result result = try_lock(path);
    if (result == Result::ACQUIRED)
      return true;
    if (result == Result::ERROR)
      return false;
    if (Time::get_singleton()->get_ticks_msec() >= deadline)
    {
      last_error = "Timed out waiting for lock " + path;
      return false;
    }
    OS::get_singleton()->delay_msec(2);
  }
}

Error gz_atomic_replace(const String &source, const String &destination)
{
#ifdef _WIN32
  Char16String native_source = source.utf16();
  Char16String native_destination = destination.utf16();
  return MoveFileExW(reinterpret_cast<LPCWSTR>(native_source.get_data()),
                     reinterpret_cast<LPCWSTR>(native_destination.get_data()),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)
             ? OK
             : ERR_CANT_CREATE;
#else
  CharString native_source = source.utf8();
  CharString native_destination = destination.utf8();
  return rename(native_source.get_data(), native_destination.get_data()) == 0
             ? OK
             : ERR_CANT_CREATE;
#endif
}

Error gz_sync_file(const String &path)
{
#ifdef _WIN32
  Char16String native_path = path.utf16();
  HANDLE file = CreateFileW(reinterpret_cast<LPCWSTR>(native_path.get_data()),
                            GENERIC_WRITE,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE)
    return ERR_CANT_OPEN;
  const bool synced = FlushFileBuffers(file);
  CloseHandle(file);
  return synced ? OK : ERR_FILE_CANT_WRITE;
#else
  CharString native_path = path.utf8();
  const int file = open(native_path.get_data(), O_RDONLY);
  if (file < 0)
    return ERR_CANT_OPEN;
  const bool synced = fsync(file) == 0;
  close(file);
  return synced ? OK : ERR_FILE_CANT_WRITE;
#endif
}

Error gz_sync_parent_directory(const String &path)
{
#ifdef _WIN32
  (void)path;
  return OK;
#else
  CharString native_path = path.get_base_dir().utf8();
  const int directory = open(native_path.get_data(), O_RDONLY | O_DIRECTORY);
  if (directory < 0)
    return ERR_CANT_OPEN;
  const bool synced = fsync(directory) == 0;
  close(directory);
  return synced ? OK : ERR_FILE_CANT_WRITE;
#endif
}
