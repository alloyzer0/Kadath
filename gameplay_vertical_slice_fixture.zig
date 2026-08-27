// 测试与证据 runner 共用同一组 authored 输入，避免内联副本与已哈希 fixture 漂移。
pub const manifest = @embedFile("tools/fixtures/gameplay-vertical-slice-02/script.json");
pub const player_source = @embedFile("tools/fixtures/gameplay-vertical-slice-02/scripts/vertical-player.luau");
pub const no_op_source = @embedFile("tools/fixtures/gameplay-vertical-slice-02/scripts/no-op.luau");
pub const initial_scene = @embedFile("tools/fixtures/gameplay-vertical-slice-02/initial.scene.json");
pub const reload_scene = @embedFile("tools/fixtures/gameplay-vertical-slice-02/reload.scene.json");
