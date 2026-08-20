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
    const KadathLuauHostV3* active_host_v3 = nullptr;
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

static int raise_host_error(lua_State* state, const char* message)
{
    luaL_error(state, "%s", message);
    return 0;
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

static bool host_v3_valid(const KadathLuauHostV3* host)
{
    return host != nullptr &&
        host->version == KADATH_LUAU_HOST_INTERFACE_VERSION &&
        host->struct_size >= sizeof(KadathLuauHostV3) &&
        host->world_epoch > 0 && host->world_epoch <= 9007199254740991ULL &&
        host->resolve_object != nullptr &&
        host->get_object_position != nullptr &&
        host->set_object_position != nullptr &&
        host->post_event != nullptr;
}

static bool valid_object_handle(const KadathLuauObjectHandle& object, uint64_t expected_world_epoch)
{
    return object.world_epoch == expected_world_epoch &&
        object.world_epoch > 0 && object.world_epoch <= 9007199254740991ULL &&
        object.logical_generation > 0 && object.logical_generation <= 9007199254740991ULL &&
        object.kind >= KADATH_LUAU_OBJECT_SPRITE && object.kind <= KADATH_LUAU_OBJECT_PATROL_HAZARD &&
        object.object_id_length > 0 && object.object_id_length <= KADATH_LUAU_MAX_OBJECT_ID_BYTES;
}

static bool object_id_from_table(lua_State* state, int index, const char*& object_id, size_t& object_id_length, uint64_t& world_epoch, uint64_t& logical_generation)
{
    index = lua_absindex(state, index);
    if (!lua_istable(state, index))
        return false;
    lua_getfield(state, index, "__kadath_object_id");
    const bool object_id_valid = lua_type(state, -1) == LUA_TSTRING;
    object_id = object_id_valid ? lua_tolstring(state, -1, &object_id_length) : nullptr;
    lua_getfield(state, index, "__kadath_world_epoch");
    const double world_epoch_number = lua_tonumber(state, -1);
    const bool world_epoch_valid = lua_type(state, -1) == LUA_TNUMBER &&
        std::isfinite(world_epoch_number) && world_epoch_number >= 0.0 &&
        world_epoch_number <= 9007199254740991.0 && std::floor(world_epoch_number) == world_epoch_number;
    lua_getfield(state, index, "__kadath_logical_generation");
    const double logical_generation_number = lua_tonumber(state, -1);
    const bool logical_generation_valid = lua_type(state, -1) == LUA_TNUMBER &&
        std::isfinite(logical_generation_number) && logical_generation_number >= 1.0 &&
        logical_generation_number <= 9007199254740991.0 && std::floor(logical_generation_number) == logical_generation_number;
    lua_pop(state, 3);
    if (!object_id_valid || object_id == nullptr || object_id_length == 0 || object_id_length > KADATH_LUAU_MAX_OBJECT_ID_BYTES ||
        !world_epoch_valid || !logical_generation_valid)
        return false;
    world_epoch = static_cast<uint64_t>(world_epoch_number);
    logical_generation = static_cast<uint64_t>(logical_generation_number);
    return true;
}

static bool resolve_object_ref(lua_State* state, KadathLuauInstance* instance, int index, KadathLuauObjectHandle& object)
{
    if (instance == nullptr || instance->active_host_v3 == nullptr)
        return false;
    const char* object_id = nullptr;
    size_t object_id_length = 0;
    uint64_t world_epoch = 0;
    uint64_t logical_generation = 0;
    if (!object_id_from_table(state, index, object_id, object_id_length, world_epoch, logical_generation) ||
        world_epoch != instance->active_host_v3->world_epoch)
        return false;
    if (!instance->active_host_v3->resolve_object(instance->active_host_v3->userdata, object_id, object_id_length, &object) ||
        !valid_object_handle(object, instance->active_host_v3->world_epoch))
        return false;
    return valid_object_handle(object, world_epoch) && object.logical_generation == logical_generation;
}

static void push_object_ref(lua_State* state, KadathLuauInstance* instance, const KadathLuauObjectHandle& object);

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
    const char* object_id = nullptr;
    size_t object_id_length = 0;
    uint64_t world_epoch = 0;
    uint64_t logical_generation = 0;
    if (!object_id_from_table(state, 1, object_id, object_id_length, world_epoch, logical_generation))
        return raise_host_error(state, "invalid behavior object reference");
    if (instance->active_host_v3 != nullptr)
    {
        KadathLuauObjectHandle object{};
        if (!resolve_object_ref(state, instance, 1, object))
            return raise_host_error(state, "behavior object reference is stale or unknown");
        object_id = object.object_id;
        object_id_length = object.object_id_length;
    }
    lua_pushlstring(state, object_id, object_id_length);
    return 1;
}

