#include "kadath_luau.h"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <new>

#include "lua.h"
#include "lualib.h"

struct KadathLuauAllocator
{
    size_t used = 0;
    size_t limit = 0;
};

struct KadathLuauAsset
{
    lua_State* state = nullptr;
    KadathLuauAllocator allocator;
    int interrupt_count = 0;
    int interrupt_limit = 0;
    uint8_t* bytecode = nullptr;
    size_t bytecode_size = 0;
};

struct KadathLuauInstance
{
    KadathLuauAsset* asset = nullptr;
    lua_State* thread = nullptr;
    int thread_ref = LUA_NOREF;
    int behavior_ref = LUA_NOREF;
    int self_ref = LUA_NOREF;
    char object_id[KADATH_LUAU_MAX_OBJECT_ID_BYTES + 1] = {};
    size_t object_id_length = 0;
    KadathLuauParameterValue parameter_values[KADATH_LUAU_MAX_PARAMETER_COUNT] = {};
    char parameter_names[KADATH_LUAU_MAX_PARAMETER_COUNT][KADATH_LUAU_MAX_PARAMETER_NAME_BYTES + 1] = {};
    size_t parameter_count = 0;
    double position_x = 0.0;
    double position_y = 0.0;
    int32_t move_x = 0;
    int32_t move_y = 0;
    bool input_context_active = false;
    KadathLuauTranslateCommand pending_commands[KADATH_LUAU_MAX_COMMAND_COUNT] = {};
    size_t pending_command_count = 0;
};

static void write_error(char* buffer, size_t size, const char* message)
{
    if (buffer == nullptr || size == 0)
        return;
    if (message == nullptr)
        message = "unknown Luau error";
    size_t length = std::strlen(message);
    if (length >= size)
        length = size - 1;
    std::memcpy(buffer, message, length);
    buffer[length] = '\0';
}

static void* limited_alloc(void* userdata, void* pointer, size_t old_size, size_t new_size)
{
    auto* allocator = static_cast<KadathLuauAllocator*>(userdata);
    if (new_size == 0)
    {
        if (pointer != nullptr)
        {
            allocator->used = allocator->used >= old_size ? allocator->used - old_size : 0;
            std::free(pointer);
        }
        return nullptr;
    }
    if (new_size > old_size && allocator->used + (new_size - old_size) > allocator->limit)
        return nullptr;
    void* replacement = std::realloc(pointer, new_size);
    if (replacement == nullptr)
        return nullptr;
    allocator->used = allocator->used - old_size + new_size;
    return replacement;
}

static void interrupt_callback(lua_State* state, int gc)
{
    if (gc >= 0)
        return;
    auto* asset = static_cast<KadathLuauAsset*>(lua_callbacks(state)->userdata);
    if (asset == nullptr)
        return;
    asset->interrupt_count += 1;
    if (asset->interrupt_count >= asset->interrupt_limit)
        luaL_error(state, "behavior execution budget exceeded");
}

static int protected_call(KadathLuauAsset* asset, lua_State* state, int arguments, int results, char* error_buffer, size_t error_buffer_size)
{
    asset->interrupt_count = 0;
    const int status = lua_pcall(state, arguments, results, 0);
    if (status != LUA_OK)
    {
        write_error(error_buffer, error_buffer_size, lua_tostring(state, -1));
        lua_pop(state, 1);
        return 0;
    }
    return 1;
}

