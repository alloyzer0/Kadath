#include "kadath_luau.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>

#include "Luau/BuiltinDefinitions.h"
#include "Luau/Config.h"
#include "Luau/ConfigResolver.h"
#include "Luau/Error.h"
#include "Luau/FileResolver.h"
#include "Luau/Frontend.h"
#include "Luau/GlobalTypes.h"
#include "Luau/Type.h"
#include "luacode.h"
#include "lua.h"
#include "lualib.h"

struct ToolingContext
{
    KadathLuauCompileResult* result = nullptr;
    char* error_buffer = nullptr;
    size_t error_buffer_size = 0;
};

struct ToolingExecutionBudget
{
    size_t used = 0;
    size_t limit = 2 * 1024 * 1024;
    int interrupt_count = 0;
    int interrupt_limit = 100000;
};

struct AnalysisFileResolver final : Luau::FileResolver
{
    std::string module_name;
    std::string source;

    std::optional<Luau::SourceCode> readSource(const Luau::ModuleName& name) override
    {
        if (name != module_name)
            return std::nullopt;
        return Luau::SourceCode{source, Luau::SourceCode::Script};
    }

    std::string getHumanReadableModuleName(const Luau::ModuleName& name) const override
    {
        return name;
    }
};

struct AnalysisConfigResolver final : Luau::ConfigResolver
{
    Luau::Config config;

    AnalysisConfigResolver()
    {
        config.mode = Luau::Mode::Strict;
    }

    const Luau::Config& getConfig(const Luau::ModuleName&, const Luau::TypeCheckLimits&) const override
    {
        return config;
    }
};

static constexpr const char* host_definition = R"(
export type Object = {
    id: (self: Object) -> string,
    position: (self: Object) -> { x: number, y: number },
    translate: (self: Object, dx: number, dy: number) -> (),
}

declare kadath: {
    parameter: {
        number: (name: string, options: { default: number, min: number, max: number }) -> number,
    },
}
)";

static void write_error(char* buffer, size_t size, const char* message)
{
    if (buffer == nullptr || size == 0)
        return;
    if (message == nullptr)
        message = "unknown Luau tooling error";
    size_t length = std::strlen(message);
    if (length >= size)
        length = size - 1;
    std::memcpy(buffer, message, length);
    buffer[length] = '\0';
}

static void* limited_alloc(void* userdata, void* pointer, size_t old_size, size_t new_size)
{
    auto* budget = static_cast<ToolingExecutionBudget*>(userdata);
    if (new_size == 0)
    {
        if (pointer != nullptr)
        {
            budget->used = budget->used >= old_size ? budget->used - old_size : 0;
            std::free(pointer);
        }
        return nullptr;
    }
    const size_t retained = budget->used >= old_size ? budget->used - old_size : 0;
    if (new_size > budget->limit - std::min(retained, budget->limit))
        return nullptr;
    void* replacement = std::realloc(pointer, new_size);
    if (replacement == nullptr)
        return nullptr;
    budget->used = retained + new_size;
    return replacement;
}

