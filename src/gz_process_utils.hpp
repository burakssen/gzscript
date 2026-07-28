#pragma once

#include <cstdint>

void gz_isolate_process(int32_t pid);
void gz_terminate_process_tree(int32_t root_pid);