static bool valid_name(const char* name, size_t length)
{
    if (name == nullptr || length == 0 || length > KADATH_LUAU_MAX_PARAMETER_NAME_BYTES)
        return false;
    if (!((name[0] >= 'A' && name[0] <= 'Z') || (name[0] >= 'a' && name[0] <= 'z') || name[0] == '_'))
        return false;
    for (size_t index = 1; index < length; ++index)
    {
        const char ch = name[index];
        if (!((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_'))
            return false;
    }
    return true;
}

static KadathLuauInstance* instance_from_upvalue(lua_State* state)
{
    return static_cast<KadathLuauInstance*>(lua_touserdata(state, lua_upvalueindex(1)));
}

static int parameter_number(lua_State* state)
{
    auto* instance = instance_from_upvalue(state);
    size_t name_length = 0;
    const char* name = lua_tolstring(state, 1, &name_length);
    if (instance == nullptr || !valid_name(name, name_length)) {
        luaL_error(state, "invalid behavior parameter name");
        return 0;
    }
    if (!lua_istable(state, 2)) {
        luaL_error(state, "behavior parameter options must be a table");
        return 0;
    }
    for (size_t index = 0; index < instance->parameter_count; ++index)
    {
        if (std::strlen(instance->parameter_names[index]) == name_length &&
            std::memcmp(instance->parameter_names[index], name, name_length) == 0)
        {
            lua_pushnumber(state, instance->parameter_values[index].value);
            return 1;
        }
    }
    lua_getfield(state, 2, "default");
    if (!lua_isnumber(state, -1)) {
        luaL_error(state, "behavior parameter default must be a number");
        return 0;
    }
    const double value = lua_tonumber(state, -1);
    lua_pop(state, 1);
    if (!std::isfinite(value)) {
        luaL_error(state, "behavior parameter default must be finite");
        return 0;
    }
    lua_pushnumber(state, value);
    return 1;
}

static int self_id(lua_State* state)
{
    auto* instance = instance_from_upvalue(state);
    if (instance == nullptr) {
        luaL_error(state, "behavior host is unavailable");
        return 0;
    }
    lua_pushlstring(state, instance->object_id, instance->object_id_length);
    return 1;
}

static int self_position(lua_State* state)
{
    auto* instance = instance_from_upvalue(state);
    if (instance == nullptr) {
        luaL_error(state, "behavior host is unavailable");
        return 0;
    }
    lua_createtable(state, 0, 2);
    lua_pushnumber(state, instance->position_x);
    lua_setfield(state, -2, "x");
    lua_pushnumber(state, instance->position_y);
    lua_setfield(state, -2, "y");
    return 1;
}

static int self_translate(lua_State* state)
{
    auto* instance = instance_from_upvalue(state);
    if (instance == nullptr) {
        luaL_error(state, "behavior host is unavailable");
        return 0;
    }
    const double dx = luaL_checknumber(state, 2);
    const double dy = luaL_checknumber(state, 3);
    if (!std::isfinite(dx) || !std::isfinite(dy)) {
        luaL_error(state, "translate arguments must be finite");
        return 0;
    }
    if (instance->pending_command_count >= KADATH_LUAU_MAX_COMMAND_COUNT) {
        luaL_error(state, "behavior command budget exceeded");
        return 0;
    }
    instance->pending_commands[instance->pending_command_count++] = { dx, dy };
    return 0;
}

static int input_move_axis(lua_State* state)
{
    auto* instance = instance_from_upvalue(state);
    if (instance == nullptr || !instance->input_context_active) {
        luaL_error(state, "behavior input is unavailable outside a hook");
        return 0;
    }
    lua_pushnumber(state, instance->move_x);
    lua_pushnumber(state, instance->move_y);
    return 2;
}

static void remove_forbidden_globals(lua_State* state)
{
    lua_pushnil(state);
    lua_setglobal(state, "io");
    lua_pushnil(state);
    lua_setglobal(state, "os");
    lua_pushnil(state);
    lua_setglobal(state, "debug");
    lua_pushnil(state);
    lua_setglobal(state, "require");
}

static int validate_behavior_table(lua_State* state, int table_index, char* error_buffer, size_t error_buffer_size)
{
    table_index = lua_absindex(state, table_index);
    lua_pushnil(state);
    while (lua_next(state, table_index) != 0)
    {
        size_t key_length = 0;
        const char* key = lua_tolstring(state, -2, &key_length);
        const bool allowed = key != nullptr &&
            ((key_length == 8 && std::memcmp(key, "on_start", 8) == 0) ||
             (key_length == 12 && std::memcmp(key, "fixed_update", 12) == 0));
        if (!allowed)
        {
            write_error(error_buffer, error_buffer_size, "behavior table contains an unknown field");
            lua_pop(state, 2);
            return 0;
        }
        if (!lua_isfunction(state, -1))
        {
            write_error(error_buffer, error_buffer_size, "behavior hook must be a function");
            lua_pop(state, 2);
            return 0;
        }
        lua_pop(state, 1);
    }
    return 1;
}

static int install_environment(KadathLuauInstance* instance, char* error_buffer, size_t error_buffer_size)
{
    lua_State* state = instance->thread;
    lua_createtable(state, 0, 2);
    lua_createtable(state, 0, 1);
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, parameter_number, "number", 1);
    lua_setfield(state, -2, "number");
    lua_setfield(state, -2, "parameter");
    lua_createtable(state, 0, 1);
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, input_move_axis, "move_axis", 1);
    lua_setfield(state, -2, "move_axis");
    lua_setreadonly(state, -1, true);
    lua_setfield(state, -2, "input");
    lua_setreadonly(state, -1, true);
    lua_setglobal(state, "kadath");

    lua_createtable(state, 0, 3);
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, self_id, "id", 1);
    lua_setfield(state, -2, "id");
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, self_position, "position", 1);
    lua_setfield(state, -2, "position");
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, self_translate, "translate", 1);
    lua_setfield(state, -2, "translate");
    lua_setreadonly(state, -1, true);
    instance->self_ref = lua_ref(state, -1);
    lua_pop(state, 1);
    (void)error_buffer;
    (void)error_buffer_size;
    return 1;
}