static int self_is_valid(lua_State* state)
{
    auto* instance = instance_from_upvalue(state);
    if (instance == nullptr || instance->active_host_v3 == nullptr)
        return raise_host_error(state, "behavior object access is unavailable outside a Host v3 hook");
    KadathLuauObjectHandle object{};
    lua_pushboolean(state, resolve_object_ref(state, instance, 1, object));
    return 1;
}

static int self_kind(lua_State* state)
{
    auto* instance = instance_from_upvalue(state);
    KadathLuauObjectHandle object{};
    if (!resolve_object_ref(state, instance, 1, object))
        return raise_host_error(state, "behavior object reference is stale or unknown");
    const char* kind = nullptr;
    switch (object.kind)
    {
    case KADATH_LUAU_OBJECT_SPRITE: kind = "sprite"; break;
    case KADATH_LUAU_OBJECT_PLAYER: kind = "player"; break;
    case KADATH_LUAU_OBJECT_GOAL: kind = "goal"; break;
    case KADATH_LUAU_OBJECT_PATROL_HAZARD: kind = "patrol_hazard"; break;
    default: return raise_host_error(state, "behavior object kind is invalid");
    }
    lua_pushstring(state, kind);
    return 1;
}

static int self_position(lua_State* state)
{
    auto* instance = instance_from_upvalue(state);
    if (instance == nullptr) {
        luaL_error(state, "behavior host is unavailable");
        return 0;
    }
    double position_x = instance->position_x;
    double position_y = instance->position_y;
    if (instance->active_host_v3 != nullptr)
    {
        KadathLuauObjectHandle object{};
        if (!resolve_object_ref(state, instance, 1, object) ||
            !instance->active_host_v3->get_object_position(instance->active_host_v3->userdata, &object, &position_x, &position_y) ||
            !std::isfinite(position_x) || !std::isfinite(position_y))
            return raise_host_error(state, "behavior object position is unavailable");
    }
    lua_createtable(state, 0, 2);
    lua_pushnumber(state, position_x);
    lua_setfield(state, -2, "x");
    lua_pushnumber(state, position_y);
    lua_setfield(state, -2, "y");
    return 1;
}

static int self_set_position(lua_State* state)
{
    auto* instance = instance_from_upvalue(state);
    if (instance == nullptr || instance->active_host_v3 == nullptr)
        return raise_host_error(state, "behavior object mutation is unavailable outside a Host v3 hook");
    const double x = luaL_checknumber(state, 2);
    const double y = luaL_checknumber(state, 3);
    if (!std::isfinite(x) || !std::isfinite(y))
        return raise_host_error(state, "set_position arguments must be finite");
    KadathLuauObjectHandle object{};
    if (!resolve_object_ref(state, instance, 1, object))
        return raise_host_error(state, "behavior object reference is stale or unknown");
    if (!instance->active_host_v3->set_object_position(instance->active_host_v3->userdata, &object, x, y))
        return raise_host_error(state, "behavior object position mutation failed");
    return 0;
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
    if (instance->active_host_v3 != nullptr)
    {
        KadathLuauObjectHandle object{};
        double position_x = 0.0;
        double position_y = 0.0;
        if (!resolve_object_ref(state, instance, 1, object) ||
            !instance->active_host_v3->get_object_position(instance->active_host_v3->userdata, &object, &position_x, &position_y) ||
            !std::isfinite(position_x + dx) || !std::isfinite(position_y + dy) ||
            !instance->active_host_v3->set_object_position(instance->active_host_v3->userdata, &object, position_x + dx, position_y + dy))
            return raise_host_error(state, "behavior object translation failed");
        return 0;
    }
    if (instance->pending_command_count >= KADATH_LUAU_MAX_COMMAND_COUNT) {
        luaL_error(state, "behavior command budget exceeded");
        return 0;
    }
    instance->pending_commands[instance->pending_command_count++] = { dx, dy };
    return 0;
}

