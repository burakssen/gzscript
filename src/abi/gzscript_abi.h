#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GZSCRIPT_ABI_VERSION 5u

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
  GZ_VALUE_VECTOR3 = 7,
  GZ_VALUE_COLOR = 8,
  GZ_VALUE_TRANSFORM2D = 9,
  GZ_VALUE_TRANSFORM3D = 10,
  GZ_VALUE_RECT2 = 11,
} GzValueType;

typedef struct {
  float x;
  float y;
} GzVector2;

typedef struct {
  float x;
  float y;
  float z;
} GzVector3;

typedef struct {
  float r;
  float g;
  float b;
  float a;
} GzColor;

typedef struct {
  GzVector2 x;
  GzVector2 y;
  GzVector2 origin;
} GzTransform2D;

typedef struct {
  GzVector3 basis[3];
  GzVector3 origin;
} GzTransform3D;

typedef struct {
  GzVector2 position;
  GzVector2 size;
} GzRect2;

typedef union {
  bool boolean;
  int64_t integer;
  double floating;
  GzStringView string;
  GzVector2 vector2;
  GzVector3 vector3;
  GzColor color;
  GzTransform2D transform2d;
  GzTransform3D transform3d;
  GzRect2 rect2;
  uint64_t object_id;
} GzValueData;

typedef struct {
  uint32_t type;
  uint32_t reserved;
  GzValueData data;
} GzValue;

#ifdef __cplusplus
static_assert(GZ_VALUE_NIL == 0 && GZ_VALUE_BOOL == 1 && GZ_VALUE_INT == 2 &&
                  GZ_VALUE_FLOAT == 3 && GZ_VALUE_STRING == 4 &&
                  GZ_VALUE_VECTOR2 == 5 && GZ_VALUE_OBJECT == 6 &&
                  GZ_VALUE_VECTOR3 == 7 && GZ_VALUE_COLOR == 8 &&
                  GZ_VALUE_TRANSFORM2D == 9 && GZ_VALUE_TRANSFORM3D == 10 &&
                  GZ_VALUE_RECT2 == 11,
              "GzValueType ordinals are part of the ABI");
static_assert(sizeof(void *) == 8, "gzscript supports 64-bit targets only");
static_assert(sizeof(GzStringView) == 16 && alignof(GzStringView) == 8,
              "Unexpected GzStringView ABI layout");
static_assert(sizeof(GzVector2) == 8 && alignof(GzVector2) == 4,
              "Unexpected GzVector2 ABI layout");
static_assert(sizeof(GzVector3) == 12 && alignof(GzVector3) == 4,
              "Unexpected GzVector3 ABI layout");
static_assert(sizeof(GzColor) == 16 && alignof(GzColor) == 4,
              "Unexpected GzColor ABI layout");
static_assert(sizeof(GzTransform2D) == 24 && alignof(GzTransform2D) == 4,
              "Unexpected GzTransform2D ABI layout");
static_assert(sizeof(GzTransform3D) == 48 && alignof(GzTransform3D) == 4,
              "Unexpected GzTransform3D ABI layout");
static_assert(sizeof(GzRect2) == 16 && alignof(GzRect2) == 4,
              "Unexpected GzRect2 ABI layout");
static_assert(sizeof(GzValueData) == 48 && alignof(GzValueData) == 8,
              "Unexpected GzValueData ABI layout");
static_assert(sizeof(GzValue) == 56 && alignof(GzValue) == 8 &&
                  offsetof(GzValue, data) == 8,
              "Unexpected GzValue ABI layout");
#endif


typedef enum {
  GZ_PROPERTY_HINT_NONE = 0,
  GZ_PROPERTY_HINT_RANGE = 1,
  GZ_PROPERTY_HINT_ENUM = 2,
  GZ_PROPERTY_HINT_FILE = 13,
  GZ_PROPERTY_HINT_MULTILINE_TEXT = 18,
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
  GzStringView hint_string;
  GzStringView class_name;
  double range_min;
  double range_max;
  double range_step;
  GzValue default_value;
} GzPropertyDescriptor;

#ifdef __cplusplus
static_assert(sizeof(GzPropertyDescriptor) == 136 &&
                   alignof(GzPropertyDescriptor) == 8 &&
                   offsetof(GzPropertyDescriptor, class_name) == 40 &&
                   offsetof(GzPropertyDescriptor, default_value) == 80,
               "Unexpected GzPropertyDescriptor ABI layout");
#endif

typedef enum {
  GZ_INSPECTOR_ENTRY_PROPERTY = 0,
  GZ_INSPECTOR_ENTRY_CATEGORY = 1,
  GZ_INSPECTOR_ENTRY_GROUP = 2,
  GZ_INSPECTOR_ENTRY_SUBGROUP = 3,
} GzInspectorEntryKind;

typedef struct {
  uint32_t kind;
  uint32_t property_index;
  GzStringView name;
  GzStringView prefix;
} GzInspectorEntryDescriptor;

#ifdef __cplusplus
static_assert(sizeof(GzInspectorEntryDescriptor) == 40 &&
                  alignof(GzInspectorEntryDescriptor) == 8,
              "Unexpected GzInspectorEntryDescriptor ABI layout");
#endif

typedef struct {
  GzStringView name;
  uint32_t type;
} GzSignalArgumentDescriptor;

typedef struct {
  GzStringView name;
  const GzSignalArgumentDescriptor *arguments;
  uint32_t argument_count;
} GzSignalDescriptor;

typedef struct {
  uint32_t abi_version;
  uint32_t struct_size;
  void (*log_info)(GzStringView message);
  void (*log_error)(GzStringView message);
  GzStatus (*object_call)(uint64_t object_id, GzStringView method,
                          const GzValue *arguments, uint32_t argument_count,
                          GzValue *result);
  GzStatus (*object_emit_signal)(uint64_t object_id, GzStringView signal,
                                 const GzValue *arguments,
                                 uint32_t argument_count);
  void *(*get_method_bind)(GzStringView class_name, GzStringView method_name,
                           int64_t hash);
  GzStatus (*object_ptrcall)(void *method_bind, uint64_t object_id,
                              const void *const *arguments, void *result);
  uint64_t (*get_ticks_usec)(void);
} GzEngineApi;

#ifdef __cplusplus
static_assert(sizeof(GzEngineApi) == 64 && alignof(GzEngineApi) == 8 &&
                   offsetof(GzEngineApi, object_call) == 24,
              "Unexpected GzEngineApi ABI layout");
#endif


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
  const GzInspectorEntryDescriptor *inspector_entries;
  uint32_t inspector_entry_count;
  const GzSignalDescriptor *signals;
  uint32_t signal_count;
  GzCreateInstance create_instance;
  GzDestroyInstance destroy_instance;
  GzCallMethod call_method;
  GzGetProperty get_property;
  GzSetProperty set_property;
  GzNotification notification;
} GzScriptDescriptor;

#ifdef __cplusplus
static_assert(sizeof(GzScriptDescriptor) == 136 &&
                  alignof(GzScriptDescriptor) == 8 &&
                  offsetof(GzScriptDescriptor, base_class) == 8 &&
                  offsetof(GzScriptDescriptor, create_instance) == 88,
              "Unexpected GzScriptDescriptor ABI layout");
#endif

typedef GzStatus (*GzScriptInit)(const GzEngineApi *engine_api,
                                 const GzScriptDescriptor **descriptor);

#ifdef __cplusplus
}
#endif
