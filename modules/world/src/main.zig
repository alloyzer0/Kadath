const std = @import("std");

const c = @cImport({
    @cInclude("kadath_world.h");
});

pub const EntityId = u64;
pub const invalid_entity: EntityId = 0;
pub const TextureId = u32;
pub const invalid_texture: TextureId = 0;

pub const InputSnapshot = extern struct {
    move_x: i8 = 0,
    move_y: i8 = 0,
};

pub const WorldBounds = extern struct {
    min: [2]f32,
    max: [2]f32,
};

pub const WorldPosition = extern struct {
    value: [2]f32,
};

pub const SpriteSpawnDesc = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    texture_id: TextureId,
    move_speed: f32,
};

pub const RenderSprite = extern struct {
    entity_id: EntityId,
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    texture_id: TextureId,
};

comptime {
    // 这里的断言保护 caller-allocated 提取缓冲区，禁止 Zig/Rust 两侧 POD 静默漂移。
    if (@sizeOf(RenderSprite) != @sizeOf(c.kadath_world_render_sprite_t) or
        @alignOf(RenderSprite) != @alignOf(c.kadath_world_render_sprite_t))
    {
        @compileError("World render sprite ABI layout changed");
    }
}

pub const World = struct {
    handle: c.kadath_world_t,

    pub fn init() !World {
        var handle: c.kadath_world_t = null;
        try check(c.kadath_world_create(&handle));
        if (handle == null) return error.WorldCreationFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *World) void {
        if (self.handle == null) return;
        check(c.kadath_world_destroy(self.handle)) catch |err| {
            std.log.err("World destroy failed: {s}", .{@errorName(err)});
        };
        self.handle = null;
    }

    pub fn spawnSprite(self: *World, desc: SpriteSpawnDesc) !EntityId {
        var c_desc = std.mem.zeroes(c.kadath_world_sprite_spawn_desc_t);
        c_desc.position = desc.position;
        c_desc.size = desc.size;
        c_desc.color = desc.color;
        c_desc.texture_id = desc.texture_id;
        c_desc.move_speed = desc.move_speed;
        var entity: c.kadath_entity_id_t = c.KADATH_ENTITY_INVALID;
        try check(c.kadath_world_spawn_sprite(self.handle, &c_desc, &entity));
        return entity;
    }

    pub fn setBounds(self: *World, bounds: WorldBounds) !void {
        var c_bounds = c.kadath_world_bounds_t{
            .min = bounds.min,
            .max = bounds.max,
        };
        try check(c.kadath_world_set_bounds(self.handle, &c_bounds));
    }

    pub fn setSpritePosition(self: *World, entity: EntityId, position: [2]f32) !void {
        var c_position = c.kadath_world_position_t{ .value = position };
        try check(c.kadath_world_set_sprite_position(self.handle, entity, &c_position));
    }

    pub fn stepFixed(self: *World, dt_seconds: f32, input: InputSnapshot) !void {
        var c_input = c.kadath_world_input_snapshot_t{
            .move_x = input.move_x,
            .move_y = input.move_y,
        };
        try check(c.kadath_world_step_fixed(self.handle, dt_seconds, &c_input));
    }
    pub fn despawn(self: *World, entity: EntityId) !void {
        try check(c.kadath_world_despawn(self.handle, entity));
    }

    pub fn extractSprites(self: *const World, output: []RenderSprite) ![]RenderSprite {
        var count: usize = 0;
        // RenderSprite 的 comptime 布局断言允许 caller 缓冲区在此安全跨越 C ABI。
        const output_ptr: [*c]c.kadath_world_render_sprite_t = @ptrCast(output.ptr);
        try check(c.kadath_world_extract_sprites(self.handle, output_ptr, output.len, &count));
        if (count > output.len) return error.WorldInvalidOutputCount;
        return output[0..count];
    }
};

fn check(result: i32) !void {
    return switch (result) {
        c.KADATH_OK => {},
        c.KADATH_ERR_INVALID_ARGUMENT => error.InvalidWorldArgument,
        c.KADATH_ERR_OUT_OF_MEMORY => error.OutOfMemory,
        c.KADATH_ERR_BUFFER_TOO_SMALL => error.WorldRenderBufferTooSmall,
        c.KADATH_ERR_WORLD_INVALID_ENTITY => error.InvalidEntity,
        c.KADATH_ERR_INTERNAL => error.WorldInternalFailure,
        else => error.WorldCallFailed,
    };
}