static int scene_find(lua_State* state)
{
    auto* instance = instance_from_upvalue(state);
    if (instance == nullptr || instance->active_host_v3 == nullptr)
        return raise_host_error(state, "behavior scene access is unavailable outside a Host v3 hook");
    size_t object_id_length = 0;
    const char* object_id = luaL_checklstring(state, 1, &object_id_length);
    if (object_id_length == 0 || object_id_length > KADATH_LUAU_MAX_OBJECT_ID_BYTES)
        return raise_host_error(state, "behavior object id is invalid");
    KadathLuauObjectHandle object{};
    if (!instance->active_host_v3->resolve_object(instance->active_host_v3->userdata, object_id, object_id_length, &object))
    {
        lua_pushnil(state);
        return 1;
    }
    push_object_ref(state, instance, object);
    return 1;
}

static int event_post(lua_State* state)
{
    auto* instance = instance_from_upvalue(state);
    if (instance == nullptr || instance->active_host_v3 == nullptr)
        return raise_host_error(state, "behavior event access is unavailable outside a Host v3 hook");
    KadathLuauPostedEvent event{};
    if (!resolve_object_ref(state, instance, 1, event.target))
        return raise_host_error(state, "behavior event target is stale or unknown");
    size_t name_length = 0;
    const char* name = luaL_checklstring(state, 2, &name_length);
    if (name_length == 0 || name_length > KADATH_LUAU_MAX_EVENT_NAME_BYTES)
        return raise_host_error(state, "behavior event name is invalid");
    event.name = name;
    event.name_length = name_length;
    if (!instance->active_host_v3->resolve_object(
            instance->active_host_v3->userdata,
            instance->object_id,
            instance->object_id_length,
            &event.sender) || !valid_object_handle(event.sender, instance->active_host_v3->world_epoch))
        return raise_host_error(state, "behavior event sender is unavailable");

    KadathLuauEventField fields[KADATH_LUAU_MAX_EVENT_FIELD_COUNT]{};
    if (!lua_isnoneornil(state, 3))
    {
        if (!lua_istable(state, 3))
            return raise_host_error(state, "behavior event payload must be a table");
        lua_pushnil(state);
        while (lua_next(state, 3) != 0)
        {
            if (event.field_count >= KADATH_LUAU_MAX_EVENT_FIELD_COUNT)
            {
                lua_pop(state, 2);
                return raise_host_error(state, "behavior event payload field limit exceeded");
            }
            KadathLuauEventField& field = fields[event.field_count];
            if (lua_type(state, -2) != LUA_TSTRING)
            {
                lua_pop(state, 2);
                return raise_host_error(state, "behavior event payload key must be a string");
            }
            field.key = lua_tolstring(state, -2, &field.key_length);
            if (field.key == nullptr || field.key_length == 0 || field.key_length > KADATH_LUAU_MAX_EVENT_KEY_BYTES)
            {
                lua_pop(state, 2);
                return raise_host_error(state, "behavior event payload key is invalid");
            }
            switch (lua_type(state, -1))
            {
            case LUA_TBOOLEAN:
                field.value.kind = KADATH_LUAU_EVENT_BOOLEAN;
                field.value.boolean_value = lua_toboolean(state, -1);
                break;
            case LUA_TNUMBER:
                field.value.kind = KADATH_LUAU_EVENT_NUMBER;
                field.value.number_value = lua_tonumber(state, -1);
                if (!std::isfinite(field.value.number_value))
                {
                    lua_pop(state, 2);
                    return raise_host_error(state, "behavior event number must be finite");
                }
                break;
            case LUA_TSTRING:
                field.value.kind = KADATH_LUAU_EVENT_STRING;
                field.value.string_value = lua_tolstring(state, -1, &field.value.string_value_length);
                if (field.value.string_value_length > KADATH_LUAU_MAX_EVENT_STRING_BYTES)
                {
                    lua_pop(state, 2);
                    return raise_host_error(state, "behavior event string limit exceeded");
                }
                break;
            case LUA_TTABLE:
                field.value.kind = KADATH_LUAU_EVENT_OBJECT;
                if (!resolve_object_ref(state, instance, -1, field.value.object_value))
                {
                    lua_pop(state, 2);
                    return raise_host_error(state, "behavior event object is stale or invalid");
                }
                break;
            default:
                lua_pop(state, 2);
                return raise_host_error(state, "behavior event payload value is invalid");
            }
            event.field_count += 1;
            lua_pop(state, 1);
        }
    }
    event.fields = event.field_count == 0 ? nullptr : fields;
    if (!instance->active_host_v3->post_event(instance->active_host_v3->userdata, &event))
        return raise_host_error(state, "behavior event queue rejected the event");
    return 0;
}