static int load_behavior(KadathLuauInstance* instance, char* error_buffer, size_t error_buffer_size)
{
    lua_State* state = instance->thread;
    if (luau_load(state, "behavior", reinterpret_cast<const char*>(instance->asset->bytecode), instance->asset->bytecode_size, 0) != 0)
    {
        write_error(error_buffer, error_buffer_size, lua_tostring(state, -1));
        lua_pop(state, 1);
        return 0;
    }
    if (!protected_call(instance->asset, state, 0, 1, error_buffer, error_buffer_size))
        return 0;
    if (!lua_istable(state, -1))
    {
        write_error(error_buffer, error_buffer_size, "behavior chunk must return a table");
        lua_pop(state, 1);
        return 0;
    }
    if (!validate_behavior_table(state, -1, error_buffer, error_buffer_size))
    {
        lua_pop(state, 1);
        return 0;
    }
    instance->behavior_ref = lua_ref(state, -1);
    lua_pop(state, 1);
    return 1;
}

static int run_hook(
    KadathLuauInstance* instance,
    const char* hook_name,
    bool with_delta,
    double dt_seconds,
    double position_x,
    double position_y,
    const KadathLuauInputSnapshot& input_snapshot,
    KadathLuauTranslateCommand* commands,
    size_t command_capacity,
    size_t* command_count,
    char* error_buffer,
    size_t error_buffer_size)
{
    if (instance == nullptr || command_count == nullptr)
        return 0;
    *command_count = 0;
    instance->position_x = position_x;
    instance->position_y = position_y;
    instance->move_x = input_snapshot.move_x;
    instance->move_y = input_snapshot.move_y;
    instance->input_context_active = true;
    struct InputContextGuard
    {
        KadathLuauInstance* instance;
        ~InputContextGuard()
        {
            instance->move_x = 0;
            instance->move_y = 0;
            instance->input_context_active = false;
        }
    } input_context_guard{instance};
    instance->pending_command_count = 0;
    lua_State* state = instance->thread;
    lua_settop(state, 0);
    lua_getref(state, instance->behavior_ref);
    lua_getfield(state, -1, hook_name);
    if (lua_isnil(state, -1))
    {
        lua_pop(state, 2);
        return 1;
    }
    if (!lua_isfunction(state, -1))
    {
        write_error(error_buffer, error_buffer_size, "behavior hook must be a function");
        lua_pop(state, 2);
        return 0;
    }
    lua_getref(state, instance->self_ref);
    int argument_count = 1;
    if (with_delta)
    {
        if (!std::isfinite(dt_seconds) || dt_seconds < 0.0)
        {
            write_error(error_buffer, error_buffer_size, "fixed step delta must be finite and non-negative");
            lua_pop(state, 3);
            return 0;
        }
        lua_pushnumber(state, dt_seconds);
        argument_count = 2;
    }
    if (!protected_call(instance->asset, state, argument_count, 0, error_buffer, error_buffer_size))
    {
        lua_pop(state, 1);
        return 0;
    }
    lua_pop(state, 1);
    if (instance->pending_command_count > command_capacity)
    {
        write_error(error_buffer, error_buffer_size, "behavior command output buffer is too small");
        return 0;
    }
    if (instance->pending_command_count > 0 && commands == nullptr)
    {
        write_error(error_buffer, error_buffer_size, "behavior command output buffer is null");
        return 0;
    }
    for (size_t index = 0; index < instance->pending_command_count; ++index)
        commands[index] = instance->pending_commands[index];
    *command_count = instance->pending_command_count;
    return 1;
}

