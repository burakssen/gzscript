#include "gz_process_utils.hpp"

#include <cerrno>
#include <cstdlib>
#include <unordered_map>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h> // ponytail: windows.h must precede tlhelp32.h for win32 type declarations
#include <tlhelp32.h>
#elif defined(__APPLE__)
#include <csignal>
#include <sys/sysctl.h>
#include <unistd.h>
#else
#include <csignal>
#include <dirent.h>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>
#endif

namespace
{
  using ProcessTree = std::unordered_multimap<int32_t, int32_t>;

  ProcessTree process_tree()
  {
    ProcessTree tree;
#ifdef _WIN32
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE)
      return tree;
    PROCESSENTRY32 entry{};
    entry.dwSize = sizeof(entry);
    if (Process32First(snapshot, &entry))
    {
      do
      {
        tree.emplace(static_cast<int32_t>(entry.th32ParentProcessID),
                     static_cast<int32_t>(entry.th32ProcessID));
      } while (Process32Next(snapshot, &entry));
    }
    CloseHandle(snapshot);
#elif defined(__APPLE__)
    int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    std::size_t size = 0;
    std::vector<kinfo_proc> processes;
    for (int attempt = 0; attempt < 3; ++attempt)
    {
      if (sysctl(query, 4, nullptr, &size, nullptr, 0) != 0 || size == 0)
        return tree;
      size += size / 4;
      processes.resize(size / sizeof(kinfo_proc));
      if (sysctl(query, 4, processes.data(), &size, nullptr, 0) == 0)
        break;
      if (errno != ENOMEM || attempt == 2)
        return tree;
    }
    processes.resize(size / sizeof(kinfo_proc));
    for (const kinfo_proc &process : processes)
      tree.emplace(process.kp_eproc.e_ppid, process.kp_proc.p_pid);
#else
    DIR *directory = opendir("/proc");
    if (!directory)
      return tree;
    while (dirent *entry = readdir(directory))
    {
      char *end = nullptr;
      const long pid = std::strtol(entry->d_name, &end, 10);
      if (!end || *end != '\0' || pid <= 0)
        continue;
      std::ifstream stat("/proc/" + std::to_string(pid) + "/stat");
      std::string line;
      if (!std::getline(stat, line))
        continue;
      const std::size_t command_end = line.rfind(')');
      if (command_end == std::string::npos || command_end + 2 >= line.size())
        continue;
      std::istringstream fields(line.substr(command_end + 2));
      char state = 0;
      int32_t parent = 0;
      if (fields >> state >> parent)
        tree.emplace(parent, static_cast<int32_t>(pid));
    }
    closedir(directory);
#endif
    return tree;
  }

  void collect_descendants(const ProcessTree &tree, int32_t parent,
                           std::vector<int32_t> &result)
  {
    const auto children = tree.equal_range(parent);
    for (auto child = children.first; child != children.second; ++child)
    {
      result.push_back(child->second);
      collect_descendants(tree, child->second, result);
    }
  }

  void terminate_process(int32_t pid)
  {
#ifdef _WIN32
    HANDLE process = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pid);
    if (process)
    {
      TerminateProcess(process, 1);
      WaitForSingleObject(process, 1000);
      CloseHandle(process);
    }
#else
    kill(pid, SIGKILL);
#endif
  }
} // namespace

void gz_isolate_process(int32_t pid)
{
#ifdef _WIN32
  (void)pid;
#else
  if (pid > 0)
    setpgid(pid, pid);
#endif
}

void gz_terminate_process_tree(int32_t root_pid)
{
  if (root_pid <= 0)
    return;
  const ProcessTree tree = process_tree();
  std::vector<int32_t> descendants;
  collect_descendants(tree, root_pid, descendants);
#ifndef _WIN32
  kill(-root_pid, SIGKILL);
#endif
  terminate_process(root_pid);
  for (int32_t pid : descendants)
    terminate_process(pid);
}