static void push_object_ref(lua_State* state, KadathLuauInstance* instance, const KadathLuauObjectHandle& object)
{
    lua_createtable(state, 0, 10);
    lua_pushlstring(state, object.object_id, object.object_id_length);
    lua_setfield(state, -2, "__kadath_object_id");
    lua_pushnumber(state, static_cast<double>(object.world_epoch));
    lua_setfield(state, -2, "__kadath_world_epoch");
    lua_pushnumber(state, static_cast<double>(object.logical_generation));
    lua_setfield(state, -2, "__kadath_logical_generation");
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, self_id, "id", 1);
    lua_setfield(state, -2, "id");
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, self_kind, "kind", 1);
    lua_setfield(state, -2, "kind");
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, self_is_valid, "is_valid", 1);
    lua_setfield(state, -2, "is_valid");
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, self_position, "position", 1);
    lua_setfield(state, -2, "position");
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, self_set_position, "set_position", 1);
    lua_setfield(state, -2, "set_position");
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, self_translate, "translate", 1);
    lua_setfield(state, -2, "translate");
    lua_setreadonly(state, -1, true);
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
             (key_length == 12 && std::memcmp(key, "fixed_update", 12) == 0) ||
             (key_length == 6 && std::memcmp(key, "update", 6) == 0) ||
             (key_length == 8 && std::memcmp(key, "on_event", 8) == 0));
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
    lua_createtable(state, 0, 4);
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
    lua_createtable(state, 0, 1);
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, scene_find, "find", 1);
    lua_setfield(state, -2, "find");
    lua_setreadonly(state, -1, true);
    lua_setfield(state, -2, "scene");
    lua_createtable(state, 0, 1);
    lua_pushlightuserdata(state, instance);
    lua_pushcclosure(state, event_post, "post", 1);
    lua_setfield(state, -2, "post");
    lua_setreadonly(state, -1, true);
    lua_setfield(state, -2, "event");
    lua_setreadonly(state, -1, true);
    lua_setglobal(state, "kadath");

    KadathLuauObjectHandle self{};
    self.logical_generation = 1;
    self.object_id_length = instance->object_id_length;
    std::memcpy(self.object_id, instance->object_id, instance->object_id_length);
    push_object_ref(state, instance, self);
    instance->self_ref = lua_ref(state, -1);
    lua_pop(state, 1);
    (void)error_buffer;
    (void)error_buffer_size;
    return 1;
}