extern "C" KadathLuauAsset* kadath_luau_asset_create(
    const uint8_t* bytecode,
    size_t bytecode_size,
    size_t memory_limit,
    int interrupt_limit,
    char* error_buffer,
    size_t error_buffer_size)
{
    if (bytecode == nullptr || bytecode_size == 0 || memory_limit == 0 || interrupt_limit <= 0)
    {
        write_error(error_buffer, error_buffer_size, "invalid Luau asset configuration");
        return nullptr;
    }
    auto* asset = new (std::nothrow) KadathLuauAsset();
    if (asset == nullptr)
    {
        write_error(error_buffer, error_buffer_size, "Luau asset allocation failed");
        return nullptr;
    }
    asset->allocator.limit = memory_limit;
    asset->interrupt_limit = interrupt_limit;
    asset->bytecode = static_cast<uint8_t*>(std::malloc(bytecode_size));
    if (asset->bytecode == nullptr)
    {
        delete asset;
        write_error(error_buffer, error_buffer_size, "Luau bytecode allocation failed");
        return nullptr;
    }
    std::memcpy(asset->bytecode, bytecode, bytecode_size);
    asset->bytecode_size = bytecode_size;
    asset->state = lua_newstate(limited_alloc, &asset->allocator);
    if (asset->state == nullptr)
    {
        std::free(asset->bytecode);
        delete asset;
        write_error(error_buffer, error_buffer_size, "Luau VM allocation failed");
        return nullptr;
    }
    luaL_openlibs(asset->state);
    remove_forbidden_globals(asset->state);
    luaL_sandbox(asset->state);
    lua_callbacks(asset->state)->userdata = asset;
    lua_callbacks(asset->state)->interrupt = interrupt_callback;
    return asset;
}

extern "C" void kadath_luau_asset_destroy(KadathLuauAsset* asset)
{
    if (asset == nullptr)
        return;
    if (asset->state != nullptr)
        lua_close(asset->state);
    std::free(asset->bytecode);
    delete asset;
}

extern "C" size_t kadath_luau_asset_memory_used(const KadathLuauAsset* asset)
{
    return asset == nullptr ? 0 : asset->allocator.used;
}

extern "C" const char* kadath_luau_runtime_toolchain_identity(void)
{
    return "luau-0.732-decb2d0";
}