static void interrupt_callback(lua_State* state, int gc)
{
    if (gc >= 0)
        return;
    auto* budget = static_cast<ToolingExecutionBudget*>(lua_callbacks(state)->userdata);
    if (budget == nullptr)
        return;
    budget->interrupt_count += 1;
    if (budget->interrupt_count >= budget->interrupt_limit)
        luaL_error(state, "behavior tooling execution budget exceeded");
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

static void remove_analysis_global(Luau::Frontend& frontend, const char* name)
{
    const Luau::AstName ast_name = frontend.globals.globalNames.names->getOrAdd(name);
    frontend.globals.globalScope->bindings.erase(Luau::Symbol{ast_name});
}

static bool analyze_source(
    const char* source,
    size_t source_length,
    const char* chunk_name,
    char* error_buffer,
    size_t error_buffer_size)
{
    try
    {
        AnalysisFileResolver file_resolver;
        file_resolver.module_name = chunk_name == nullptr ? "behavior" : chunk_name;
        file_resolver.source.assign(source, source_length);
        AnalysisConfigResolver config_resolver;
        Luau::FrontendOptions frontend_options;
        frontend_options.moduleTimeLimitSec = 0.25;
        frontend_options.applyInternalLimitScaling = true;
        Luau::Frontend frontend(&file_resolver, &config_resolver, frontend_options);
        Luau::registerBuiltinGlobals(frontend, frontend.globals);
        remove_analysis_global(frontend, "io");
        remove_analysis_global(frontend, "os");
        remove_analysis_global(frontend, "debug");
        remove_analysis_global(frontend, "require");

        Luau::unfreeze(frontend.globals.globalTypes);
        const Luau::LoadDefinitionFileResult definitions = frontend.loadDefinitionFile(
            frontend.globals,
            frontend.globals.globalScope,
            host_definition,
            "@kadath",
            false);
        if (!definitions.success)
        {
            Luau::freeze(frontend.globals.globalTypes);
            write_error(error_buffer, error_buffer_size, "Kadath behavior host definition failed");
            return false;
        }
        const auto object_type = frontend.globals.globalScope->exportedTypeBindings.find("Object");
        if (object_type == frontend.globals.globalScope->exportedTypeBindings.end())
        {
            Luau::freeze(frontend.globals.globalTypes);
            write_error(error_buffer, error_buffer_size, "Kadath behavior Object type is unavailable");
            return false;
        }
        frontend.globals.globalScope->importedTypeBindings["Kadath"]["Object"] = object_type->second;
        Luau::freeze(frontend.globals.globalTypes);

        const Luau::CheckResult analysis = frontend.check(file_resolver.module_name);
        if (!analysis.timeoutHits.empty())
        {
            write_error(error_buffer, error_buffer_size, "Luau Analysis budget exceeded");
            return false;
        }
        if (!analysis.errors.empty())
        {
            const Luau::TypeError& error = analysis.errors.front();
            const std::string message = file_resolver.module_name + ":" +
                std::to_string(error.location.begin.line + 1) + ":" +
                std::to_string(error.location.begin.column + 1) + ": " +
                Luau::toString(error, Luau::TypeErrorToStringOptions{&file_resolver});
            write_error(error_buffer, error_buffer_size, message.c_str());
            return false;
        }
        return true;
    }
    catch (const std::exception& exception)
    {
        write_error(error_buffer, error_buffer_size, exception.what());
        return false;
    }
    catch (...)
    {
        write_error(error_buffer, error_buffer_size, "unknown Luau Analysis failure");
        return false;
    }
}

static ToolingContext* context_from_upvalue(lua_State* state)
{
    return static_cast<ToolingContext*>(lua_touserdata(state, lua_upvalueindex(1)));
}

static int parameter_number(lua_State* state)
{
    auto* context = context_from_upvalue(state);
    size_t name_length = 0;
    const char* name = lua_tolstring(state, 1, &name_length);
    if (context == nullptr || !valid_name(name, name_length)) {
        luaL_error(state, "invalid behavior parameter name");
        return 0;
    }
    if (!lua_istable(state, 2)) {
        luaL_error(state, "behavior parameter options must be a table");
        return 0;
    }
    if (context->result->parameter_count >= KADATH_LUAU_MAX_PARAMETER_COUNT) {
        luaL_error(state, "behavior parameter count exceeded");
        return 0;
    }
    lua_getfield(state, 2, "default");
    lua_getfield(state, 2, "min");
    lua_getfield(state, 2, "max");
    if (!lua_isnumber(state, -3) || !lua_isnumber(state, -2) || !lua_isnumber(state, -1)) {
        luaL_error(state, "behavior number parameter requires default, min and max");
        return 0;
    }
    const double default_value = lua_tonumber(state, -3);
    const double minimum = lua_tonumber(state, -2);
    const double maximum = lua_tonumber(state, -1);
    lua_pop(state, 3);
    if (!std::isfinite(default_value) || !std::isfinite(minimum) || !std::isfinite(maximum) || minimum > maximum || default_value < minimum || default_value > maximum) {
        luaL_error(state, "behavior number parameter range is invalid");
        return 0;
    }
    for (size_t index = 0; index < context->result->parameter_count; ++index)
    {
        if (std::strncmp(context->result->parameters[index].name, name, KADATH_LUAU_MAX_PARAMETER_NAME_BYTES + 1) == 0) {
            luaL_error(state, "behavior parameter name is duplicated");
            return 0;
        }
    }
    auto& parameter = context->result->parameters[context->result->parameter_count++];
    std::memcpy(parameter.name, name, name_length);
    parameter.name[name_length] = '\0';
    parameter.default_value = default_value;
    parameter.minimum = minimum;
    parameter.maximum = maximum;
    lua_pushnumber(state, default_value);
    return 1;
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

static int protected_call(
    lua_State* state,
    int arguments,
    int results,
    ToolingContext* context,
    ToolingExecutionBudget* budget)
{
    budget->interrupt_count = 0;
    const int status = lua_pcall(state, arguments, results, 0);
    if (status != LUA_OK)
    {
        write_error(context->error_buffer, context->error_buffer_size, lua_tostring(state, -1));
        lua_pop(state, 1);
        return 0;
    }
    return 1;
}

static int validate_behavior_table(lua_State* state, int table_index, ToolingContext* context)
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
        if (!allowed || !lua_isfunction(state, -1))
        {
            write_error(context->error_buffer, context->error_buffer_size, "behavior table contains an invalid hook");
            lua_pop(state, 2);
            return 0;
        }
        lua_pop(state, 1);
    }
    return 1;
}