static int run_hook_v3(
    KadathLuauInstance* instance,
    const char* hook_name,
    bool with_delta,
    double dt_seconds,
    const KadathLuauInputSnapshot& input_snapshot,
    const KadathLuauHostV3* host,
    char* error_buffer,
    size_t error_buffer_size)
{
    if (instance == nullptr || !host_v3_valid(host))
    {
        write_error(error_buffer, error_buffer_size, "UnsupportedBehaviorHostInterface");
        return 0;
    }
    if (input_snapshot.move_x < -1 || input_snapshot.move_x > 1 || input_snapshot.move_y < -1 || input_snapshot.move_y > 1)
    {
        write_error(error_buffer, error_buffer_size, "behavior input axes must be -1, 0, or 1");
        return 0;
    }
    instance->move_x = input_snapshot.move_x;
    instance->move_y = input_snapshot.move_y;
    instance->input_context_active = true;
    instance->active_host_v3 = host;
    struct HostContextGuard
    {
        KadathLuauInstance* instance;
        ~HostContextGuard()
        {
            instance->move_x = 0;
            instance->move_y = 0;
            instance->input_context_active = false;
            instance->active_host_v3 = nullptr;
        }
    } host_context_guard{instance};

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
    KadathLuauObjectHandle self{};
    if (!host->resolve_object(host->userdata, instance->object_id, instance->object_id_length, &self) ||
        !valid_object_handle(self, host->world_epoch))
    {
        write_error(error_buffer, error_buffer_size, "behavior self object is unavailable");
        lua_pop(state, 2);
        return 0;
    }
    push_object_ref(state, instance, self);
    int argument_count = 1;
    if (with_delta)
    {
        if (!std::isfinite(dt_seconds) || dt_seconds < 0.0)
        {
            write_error(error_buffer, error_buffer_size, "behavior delta must be finite and non-negative");
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
    return 1;
}

static bool valid_event(const KadathLuauEvent* event)
{
    if (event == nullptr || event->name == nullptr || event->name_length == 0 ||
        event->name_length > KADATH_LUAU_MAX_EVENT_NAME_BYTES ||
        event->has_sender > 1 || event->has_other > 1 ||
        event->field_count > KADATH_LUAU_MAX_EVENT_FIELD_COUNT ||
        (event->field_count > 0 && event->fields == nullptr))
        return false;
    if (event->domain != KADATH_LUAU_EVENT_DOMAIN_FIXED && event->domain != KADATH_LUAU_EVENT_DOMAIN_FRAME)
        return false;
    const auto valid_object = [](const KadathLuauObjectHandle& object) {
        return object.world_epoch > 0 && object.world_epoch <= 9007199254740991ULL &&
            object.logical_generation > 0 && object.logical_generation <= 9007199254740991ULL &&
            object.kind >= KADATH_LUAU_OBJECT_SPRITE && object.kind <= KADATH_LUAU_OBJECT_PATROL_HAZARD &&
            object.object_id_length > 0 && object.object_id_length <= KADATH_LUAU_MAX_OBJECT_ID_BYTES;
    };
    if ((event->has_sender && !valid_object(event->sender)) || (event->has_other && !valid_object(event->other)))
        return false;
    for (size_t index = 0; index < event->field_count; ++index)
    {
        const KadathLuauEventField& field = event->fields[index];
        if (field.key == nullptr || field.key_length == 0 || field.key_length > KADATH_LUAU_MAX_EVENT_KEY_BYTES)
            return false;
        switch (field.value.kind)
        {
        case KADATH_LUAU_EVENT_BOOLEAN:
            if (field.value.boolean_value != 0 && field.value.boolean_value != 1) return false;
            break;
        case KADATH_LUAU_EVENT_NUMBER:
            if (!std::isfinite(field.value.number_value)) return false;
            break;
        case KADATH_LUAU_EVENT_STRING:
            if (field.value.string_value == nullptr || field.value.string_value_length > KADATH_LUAU_MAX_EVENT_STRING_BYTES) return false;
            break;
        case KADATH_LUAU_EVENT_OBJECT:
            if (!valid_object(field.value.object_value)) return false;
            break;
        default:
            return false;
        }
    }
    return true;
}

static void push_event_value(lua_State* state, KadathLuauInstance* instance, const KadathLuauEventValue& value)
{
    switch (value.kind)
    {
    case KADATH_LUAU_EVENT_BOOLEAN: lua_pushboolean(state, value.boolean_value); break;
    case KADATH_LUAU_EVENT_NUMBER: lua_pushnumber(state, value.number_value); break;
    case KADATH_LUAU_EVENT_STRING: lua_pushlstring(state, value.string_value, value.string_value_length); break;
    case KADATH_LUAU_EVENT_OBJECT: push_object_ref(state, instance, value.object_value); break;
    default: lua_pushnil(state); break;
    }
}

static void push_event(lua_State* state, KadathLuauInstance* instance, const KadathLuauEvent& event)
{
    lua_createtable(state, 0, 5);
    lua_pushlstring(state, event.name, event.name_length);
    lua_setfield(state, -2, "name");
    lua_pushstring(state, event.domain == KADATH_LUAU_EVENT_DOMAIN_FIXED ? "fixed" : "frame");
    lua_setfield(state, -2, "domain");
    if (event.has_sender) push_object_ref(state, instance, event.sender); else lua_pushnil(state);
    lua_setfield(state, -2, "sender");
    if (event.has_other) push_object_ref(state, instance, event.other); else lua_pushnil(state);
    lua_setfield(state, -2, "other");
    lua_createtable(state, 0, static_cast<int>(event.field_count));
    for (size_t index = 0; index < event.field_count; ++index)
    {
        const KadathLuauEventField& field = event.fields[index];
        lua_pushlstring(state, field.key, field.key_length);
        push_event_value(state, instance, field.value);
        lua_settable(state, -3);
    }
    lua_setreadonly(state, -1, true);
    lua_setfield(state, -2, "payload");
    lua_setreadonly(state, -1, true);
}

static int run_event_hook_v3(
    KadathLuauInstance* instance,
    const KadathLuauEvent* event,
    const KadathLuauInputSnapshot& input_snapshot,
    const KadathLuauHostV3* host,
    char* error_buffer,
    size_t error_buffer_size)
{
    if (instance == nullptr || !host_v3_valid(host))
    {
        write_error(error_buffer, error_buffer_size, "UnsupportedBehaviorHostInterface");
        return 0;
    }
    if (!valid_event(event))
    {
        write_error(error_buffer, error_buffer_size, "invalid behavior event");
        return 0;
    }
    if (input_snapshot.move_x < -1 || input_snapshot.move_x > 1 || input_snapshot.move_y < -1 || input_snapshot.move_y > 1)
    {
        write_error(error_buffer, error_buffer_size, "behavior input axes must be -1, 0, or 1");
        return 0;
    }
    instance->move_x = input_snapshot.move_x;
    instance->move_y = input_snapshot.move_y;
    instance->input_context_active = true;
    instance->active_host_v3 = host;
    struct HostContextGuard
    {
        KadathLuauInstance* instance;
        ~HostContextGuard()
        {
            instance->move_x = 0;
            instance->move_y = 0;
            instance->input_context_active = false;
            instance->active_host_v3 = nullptr;
        }
    } host_context_guard{instance};

    lua_State* state = instance->thread;
    lua_settop(state, 0);
    lua_getref(state, instance->behavior_ref);
    lua_getfield(state, -1, "on_event");
    if (lua_isnil(state, -1))
    {
        lua_pop(state, 2);
        return 1;
    }
    KadathLuauObjectHandle self{};
    if (!host->resolve_object(host->userdata, instance->object_id, instance->object_id_length, &self) ||
        !valid_object_handle(self, host->world_epoch))
    {
        write_error(error_buffer, error_buffer_size, "behavior self object is unavailable");
        lua_pop(state, 2);
        return 0;
    }
    push_object_ref(state, instance, self);
    push_event(state, instance, *event);
    if (!protected_call(instance->asset, state, 2, 0, error_buffer, error_buffer_size))
    {
        lua_pop(state, 1);
        return 0;
    }
    lua_pop(state, 1);
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

extern "C" int kadath_luau_instance_on_start_v3(
    KadathLuauInstance* instance,
    const KadathLuauHostV3* host,
    char* error_buffer,
    size_t error_buffer_size)
{
    const KadathLuauInputSnapshot input_snapshot{};
    return run_hook_v3(instance, "on_start", false, 0.0, input_snapshot, host, error_buffer, error_buffer_size);
}

extern "C" int kadath_luau_instance_fixed_update_v3(
    KadathLuauInstance* instance,
    double dt_seconds,
    const KadathLuauInputSnapshot* input_snapshot,
    const KadathLuauHostV3* host,
    char* error_buffer,
    size_t error_buffer_size)
{
    if (input_snapshot == nullptr)
    {
        write_error(error_buffer, error_buffer_size, "behavior input snapshot is required");
        return 0;
    }
    return run_hook_v3(instance, "fixed_update", true, dt_seconds, *input_snapshot, host, error_buffer, error_buffer_size);
}

extern "C" int kadath_luau_instance_update_v3(
    KadathLuauInstance* instance,
    double dt_seconds,
    const KadathLuauInputSnapshot* input_snapshot,
    const KadathLuauHostV3* host,
    char* error_buffer,
    size_t error_buffer_size)
{
    if (input_snapshot == nullptr)
    {
        write_error(error_buffer, error_buffer_size, "behavior input snapshot is required");
        return 0;
    }
    return run_hook_v3(instance, "update", true, dt_seconds, *input_snapshot, host, error_buffer, error_buffer_size);
}

extern "C" int kadath_luau_instance_on_event_v3(
    KadathLuauInstance* instance,
    const KadathLuauEvent* event,
    const KadathLuauInputSnapshot* input_snapshot,
    const KadathLuauHostV3* host,
    char* error_buffer,
    size_t error_buffer_size)
{
    if (input_snapshot == nullptr)
    {
        write_error(error_buffer, error_buffer_size, "behavior input snapshot is required");
        return 0;
    }
    return run_event_hook_v3(instance, event, *input_snapshot, host, error_buffer, error_buffer_size);
}
