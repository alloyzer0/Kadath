const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const ContentKind = enum {
    source_document,
    artifact,

    pub fn protocolName(self: ContentKind) []const u8 {
        return switch (self) {
            .source_document => "source_document",
            .artifact => "artifact",
        };
    }
};

pub const ContentIdentity = struct {
    kind: ContentKind,
    sha256: [Sha256.digest_length]u8,
    byte_count: u64,

    pub fn fromBytes(kind: ContentKind, bytes: []const u8) !ContentIdentity {
        const byte_count = std.math.cast(u64, bytes.len) orelse return error.ContentByteCountOverflow;
        var digest: [Sha256.digest_length]u8 = undefined;
        // 身份必须来自解析器消费的同一份 buffer；禁止在调用方二次读取文件后补算哈希。
        Sha256.hash(bytes, &digest, .{});
        return .{ .kind = kind, .sha256 = digest, .byte_count = byte_count };
    }

    pub fn writeHexLower(self: ContentIdentity, output: *[Sha256.digest_length * 2]u8) []const u8 {
        return std.fmt.bufPrint(output, "{x}", .{&self.sha256}) catch unreachable;
    }
};

test "content identity uses fixed-width lowercase sha256 and u64 bytes" {
    const identity = try ContentIdentity.fromBytes(.source_document, "abc");
    var hex: [Sha256.digest_length * 2]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        identity.writeHexLower(&hex),
    );
    try std.testing.expectEqual(@as(u64, 3), identity.byte_count);
    try std.testing.expectEqualStrings("source_document", identity.kind.protocolName());
}
