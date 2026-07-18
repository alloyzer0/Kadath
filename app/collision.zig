const std = @import("std");

pub const EntityId = u64;

pub const Aabb = struct {
    position: [2]f32,
    size: [2]f32,
};

pub const Body = struct {
    entity_id: EntityId,
    aabb: Aabb,
};

pub const Contact = struct {
    first_entity: EntityId,
    second_entity: EntityId,
};

pub fn queryContact(first: Body, second: Body) ?Contact {
    if (!isValid(first.aabb) or !isValid(second.aabb)) return null;

    const first_right = first.aabb.position[0] + first.aabb.size[0];
    const first_bottom = first.aabb.position[1] + first.aabb.size[1];
    const second_right = second.aabb.position[0] + second.aabb.size[0];
    const second_bottom = second.aabb.position[1] + second.aabb.size[1];

    // 关键边界：严格不等式让仅边缘相接的 AABB 不产生穿透接触。
    if (first.aabb.position[0] < second_right and first_right > second.aabb.position[0] and
        first.aabb.position[1] < second_bottom and first_bottom > second.aabb.position[1])
    {
        return .{
            .first_entity = first.entity_id,
            .second_entity = second.entity_id,
        };
    }
    return null;
}

fn isValid(aabb: Aabb) bool {
    return std.math.isFinite(aabb.position[0]) and std.math.isFinite(aabb.position[1]) and
        std.math.isFinite(aabb.size[0]) and std.math.isFinite(aabb.size[1]) and
        aabb.size[0] >= 0.0 and aabb.size[1] >= 0.0;
}

test "contact query returns entity ids for overlapping bodies" {
    const contact = queryContact(.{
        .entity_id = 7,
        .aabb = .{ .position = .{ 100.0, 100.0 }, .size = .{ 20.0, 20.0 } },
    }, .{
        .entity_id = 9,
        .aabb = .{ .position = .{ 115.0, 105.0 }, .size = .{ 20.0, 20.0 } },
    });
    try std.testing.expect(contact != null);
    try std.testing.expectEqual(@as(EntityId, 7), contact.?.first_entity);
    try std.testing.expectEqual(@as(EntityId, 9), contact.?.second_entity);
}

test "contact query ignores edge touching bodies" {
    const contact = queryContact(.{
        .entity_id = 1,
        .aabb = .{ .position = .{ 100.0, 100.0 }, .size = .{ 20.0, 20.0 } },
    }, .{
        .entity_id = 2,
        .aabb = .{ .position = .{ 120.0, 100.0 }, .size = .{ 20.0, 20.0 } },
    });
    try std.testing.expect(contact == null);
}

test "contact query rejects non-finite and negative geometry" {
    const non_finite = queryContact(.{
        .entity_id = 1,
        .aabb = .{ .position = .{ std.math.nan(f32), 0.0 }, .size = .{ 20.0, 20.0 } },
    }, .{
        .entity_id = 2,
        .aabb = .{ .position = .{ 0.0, 0.0 }, .size = .{ 20.0, 20.0 } },
    });
    try std.testing.expect(non_finite == null);

    const negative_size = queryContact(.{
        .entity_id = 1,
        .aabb = .{ .position = .{ 0.0, 0.0 }, .size = .{ -1.0, 20.0 } },
    }, .{
        .entity_id = 2,
        .aabb = .{ .position = .{ 0.0, 0.0 }, .size = .{ 20.0, 20.0 } },
    });
    try std.testing.expect(negative_size == null);
}