extern "C" int kadath_luau_compile(
    const char* source,
    size_t source_length,
    const char* chunk_name,
    KadathLuauCompileResult* result,
    char* error_buffer,
    size_t error_buffer_size)
{
    if (source == nullptr || source_length == 0 || result == nullptr)
    {
        write_error(error_buffer, error_buffer_size, "invalid Luau source input");
        return 0;
    }
    std::memset(result, 0, sizeof(*result));
    if (!analyze_source(source, source_length, chunk_name, error_buffer, error_buffer_size))
        return 0;
    lua_CompileOptions options = {};
    options.optimizationLevel = 1;
    options.debugLevel = 1;
    size_t bytecode_size = 0;
    char* bytecode = luau_compile(source, source_length, &options, &bytecode_size);
    if (bytecode == nullptr || bytecode_size == 0)
    {
        write_error(error_buffer, error_buffer_size, "Luau compiler returned no bytecode");
        std::free(bytecode);
        return 0;
    }
    ToolingExecutionBudget execution_budget;
    lua_State* state = lua_newstate(limited_alloc, &execution_budget);
    if (state == nullptr)
    {
        write_error(error_buffer, error_buffer_size, "Luau tooling VM allocation failed");
        std::free(bytecode);
        return 0;
    }
    luaL_openlibs(state);
    remove_forbidden_globals(state);
    luaL_sandbox(state);
    luaL_sandboxthread(state);
    lua_callbacks(state)->userdata = &execution_budget;
    lua_callbacks(state)->interrupt = interrupt_callback;
    ToolingContext context{ .result = result, .error_buffer = error_buffer, .error_buffer_size = error_buffer_size };
    lua_createtable(state, 0, 1);
    lua_createtable(state, 0, 1);
    lua_pushlightuserdata(state, &context);
    lua_pushcclosure(state, parameter_number, "number", 1);
    lua_setfield(state, -2, "number");
    lua_setfield(state, -2, "parameter");
    lua_setreadonly(state, -1, true);
    lua_setglobal(state, "kadath");
    const char* name = chunk_name == nullptr ? "behavior" : chunk_name;
    if (luau_load(state, name, bytecode, bytecode_size, 0) != 0 ||
        !protected_call(state, 0, 1, &context, &execution_budget))
    {
        if (error_buffer == nullptr || error_buffer[0] == '\0')
            write_error(error_buffer, error_buffer_size, lua_tostring(state, -1));
        lua_close(state);
        std::free(bytecode);
        return 0;
    }
    if (!lua_istable(state, -1) || !validate_behavior_table(state, -1, &context))
    {
        if (error_buffer == nullptr || error_buffer[0] == '\0')
            write_error(error_buffer, error_buffer_size, "behavior chunk must return a valid table");
        lua_pop(state, 1);
        lua_close(state);
        std::free(bytecode);
        return 0;
    }
    lua_pop(state, 1);
    result->bytecode = static_cast<uint8_t*>(std::malloc(bytecode_size));
    if (result->bytecode == nullptr)
    {
        write_error(error_buffer, error_buffer_size, "behavior bytecode allocation failed");
        lua_close(state);
        std::free(bytecode);
        return 0;
    }
    std::memcpy(result->bytecode, bytecode, bytecode_size);
    result->bytecode_size = bytecode_size;
    lua_close(state);
    std::free(bytecode);
    return 1;
}

extern "C" void kadath_luau_compile_result_destroy(KadathLuauCompileResult* result)
{
    if (result == nullptr)
        return;
    std::free(result->bytecode);
    std::memset(result, 0, sizeof(*result));
}

extern "C" const char* kadath_luau_toolchain_identity(void)
{
    return "luau-0.732-decb2d0";
}
