#include "kadath_luau.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <string>
#include <string_view>
#include <tuple>
#include <vector>

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

enum class ToolingFailureKind
{
    none,
    invalid_parameter,
};

struct ToolingContext
{
    KadathLuauCompileResult* result = nullptr;
    ToolingFailureKind failure = ToolingFailureKind::none;
};

struct ToolingExecutionBudget
{
    size_t used = 0;
    size_t limit = 2 * 1024 * 1024;
    int interrupt_count = 0;
    int interrupt_limit = 100000;
    bool execution_budget_exceeded = false;
    bool memory_limit_exceeded = false;
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

struct PendingDiagnostic
{
    uint32_t severity = KADATH_LUAU_DIAGNOSTIC_ERROR;
    uint32_t stage = 0;
    uint32_t code = 0;
    bool has_range = false;
    KadathLuauSourcePosition start{};
    KadathLuauSourcePosition end{};
    std::string message;
};

struct PipelineOutput
{
    KadathLuauCompileResult compiled{};
    std::vector<PendingDiagnostic> diagnostics;

    PipelineOutput() = default;
    PipelineOutput(const PipelineOutput&) = delete;
    PipelineOutput& operator=(const PipelineOutput&) = delete;
    PipelineOutput(PipelineOutput&&) = delete;
    PipelineOutput& operator=(PipelineOutput&&) = delete;

    ~PipelineOutput()
    {
        std::free(compiled.bytecode);
    }
};

struct BytecodeDeleter
{
    void operator()(char* bytecode) const noexcept
    {
        std::free(bytecode);
    }
};

struct LuaStateDeleter
{
    void operator()(lua_State* state) const noexcept
    {
        if (state != nullptr)
            lua_close(state);
    }
};

static constexpr const char* host_definition = R"(
export type ObjectKind = "sprite" | "player" | "goal" | "patrol_hazard"

export type Object = {
    id: (self: Object) -> string,
    kind: (self: Object) -> ObjectKind,
    is_valid: (self: Object) -> boolean,
    position: (self: Object) -> { x: number, y: number },
    set_position: (self: Object, x: number, y: number) -> (),
    translate: (self: Object, dx: number, dy: number) -> (),
    destroy: (self: Object) -> (),
}

export type EventValue = boolean | number | string | Object
export type EventPayload = { [string]: EventValue }
export type Event = {
    name: string,
    domain: "fixed" | "frame",
    sender: Object?,
    other: Object?,
    payload: EventPayload,
}

declare kadath: {
    parameter: {
        number: (name: string, options: { default: number, min: number, max: number }) -> number,
    },
    input: {
        move_axis: () -> (number, number),
    },
    scene: {
        find: (object_id: string) -> Object?,
        spawn: (prototype_id: string, x: number, y: number) -> Object,
    },
    event: {
        post: (target: Object, name: string, payload: EventPayload?) -> (),
    },
}
)";

static void clear_error(char* buffer, size_t size)
{
    if (buffer != nullptr && size != 0)
        buffer[0] = '\0';
}

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

static bool utf8_scalar_width(const char* bytes, size_t size, size_t offset, size_t& width)
{
    if (offset >= size)
        return false;
    const auto first = static_cast<unsigned char>(bytes[offset]);
    if (first <= 0x7f)
    {
        width = 1;
        return true;
    }

    uint32_t scalar = 0;
    if (first >= 0xc2 && first <= 0xdf)
    {
        width = 2;
        scalar = first & 0x1f;
    }
    else if (first >= 0xe0 && first <= 0xef)
    {
        width = 3;
        scalar = first & 0x0f;
    }
    else if (first >= 0xf0 && first <= 0xf4)
    {
        width = 4;
        scalar = first & 0x07;
    }
    else
    {
        return false;
    }
    if (width > size - offset)
        return false;

    for (size_t index = 1; index < width; ++index)
    {
        const auto continuation = static_cast<unsigned char>(bytes[offset + index]);
        if ((continuation & 0xc0) != 0x80)
            return false;
        scalar = (scalar << 6) | (continuation & 0x3f);
    }
    if ((width == 3 && scalar < 0x800) ||
        (width == 4 && scalar < 0x10000) ||
        (scalar >= 0xd800 && scalar <= 0xdfff) ||
        scalar > 0x10ffff)
    {
        return false;
    }
    return true;
}

