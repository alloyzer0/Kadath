#ifndef KADATH_LUAU_H
#define KADATH_LUAU_H

#include <stddef.h>
#include <stdint.h>

#include "kadath_errors.h"

#ifdef __cplusplus
extern "C" {
#endif

#define KADATH_LUAU_MAX_PARAMETER_COUNT 16
#define KADATH_LUAU_MAX_PARAMETER_NAME_BYTES 63
#define KADATH_LUAU_MAX_COMMAND_COUNT 16
#define KADATH_LUAU_MAX_OBJECT_ID_BYTES 63
#define KADATH_LUAU_MAX_ANALYSIS_DIAGNOSTIC_COUNT 32
#define KADATH_LUAU_MAX_ANALYSIS_MESSAGE_BYTES 1024
#define KADATH_LUAU_HOST_INTERFACE_VERSION 3
#define KADATH_LUAU_MAX_EVENT_NAME_BYTES 63
#define KADATH_LUAU_MAX_EVENT_FIELD_COUNT 8
#define KADATH_LUAU_MAX_EVENT_KEY_BYTES 31
#define KADATH_LUAU_MAX_EVENT_STRING_BYTES 127

typedef struct KadathLuauAsset KadathLuauAsset;
typedef struct KadathLuauInstance KadathLuauInstance;

typedef struct KadathLuauParameterSchema {
    char name[KADATH_LUAU_MAX_PARAMETER_NAME_BYTES + 1];
    double default_value;
    double minimum;
    double maximum;
} KadathLuauParameterSchema;

typedef struct KadathLuauParameterValue {
    const char* name;
    size_t name_length;
    double value;
} KadathLuauParameterValue;

typedef struct KadathLuauTranslateCommand {
    double dx;
    double dy;
} KadathLuauTranslateCommand;

typedef struct KadathLuauInputSnapshot {
    int32_t move_x;
    int32_t move_y;
} KadathLuauInputSnapshot;

typedef enum KadathLuauObjectKind {
    KADATH_LUAU_OBJECT_SPRITE = 1,
    KADATH_LUAU_OBJECT_PLAYER = 2,
    KADATH_LUAU_OBJECT_GOAL = 3,
    KADATH_LUAU_OBJECT_PATROL_HAZARD = 4,
} KadathLuauObjectKind;

typedef struct KadathLuauObjectHandle {
    uint64_t world_epoch;
    uint64_t logical_generation;
    uint32_t kind;
    size_t object_id_length;
    char object_id[KADATH_LUAU_MAX_OBJECT_ID_BYTES + 1];
} KadathLuauObjectHandle;

typedef enum KadathLuauEventValueKind {
    KADATH_LUAU_EVENT_BOOLEAN = 1,
    KADATH_LUAU_EVENT_NUMBER = 2,
    KADATH_LUAU_EVENT_STRING = 3,
    KADATH_LUAU_EVENT_OBJECT = 4,
} KadathLuauEventValueKind;

typedef struct KadathLuauEventValue {
    uint32_t kind;
    int32_t boolean_value;
    double number_value;
    const char* string_value;
    size_t string_value_length;
    KadathLuauObjectHandle object_value;
} KadathLuauEventValue;

typedef struct KadathLuauEventField {
    const char* key;
    size_t key_length;
    KadathLuauEventValue value;
} KadathLuauEventField;

typedef struct KadathLuauPostedEvent {
    KadathLuauObjectHandle target;
    KadathLuauObjectHandle sender;
    const char* name;
    size_t name_length;
    const KadathLuauEventField* fields;
    size_t field_count;
} KadathLuauPostedEvent;

typedef enum KadathLuauEventDomain {
    KADATH_LUAU_EVENT_DOMAIN_FIXED = 1,
    KADATH_LUAU_EVENT_DOMAIN_FRAME = 2,
} KadathLuauEventDomain;

typedef struct KadathLuauEvent {
    const char* name;
    size_t name_length;
    uint32_t domain;
    uint32_t has_sender;
    KadathLuauObjectHandle sender;
    uint32_t has_other;
    KadathLuauObjectHandle other;
    const KadathLuauEventField* fields;
    size_t field_count;
} KadathLuauEvent;

typedef int (*KadathLuauResolveObjectFn)(
    void* userdata,
    const char* object_id,
    size_t object_id_length,
    KadathLuauObjectHandle* out_object);
typedef int (*KadathLuauGetObjectPositionFn)(
    void* userdata,
    const KadathLuauObjectHandle* object,
    double* out_x,
    double* out_y);
typedef int (*KadathLuauSetObjectPositionFn)(
    void* userdata,
    const KadathLuauObjectHandle* object,
    double x,
    double y);
typedef int (*KadathLuauPostEventFn)(void* userdata, const KadathLuauPostedEvent* event);

typedef struct KadathLuauHostV3 {
    uint32_t version;
    uint32_t struct_size;
    void* userdata;
    uint64_t world_epoch;
    KadathLuauResolveObjectFn resolve_object;
    KadathLuauGetObjectPositionFn get_object_position;
    KadathLuauSetObjectPositionFn set_object_position;
    KadathLuauPostEventFn post_event;
} KadathLuauHostV3;

typedef struct KadathLuauCompileResult {
    uint8_t* bytecode;
    size_t bytecode_size;
    size_t parameter_count;
    KadathLuauParameterSchema parameters[KADATH_LUAU_MAX_PARAMETER_COUNT];
} KadathLuauCompileResult;

typedef enum KadathLuauAnalysisState {
    KADATH_LUAU_ANALYSIS_VALID = 1,
    KADATH_LUAU_ANALYSIS_INVALID = 2,
} KadathLuauAnalysisState;

typedef enum KadathLuauDiagnosticSeverity {
    KADATH_LUAU_DIAGNOSTIC_ERROR = 1,
} KadathLuauDiagnosticSeverity;

typedef enum KadathLuauDiagnosticStage {
    KADATH_LUAU_DIAGNOSTIC_ANALYSIS = 1,
    KADATH_LUAU_DIAGNOSTIC_COMPILE = 2,
    KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION = 3,
    KADATH_LUAU_DIAGNOSTIC_BEHAVIOR_CONTRACT = 4,
} KadathLuauDiagnosticStage;

typedef enum KadathLuauDiagnosticCode {
    KADATH_LUAU_DIAGNOSTIC_LUAU_ANALYSIS_ERROR = 1,
    KADATH_LUAU_DIAGNOSTIC_LUAU_ANALYSIS_BUDGET_EXCEEDED = 2,
    KADATH_LUAU_DIAGNOSTIC_LUAU_COMPILE_ERROR = 3,
    KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION_ERROR = 4,
    KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION_BUDGET_EXCEEDED = 5,
    KADATH_LUAU_DIAGNOSTIC_TOOLING_MEMORY_LIMIT_EXCEEDED = 6,
    KADATH_LUAU_DIAGNOSTIC_INVALID_PARAMETER_DECLARATION = 7,
    KADATH_LUAU_DIAGNOSTIC_INVALID_BEHAVIOR_TABLE = 8,
    KADATH_LUAU_DIAGNOSTIC_LIMIT_REACHED = 9,
} KadathLuauDiagnosticCode;

typedef struct KadathLuauSourcePosition {
    uint32_t line;
    uint32_t column;
} KadathLuauSourcePosition;

typedef struct KadathLuauSourceRange {
    uint32_t has_range;
    KadathLuauSourcePosition start;
    KadathLuauSourcePosition end;
} KadathLuauSourceRange;

typedef struct KadathLuauAnalysisDiagnostic {
    uint32_t severity;
    uint32_t stage;
    uint32_t code;
    uint32_t message_bytes;
    KadathLuauSourceRange range;
    char message[KADATH_LUAU_MAX_ANALYSIS_MESSAGE_BYTES + 1];
} KadathLuauAnalysisDiagnostic;

typedef struct KadathLuauAnalysisResult {
    uint32_t state;
    uint32_t diagnostic_count;
    KadathLuauAnalysisDiagnostic diagnostics[KADATH_LUAU_MAX_ANALYSIS_DIAGNOSTIC_COUNT];
} KadathLuauAnalysisResult;

// Mode: caller-allocates; callee reads source/chunk_name and writes out_result/error_buffer.
// Lifetime: every pointer is borrowed only for this call and is never retained.
// Ownership: out_result and error_buffer remain caller-owned; no destroy call is required.
// Failure: KADATH_OK means out_result is complete. On error, a non-null out_result is zeroed
// and error_buffer receives a bounded NUL-terminated summary when its size is non-zero.
// Thread-safe. Reentrant: NO.
int32_t kadath_luau_analyze(
    const char* source,
    size_t source_length,
    const char* chunk_name,
    KadathLuauAnalysisResult* out_result,
    char* error_buffer,
    size_t error_buffer_size);

int kadath_luau_compile(
    const char* source,
    size_t source_length,
    const char* chunk_name,
    KadathLuauCompileResult* result,
    char* error_buffer,
    size_t error_buffer_size);

void kadath_luau_compile_result_destroy(KadathLuauCompileResult* result);

const char* kadath_luau_toolchain_identity(void);
const char* kadath_luau_runtime_toolchain_identity(void);

KadathLuauAsset* kadath_luau_asset_create(
    const uint8_t* bytecode,
    size_t bytecode_size,
    size_t memory_limit,
    int interrupt_limit,
    char* error_buffer,
    size_t error_buffer_size);

void kadath_luau_asset_destroy(KadathLuauAsset* asset);
size_t kadath_luau_asset_memory_used(const KadathLuauAsset* asset);

KadathLuauInstance* kadath_luau_instance_create(
    KadathLuauAsset* asset,
    const char* object_id,
    size_t object_id_length,
    const KadathLuauParameterValue* parameters,
    size_t parameter_count,
    char* error_buffer,
    size_t error_buffer_size);

void kadath_luau_instance_destroy(KadathLuauInstance* instance);

int kadath_luau_instance_on_start(
    KadathLuauInstance* instance,
    double position_x,
    double position_y,
    KadathLuauTranslateCommand* commands,
    size_t command_capacity,
    size_t* command_count,
    char* error_buffer,
    size_t error_buffer_size);

int kadath_luau_instance_fixed_update(
    KadathLuauInstance* instance,
    double dt_seconds,
    double position_x,
    double position_y,
    const KadathLuauInputSnapshot* input_snapshot,
    KadathLuauTranslateCommand* commands,
    size_t command_capacity,
    size_t* command_count,
    char* error_buffer,
    size_t error_buffer_size);

int kadath_luau_instance_on_start_v3(
    KadathLuauInstance* instance,
    const KadathLuauHostV3* host,
    char* error_buffer,
    size_t error_buffer_size);

int kadath_luau_instance_fixed_update_v3(
    KadathLuauInstance* instance,
    double dt_seconds,
    const KadathLuauInputSnapshot* input_snapshot,
    const KadathLuauHostV3* host,
    char* error_buffer,
    size_t error_buffer_size);

int kadath_luau_instance_update_v3(
    KadathLuauInstance* instance,
    double dt_seconds,
    const KadathLuauInputSnapshot* input_snapshot,
    const KadathLuauHostV3* host,
    char* error_buffer,
    size_t error_buffer_size);

int kadath_luau_instance_on_event_v3(
    KadathLuauInstance* instance,
    const KadathLuauEvent* event,
    const KadathLuauInputSnapshot* input_snapshot,
    const KadathLuauHostV3* host,
    char* error_buffer,
    size_t error_buffer_size);

#ifdef __cplusplus
}
#endif

#endif
