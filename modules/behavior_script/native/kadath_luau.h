#ifndef KADATH_LUAU_H
#define KADATH_LUAU_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KADATH_LUAU_MAX_PARAMETER_COUNT 16
#define KADATH_LUAU_MAX_PARAMETER_NAME_BYTES 63
#define KADATH_LUAU_MAX_COMMAND_COUNT 16
#define KADATH_LUAU_MAX_OBJECT_ID_BYTES 63

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

typedef struct KadathLuauCompileResult {
    uint8_t* bytecode;
    size_t bytecode_size;
    size_t parameter_count;
    KadathLuauParameterSchema parameters[KADATH_LUAU_MAX_PARAMETER_COUNT];
} KadathLuauCompileResult;

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
    KadathLuauTranslateCommand* commands,
    size_t command_capacity,
    size_t* command_count,
    char* error_buffer,
    size_t error_buffer_size);

#ifdef __cplusplus
}
#endif

#endif