static bool valid_utf8(const char* bytes, size_t size)
{
    size_t offset = 0;
    while (offset < size)
    {
        size_t width = 0;
        if (!utf8_scalar_width(bytes, size, offset, width))
            return false;
        offset += width;
    }
    return true;
}

static size_t bounded_utf8_prefix(std::string_view value, size_t maximum)
{
    size_t offset = 0;
    size_t accepted = 0;
    while (offset < value.size())
    {
        size_t width = 0;
        if (!utf8_scalar_width(value.data(), value.size(), offset, width))
            return 0;
        if (offset + width > maximum)
            break;
        offset += width;
        accepted = offset;
    }
    return accepted;
}

class SourceCoordinates
{
public:
    SourceCoordinates(const char* source, size_t source_length)
        : source_(source, source_length)
    {
        line_starts_.push_back(0);
        for (size_t offset = 0; offset < source_.size(); ++offset)
        {
            if (source_[offset] == '\n')
                line_starts_.push_back(offset + 1);
        }
    }

    bool fromLuau(const Luau::Location& location, KadathLuauSourcePosition& start, KadathLuauSourcePosition& end) const
    {
        if (location.begin.line == std::numeric_limits<unsigned int>::max() ||
            location.begin.column == std::numeric_limits<unsigned int>::max() ||
            location.end.line == std::numeric_limits<unsigned int>::max() ||
            location.end.column == std::numeric_limits<unsigned int>::max())
        {
            return false;
        }
        if (!fromLineByteColumn(location.begin.line, location.begin.column, start) ||
            !fromLineByteColumn(location.end.line, location.end.column, end))
        {
            return false;
        }
        return std::tie(start.line, start.column) <= std::tie(end.line, end.column);
    }

    bool fromOffset(size_t offset, KadathLuauSourcePosition& position) const
    {
        if (offset > source_.size())
            return false;
        const auto iterator = std::upper_bound(line_starts_.begin(), line_starts_.end(), offset);
        const size_t line_index = iterator == line_starts_.begin() ? 0 : static_cast<size_t>(iterator - line_starts_.begin() - 1);
        const size_t line_start = line_starts_[line_index];
        return makePosition(line_index, line_start, offset, position);
    }

private:
    bool fromLineByteColumn(size_t line_index, size_t byte_column, KadathLuauSourcePosition& position) const
    {
        if (line_index >= line_starts_.size())
            return false;
        const size_t line_start = line_starts_[line_index];
        const size_t line_end = line_index + 1 < line_starts_.size() ? line_starts_[line_index + 1] - 1 : source_.size();
        if (byte_column > line_end - line_start)
            return false;
        return makePosition(line_index, line_start, line_start + byte_column, position);
    }

    bool makePosition(size_t line_index, size_t line_start, size_t offset, KadathLuauSourcePosition& position) const
    {
        if (line_index >= std::numeric_limits<uint32_t>::max())
            return false;
        size_t scalar_count = 0;
        size_t cursor = line_start;
        while (cursor < offset)
        {
            size_t width = 0;
            if (!utf8_scalar_width(source_.data(), source_.size(), cursor, width) || cursor + width > offset)
                return false;
            cursor += width;
            scalar_count += 1;
        }
        if (scalar_count >= std::numeric_limits<uint32_t>::max())
            return false;
        position.line = static_cast<uint32_t>(line_index + 1);
        position.column = static_cast<uint32_t>(scalar_count + 1);
        return true;
    }

    std::string_view source_;
    std::vector<size_t> line_starts_;
};

static PendingDiagnostic make_diagnostic(uint32_t stage, uint32_t code, std::string message)
{
    PendingDiagnostic diagnostic;
    diagnostic.stage = stage;
    diagnostic.code = code;
    diagnostic.message = std::move(message);
    return diagnostic;
}