extern "C" KadathLuauInstance* kadath_luau_instance_create(
    KadathLuauAsset* asset,
    const char* object_id,
    size_t object_id_length,
    const KadathLuauParameterValue* parameters,
    size_t parameter_count,
    char* error_buffer,
    size_t error_buffer_size)
{
    if (asset == nullptr || object_id == nullptr || object_id_length == 0 || object_id_length > KADATH_LUAU_MAX_OBJECT_ID_BYTES || parameter_count > KADATH_LUAU_MAX_PARAMETER_COUNT)
    {
        write_error(error_buffer, error_buffer_size, "invalid behavior instance configuration");
        return nullptr;
    }
    auto* instance = new (std::nothrow) KadathLuauInstance();
    if (instance == nullptr)
    {
        write_error(error_buffer, error_buffer_size, "behavior instance allocation failed");
        return nullptr;
    }
    instance->asset = asset;
    instance->object_id_length = object_id_length;
    std::memcpy(instance->object_id, object_id, object_id_length);
    for (size_t index = 0; index < parameter_count; ++index)
    {
        if (!valid_name(parameters[index].name, parameters[index].name_length) || !std::isfinite(parameters[index].value))
        {
            delete instance;
            write_error(error_buffer, error_buffer_size, "invalid behavior parameter value");
            return nullptr;
        }
        for (size_t existing_index = 0; existing_index < index; ++existing_index)
        {
            if (parameters[existing_index].name_length == parameters[index].name_length &&
                std::memcmp(parameters[existing_index].name, parameters[index].name, parameters[index].name_length) == 0)
            {
                delete instance;
                write_error(error_buffer, error_buffer_size, "duplicate behavior parameter value");
                return nullptr;
            }
        }
        std::memcpy(instance->parameter_names[index], parameters[index].name, parameters[index].name_length);
        instance->parameter_names[index][parameters[index].name_length] = '\0';
        instance->parameter_values[index] = parameters[index];
        instance->parameter_values[index].name = instance->parameter_names[index];
    }
    instance->parameter_count = parameter_count;
    instance->thread = lua_newthread(asset->state);
    if (instance->thread == nullptr)
    {
        delete instance;
        write_error(error_buffer, error_buffer_size, "behavior thread allocation failed");
        return nullptr;
    }
    instance->thread_ref = lua_ref(asset->state, -1);
    lua_pop(asset->state, 1);
    luaL_sandboxthread(instance->thread);
    lua_callbacks(instance->thread)->userdata = asset;
    lua_callbacks(instance->thread)->interrupt = interrupt_callback;
    install_environment(instance, error_buffer, error_buffer_size);
    if (!load_behavior(instance, error_buffer, error_buffer_size))
    {
        kadath_luau_instance_destroy(instance);
        return nullptr;
    }
    return instance;
}

extern "C" void kadath_luau_instance_destroy(KadathLuauInstance* instance)
{
    if (instance == nullptr)
        return;
    if (instance->asset != nullptr && instance->asset->state != nullptr)
    {
        if (instance->behavior_ref != LUA_NOREF)
            lua_unref(instance->thread, instance->behavior_ref);
        if (instance->self_ref != LUA_NOREF)
            lua_unref(instance->thread, instance->self_ref);
        if (instance->thread_ref != LUA_NOREF)
            lua_unref(instance->asset->state, instance->thread_ref);
    }
    delete instance;
}

extern "C" int kadath_luau_instance_on_start(
    KadathLuauInstance* instance,
    double position_x,
    double position_y,
    KadathLuauTranslateCommand* commands,
    size_t command_capacity,
    size_t* command_count,
    char* error_buffer,
    size_t error_buffer_size)
{
    const KadathLuauInputSnapshot input_snapshot{};
    return run_hook(instance, "on_start", false, 0.0, position_x, position_y, input_snapshot, commands, command_capacity, command_count, error_buffer, error_buffer_size);
}

extern "C" int kadath_luau_instance_fixed_update(
    KadathLuauInstance* instance,
    double dt_seconds,
    double position_x,
    double position_y,
    const KadathLuauInputSnapshot* input_snapshot,
    KadathLuauTranslateCommand* commands,
    size_t command_capacity,
    size_t* command_count,
    char* error_buffer,
    size_t error_buffer_size)
{
    if (command_count != nullptr)
        *command_count = 0;
    if (input_snapshot == nullptr || input_snapshot->move_x < -1 || input_snapshot->move_x > 1 ||
        input_snapshot->move_y < -1 || input_snapshot->move_y > 1)
    {
        write_error(error_buffer, error_buffer_size, "behavior input axes must be -1, 0, or 1");
        return 0;
    }
    return run_hook(instance, "fixed_update", true, dt_seconds, position_x, position_y, *input_snapshot, commands, command_capacity, command_count, error_buffer, error_buffer_size);
}
