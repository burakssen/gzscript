#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GZSCRIPT_ABI_VERSION 1u

typedef struct {
  const char *ptr;
  size_t len;
} GzStringView;

typedef enum {
  GZ_STATUS_OK = 0,
  GZ_STATUS_INVALID_ARGUMENT = 1,
  GZ_STATUS_METHOD_NOT_FOUND = 2,
  GZ_STATUS_PROPERTY_NOT_FOUND = 3,
  GZ_STATUS_TYPE_MISMATCH = 4,
  GZ_STATUS_OUT_OF_MEMORY = 5,
  GZ_STATUS_SCRIPT_ERROR = 6,
  GZ_STATUS_ABI_MISMATCH = 7,
} GzStatus;

typedef enum {
  GZ_VALUE_NIL = 0,
  GZ_VALUE_BOOL = 1,
  GZ_VALUE_INT = 2,
  GZ_VALUE_FLOAT = 3,
  GZ_VALUE_STRING = 4,
  GZ_VALUE_VECTOR2 = 5,
  GZ_VALUE_OBJECT = 6,
} GzValueType;

typedef struct {
  double x;
  double y;
} GzVector2;

typedef union {
  bool boolean;
  int64_t integer;
  double floating;
  GzStringView string;
  GzVector2 vector2;
  uint64_t object_id;
} GzValueData;

typedef struct {
  uint32_t type;
  uint32_t reserved;
  GzValueData data;
} GzValue;

typedef enum {
  GZ_PROPERTY_HINT_NONE = 0,
  GZ_PROPERTY_HINT_RANGE = 1,
} GzPropertyHint;

typedef struct {
  GzStringView name;
  uint32_t argument_count;
  uint32_t flags;
} GzMethodDescriptor;

typedef struct {
  GzStringView name;
  uint32_t type;
  uint32_t hint;
  GzStringView category;
  double range_min;
  double range_max;
  double range_step;
  GzValue default_value;
} GzPropertyDescriptor;

typedef struct {
  uint32_t abi_version;
  uint32_t struct_size;
  void (*log_info)(GzStringView message);
  void (*log_error)(GzStringView message);
  GzStatus (*object_call)(uint64_t object_id, GzStringView method,
                          const GzValue *arguments, uint32_t argument_count,
                          GzValue *result);
} GzEngineApi;

typedef GzStatus (*GzCreateInstance)(uint64_t owner_id, void **instance);
typedef void (*GzDestroyInstance)(void *instance);
typedef GzStatus (*GzCallMethod)(void *instance, GzStringView method,
                                 const GzValue *arguments,
                                 uint32_t argument_count, GzValue *result);
typedef GzStatus (*GzGetProperty)(void *instance, uint32_t property_index,
                                  GzValue *result);
typedef GzStatus (*GzSetProperty)(void *instance, uint32_t property_index,
                                  const GzValue *value);
typedef void (*GzNotification)(void *instance, int32_t what, bool reversed);

typedef struct {
  uint32_t abi_version;
  uint32_t struct_size;
  GzStringView base_class;
  const GzMethodDescriptor *methods;
  uint32_t method_count;
  const GzPropertyDescriptor *properties;
  uint32_t property_count;
  GzCreateInstance create_instance;
  GzDestroyInstance destroy_instance;
  GzCallMethod call_method;
  GzGetProperty get_property;
  GzSetProperty set_property;
  GzNotification notification;
} GzScriptDescriptor;

typedef GzStatus (*GzScriptInit)(const GzEngineApi *engine_api,
                                 const GzScriptDescriptor **descriptor);

#ifdef __cplusplus
}
#endif