static bool prepare_message(PendingDiagnostic& diagnostic)
{
    if (diagnostic.message.empty() || diagnostic.message.find('\0') != std::string::npos ||
        !valid_utf8(diagnostic.message.data(), diagnostic.message.size()))
    {
        return false;
    }
    if (diagnostic.message.size() > KADATH_LUAU_MAX_ANALYSIS_MESSAGE_BYTES)
    {
        const size_t prefix = bounded_utf8_prefix(diagnostic.message, KADATH_LUAU_MAX_ANALYSIS_MESSAGE_BYTES);
        if (prefix == 0)
            return false;
        diagnostic.message.resize(prefix);
    }
    return true;
}

static bool diagnostic_less(const PendingDiagnostic& left, const PendingDiagnostic& right)
{
    if (left.has_range != right.has_range)
        return left.has_range;
    if (left.has_range)
    {
        const auto left_range = std::tie(left.start.line, left.start.column, left.end.line, left.end.column);
        const auto right_range = std::tie(right.start.line, right.start.column, right.end.line, right.end.column);
        if (left_range != right_range)
            return left_range < right_range;
    }
    return std::tie(left.stage, left.code, left.message) < std::tie(right.stage, right.code, right.message);
}

static bool finalize_analysis(std::vector<PendingDiagnostic> diagnostics, KadathLuauAnalysisResult* result)
{
    for (PendingDiagnostic& diagnostic : diagnostics)
    {
        if (!prepare_message(diagnostic))
            return false;
    }
    std::stable_sort(diagnostics.begin(), diagnostics.end(), diagnostic_less);
    if (diagnostics.size() > KADATH_LUAU_MAX_ANALYSIS_DIAGNOSTIC_COUNT)
    {
        diagnostics.resize(KADATH_LUAU_MAX_ANALYSIS_DIAGNOSTIC_COUNT - 1);
        diagnostics.push_back(make_diagnostic(
            KADATH_LUAU_DIAGNOSTIC_ANALYSIS,
            KADATH_LUAU_DIAGNOSTIC_LIMIT_REACHED,
            "Additional diagnostics were omitted because the diagnostic limit was reached"));
    }

    std::memset(result, 0, sizeof(*result));
    result->state = diagnostics.empty() ? KADATH_LUAU_ANALYSIS_VALID : KADATH_LUAU_ANALYSIS_INVALID;
    result->diagnostic_count = static_cast<uint32_t>(diagnostics.size());
    for (size_t index = 0; index < diagnostics.size(); ++index)
    {
        const PendingDiagnostic& source = diagnostics[index];
        KadathLuauAnalysisDiagnostic& target = result->diagnostics[index];
        target.severity = source.severity;
        target.stage = source.stage;
        target.code = source.code;
        target.message_bytes = static_cast<uint32_t>(source.message.size());
        target.range.has_range = source.has_range ? 1 : 0;
        if (source.has_range)
        {
            target.range.start = source.start;
            target.range.end = source.end;
        }
        std::memcpy(target.message, source.message.data(), source.message.size());
        target.message[source.message.size()] = '\0';
    }
    return true;
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
    {
        budget->memory_limit_exceeded = true;
        return nullptr;
    }
    void* replacement = std::realloc(pointer, new_size);
    if (replacement == nullptr)
    {
        budget->memory_limit_exceeded = true;
        return nullptr;
    }
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
    {
        budget->execution_budget_exceeded = true;
        luaL_error(state, "behavior tooling execution budget exceeded");
    }
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

static ToolingContext* context_from_upvalue(lua_State* state)
{
    return static_cast<ToolingContext*>(lua_touserdata(state, lua_upvalueindex(1)));
}

static int parameter_number(lua_State* state)
{
    auto* context = context_from_upvalue(state);
    size_t name_length = 0;
    const char* name = lua_tolstring(state, 1, &name_length);
    if (context == nullptr)
    {
        luaL_error(state, "behavior tooling context is unavailable");
        return 0;
    }
    context->failure = ToolingFailureKind::invalid_parameter;
    if (!valid_name(name, name_length))
    {
        luaL_error(state, "invalid behavior parameter name");
        return 0;
    }
    if (!lua_istable(state, 2))
    {
        luaL_error(state, "behavior parameter options must be a table");
        return 0;
    }
    if (context->result->parameter_count >= KADATH_LUAU_MAX_PARAMETER_COUNT)
    {
        luaL_error(state, "behavior parameter count exceeded");
        return 0;
    }
    lua_getfield(state, 2, "default");
    lua_getfield(state, 2, "min");
    lua_getfield(state, 2, "max");
    if (!lua_isnumber(state, -3) || !lua_isnumber(state, -2) || !lua_isnumber(state, -1))
    {
        luaL_error(state, "behavior number parameter requires default, min and max");
        return 0;
    }
    const double default_value = lua_tonumber(state, -3);
    const double minimum = lua_tonumber(state, -2);
    const double maximum = lua_tonumber(state, -1);
    lua_pop(state, 3);
    if (!std::isfinite(default_value) || !std::isfinite(minimum) || !std::isfinite(maximum) ||
        minimum > maximum || default_value < minimum || default_value > maximum)
    {
        luaL_error(state, "behavior number parameter range is invalid");
        return 0;
    }
    for (size_t index = 0; index < context->result->parameter_count; ++index)
    {
        if (std::strncmp(context->result->parameters[index].name, name, KADATH_LUAU_MAX_PARAMETER_NAME_BYTES + 1) == 0)
        {
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
    context->failure = ToolingFailureKind::none;
    lua_pushnumber(state, default_value);
    return 1;
}

static int input_move_axis(lua_State* state)
{
    luaL_error(state, "behavior input is unavailable during tooling execution");
    return 0;
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

static bool protected_call(lua_State* state, ToolingExecutionBudget& budget, std::string& message)
{
    budget.interrupt_count = 0;
    const int status = lua_pcall(state, 0, 1, 0);
    if (status == LUA_OK)
        return true;
    const char* failure_message = lua_tostring(state, -1);
    message = failure_message == nullptr ? "behavior tooling execution failed" : failure_message;
    lua_pop(state, 1);
    return false;
}

static bool validate_behavior_table(lua_State* state, int table_index, std::string& message)
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
        if (!allowed || !lua_isfunction(state, -1))
        {
            message = "behavior table contains an invalid hook";
            lua_pop(state, 2);
            return false;
        }
        lua_pop(state, 1);
    }
    return true;
}

static PendingDiagnostic execution_diagnostic(
    const ToolingContext& context,
    const ToolingExecutionBudget& budget,
    std::string message)
{
    if (context.failure == ToolingFailureKind::invalid_parameter)
    {
        return make_diagnostic(
            KADATH_LUAU_DIAGNOSTIC_BEHAVIOR_CONTRACT,
            KADATH_LUAU_DIAGNOSTIC_INVALID_PARAMETER_DECLARATION,
            message.empty() ? "behavior parameter declaration is invalid" : std::move(message));
    }
    if (budget.execution_budget_exceeded)
    {
        return make_diagnostic(
            KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION,
            KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION_BUDGET_EXCEEDED,
            "behavior tooling execution budget exceeded");
    }
    if (budget.memory_limit_exceeded)
    {
        return make_diagnostic(
            KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION,
            KADATH_LUAU_DIAGNOSTIC_TOOLING_MEMORY_LIMIT_EXCEEDED,
            "behavior tooling memory limit exceeded");
    }
    return make_diagnostic(
        KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION,
        KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION_ERROR,
        message.empty() ? "behavior tooling execution failed" : std::move(message));
}

static bool run_pipeline(
    const char* source,
    size_t source_length,
    const std::string& chunk_name,
    PipelineOutput& output,
    char* error_buffer,
    size_t error_buffer_size)
{
    const SourceCoordinates coordinates(source, source_length);
    const void* embedded_nul = std::memchr(source, 0, source_length);
    if (embedded_nul != nullptr)
    {
        const size_t offset = static_cast<const char*>(embedded_nul) - source;
        PendingDiagnostic diagnostic = make_diagnostic(
            KADATH_LUAU_DIAGNOSTIC_ANALYSIS,
            KADATH_LUAU_DIAGNOSTIC_LUAU_ANALYSIS_ERROR,
            "Luau source contains an embedded NUL character");
        if (!coordinates.fromOffset(offset, diagnostic.start) || !coordinates.fromOffset(offset + 1, diagnostic.end))
        {
            write_error(error_buffer, error_buffer_size, "failed to map embedded NUL source position");
            return false;
        }
        diagnostic.has_range = true;
        output.diagnostics.push_back(std::move(diagnostic));
        return true;
    }

    AnalysisFileResolver file_resolver;
    file_resolver.module_name = chunk_name;
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
    const auto event_type = frontend.globals.globalScope->exportedTypeBindings.find("Event");
    if (event_type == frontend.globals.globalScope->exportedTypeBindings.end())
    {
        Luau::freeze(frontend.globals.globalTypes);
        write_error(error_buffer, error_buffer_size, "Kadath behavior Event type is unavailable");
        return false;
    }
    frontend.globals.globalScope->importedTypeBindings["Kadath"]["Event"] = event_type->second;
    Luau::freeze(frontend.globals.globalTypes);

    const Luau::CheckResult analysis = frontend.check(file_resolver.module_name);
    if (!analysis.timeoutHits.empty())
    {
        output.diagnostics.push_back(make_diagnostic(
            KADATH_LUAU_DIAGNOSTIC_ANALYSIS,
            KADATH_LUAU_DIAGNOSTIC_LUAU_ANALYSIS_BUDGET_EXCEEDED,
            "Luau Analysis budget exceeded"));
        return true;
    }
    for (const Luau::TypeError& error : analysis.errors)
    {
        PendingDiagnostic diagnostic = make_diagnostic(
            KADATH_LUAU_DIAGNOSTIC_ANALYSIS,
            KADATH_LUAU_DIAGNOSTIC_LUAU_ANALYSIS_ERROR,
            Luau::toString(error, Luau::TypeErrorToStringOptions{&file_resolver}));
        diagnostic.has_range = coordinates.fromLuau(error.location, diagnostic.start, diagnostic.end);
        output.diagnostics.push_back(std::move(diagnostic));
    }
    if (!output.diagnostics.empty())
        return true;

    lua_CompileOptions options = {};
    options.optimizationLevel = 1;
    options.debugLevel = 1;
    size_t bytecode_size = 0;
    std::unique_ptr<char, BytecodeDeleter> bytecode(luau_compile(source, source_length, &options, &bytecode_size));
    if (bytecode == nullptr || bytecode_size == 0)
    {
        write_error(error_buffer, error_buffer_size, "Luau compiler returned no bytecode");
        return false;
    }
    if (bytecode.get()[0] == 0)
    {
        std::string message(bytecode.get() + 1, bytecode_size - 1);
        output.diagnostics.push_back(make_diagnostic(
            KADATH_LUAU_DIAGNOSTIC_COMPILE,
            KADATH_LUAU_DIAGNOSTIC_LUAU_COMPILE_ERROR,
            message.empty() ? "Luau compiler rejected the source" : std::move(message)));
        return true;
    }

    ToolingExecutionBudget execution_budget;
    std::unique_ptr<lua_State, LuaStateDeleter> state(lua_newstate(limited_alloc, &execution_budget));
    if (state == nullptr)
    {
        output.diagnostics.push_back(make_diagnostic(
            KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION,
            KADATH_LUAU_DIAGNOSTIC_TOOLING_MEMORY_LIMIT_EXCEEDED,
            "Luau tooling VM allocation exceeded the memory limit"));
        return true;
    }
    luaL_openlibs(state.get());
    remove_forbidden_globals(state.get());
    luaL_sandbox(state.get());
    luaL_sandboxthread(state.get());
    lua_callbacks(state.get())->userdata = &execution_budget;
    lua_callbacks(state.get())->interrupt = interrupt_callback;
    ToolingContext context;
    context.result = &output.compiled;
    lua_createtable(state.get(), 0, 2);
    lua_createtable(state.get(), 0, 1);
    lua_pushlightuserdata(state.get(), &context);
    lua_pushcclosure(state.get(), parameter_number, "number", 1);
    lua_setfield(state.get(), -2, "number");
    lua_setfield(state.get(), -2, "parameter");
    lua_createtable(state.get(), 0, 1);
    lua_pushcfunction(state.get(), input_move_axis, "move_axis");
    lua_setfield(state.get(), -2, "move_axis");
    lua_setreadonly(state.get(), -1, true);
    lua_setfield(state.get(), -2, "input");
    lua_setreadonly(state.get(), -1, true);
    lua_setglobal(state.get(), "kadath");

    if (luau_load(state.get(), chunk_name.c_str(), bytecode.get(), bytecode_size, 0) != 0)
    {
        const char* failure_message = lua_tostring(state.get(), -1);
        std::string message = failure_message == nullptr ? "Luau tooling failed to load bytecode" : failure_message;
        lua_pop(state.get(), 1);
        output.diagnostics.push_back(execution_diagnostic(context, execution_budget, std::move(message)));
        return true;
    }

    std::string execution_message;
    if (!protected_call(state.get(), execution_budget, execution_message))
    {
        output.diagnostics.push_back(execution_diagnostic(context, execution_budget, std::move(execution_message)));
        return true;
    }
    if (!lua_istable(state.get(), -1))
    {
        output.diagnostics.push_back(make_diagnostic(
            KADATH_LUAU_DIAGNOSTIC_BEHAVIOR_CONTRACT,
            KADATH_LUAU_DIAGNOSTIC_INVALID_BEHAVIOR_TABLE,
            "behavior chunk must return a table"));
        lua_pop(state.get(), 1);
        return true;
    }
    std::string behavior_message;
    if (!validate_behavior_table(state.get(), -1, behavior_message))
    {
        output.diagnostics.push_back(make_diagnostic(
            KADATH_LUAU_DIAGNOSTIC_BEHAVIOR_CONTRACT,
            KADATH_LUAU_DIAGNOSTIC_INVALID_BEHAVIOR_TABLE,
            std::move(behavior_message)));
        lua_pop(state.get(), 1);
        return true;
    }
    lua_pop(state.get(), 1);
    output.compiled.bytecode = reinterpret_cast<uint8_t*>(bytecode.release());
    output.compiled.bytecode_size = bytecode_size;
    return true;
}

static bool validate_input(
    const char* source,
    size_t source_length,
    const char* chunk_name,
    std::string& normalized_chunk_name,
    char* error_buffer,
    size_t error_buffer_size)
{
    if (source == nullptr && source_length != 0)
    {
        write_error(error_buffer, error_buffer_size, "invalid Luau source input");
        return false;
    }
    const char* source_bytes = source == nullptr ? "" : source;
    if (!valid_utf8(source_bytes, source_length))
    {
        write_error(error_buffer, error_buffer_size, "Luau source is not strict UTF-8");
        return false;
    }
    if (chunk_name == nullptr)
    {
        normalized_chunk_name = "behavior";
        return true;
    }
    size_t chunk_name_length = 0;
    while (chunk_name_length <= 1024 && chunk_name[chunk_name_length] != '\0')
        chunk_name_length += 1;
    if (chunk_name_length == 0 || chunk_name_length > 1024 || !valid_utf8(chunk_name, chunk_name_length))
    {
        write_error(error_buffer, error_buffer_size, "invalid Luau chunk name");
        return false;
    }
    normalized_chunk_name.assign(chunk_name, chunk_name_length);
    return true;
}

static void write_legacy_diagnostic(
    const KadathLuauAnalysisDiagnostic& diagnostic,
    const std::string& chunk_name,
    char* error_buffer,
    size_t error_buffer_size)
{
    std::string message;
    if (diagnostic.range.has_range != 0)
    {
        message = chunk_name + ":" + std::to_string(diagnostic.range.start.line) + ":" +
            std::to_string(diagnostic.range.start.column) + ": ";
    }
    message.append(diagnostic.message, diagnostic.message_bytes);
    write_error(error_buffer, error_buffer_size, message.c_str());
}

extern "C" int32_t kadath_luau_analyze(
    const char* source,
    size_t source_length,
    const char* chunk_name,
    KadathLuauAnalysisResult* out_result,
    char* error_buffer,
    size_t error_buffer_size)
{
    clear_error(error_buffer, error_buffer_size);
    if (out_result == nullptr)
    {
        write_error(error_buffer, error_buffer_size, "invalid Luau analysis result output");
        return KADATH_ERR_INVALID_ARGUMENT;
    }
    std::memset(out_result, 0, sizeof(*out_result));
    if (error_buffer == nullptr && error_buffer_size != 0)
        return KADATH_ERR_INVALID_ARGUMENT;
    try
    {
        std::string normalized_chunk_name;
        if (!validate_input(source, source_length, chunk_name, normalized_chunk_name, error_buffer, error_buffer_size))
            return KADATH_ERR_INVALID_ARGUMENT;
        PipelineOutput output;
        const char* source_bytes = source == nullptr ? "" : source;
        if (!run_pipeline(source_bytes, source_length, normalized_chunk_name, output, error_buffer, error_buffer_size))
            return KADATH_ERR_INTERNAL;
        if (!finalize_analysis(std::move(output.diagnostics), out_result))
        {
            write_error(error_buffer, error_buffer_size, "Luau analysis produced an invalid diagnostic message");
            std::memset(out_result, 0, sizeof(*out_result));
            return KADATH_ERR_INTERNAL;
        }
        return KADATH_OK;
    }
    catch (const std::bad_alloc& exception)
    {
        write_error(error_buffer, error_buffer_size, exception.what());
        std::memset(out_result, 0, sizeof(*out_result));
        return KADATH_ERR_OUT_OF_MEMORY;
    }
    catch (const std::exception& exception)
    {
        write_error(error_buffer, error_buffer_size, exception.what());
        std::memset(out_result, 0, sizeof(*out_result));
        return KADATH_ERR_INTERNAL;
    }
    catch (...)
    {
        write_error(error_buffer, error_buffer_size, "unknown Luau analysis failure");
        std::memset(out_result, 0, sizeof(*out_result));
        return KADATH_ERR_INTERNAL;
    }
}

extern "C" int kadath_luau_compile(
    const char* source,
    size_t source_length,
    const char* chunk_name,
    KadathLuauCompileResult* result,
    char* error_buffer,
    size_t error_buffer_size)
{
    clear_error(error_buffer, error_buffer_size);
    if (source == nullptr || source_length == 0 || result == nullptr)
    {
        write_error(error_buffer, error_buffer_size, "invalid Luau source input");
        return 0;
    }
    std::memset(result, 0, sizeof(*result));
    try
    {
        std::string normalized_chunk_name;
        if (!validate_input(source, source_length, chunk_name, normalized_chunk_name, error_buffer, error_buffer_size))
            return 0;
        PipelineOutput output;
        if (!run_pipeline(source, source_length, normalized_chunk_name, output, error_buffer, error_buffer_size))
        {
            kadath_luau_compile_result_destroy(&output.compiled);
            return 0;
        }
        KadathLuauAnalysisResult analysis_result{};
        if (!finalize_analysis(std::move(output.diagnostics), &analysis_result))
        {
            write_error(error_buffer, error_buffer_size, "Luau compilation produced an invalid diagnostic message");
            kadath_luau_compile_result_destroy(&output.compiled);
            return 0;
        }
        if (analysis_result.state == KADATH_LUAU_ANALYSIS_INVALID)
        {
            write_legacy_diagnostic(analysis_result.diagnostics[0], normalized_chunk_name, error_buffer, error_buffer_size);
            kadath_luau_compile_result_destroy(&output.compiled);
            return 0;
        }
        if (output.compiled.bytecode == nullptr || output.compiled.bytecode_size == 0)
        {
            write_error(error_buffer, error_buffer_size, "Luau compiler returned no bytecode");
            kadath_luau_compile_result_destroy(&output.compiled);
            return 0;
        }
        *result = output.compiled;
        std::memset(&output.compiled, 0, sizeof(output.compiled));
        return 1;
    }
    catch (const std::exception& exception)
    {
        write_error(error_buffer, error_buffer_size, exception.what());
        std::memset(result, 0, sizeof(*result));
        return 0;
    }
    catch (...)
    {
        write_error(error_buffer, error_buffer_size, "unknown Luau compilation failure");
        std::memset(result, 0, sizeof(*result));
        return 0;
    }
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
