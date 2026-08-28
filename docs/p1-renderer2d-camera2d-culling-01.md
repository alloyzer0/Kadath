# P1 Renderer2D Camera2D / Culling 01 实现记录

## 状态

`IMPLEMENTED / WINDOWS_PASS / LINUX_PASS / NOT_PUSHED / NOT_MERGED`

本增量以 Inner `303d56d` 为固定点，在 `codex/p1-renderer2d-camera2d-culling-01` 中完成静态 Camera2D、Renderer2D 裁剪、Editor 创作链和双平台产品验证。首版没有 Camera follow、输入平移、旋转、多相机或 GPU culling。

## 已交付契约

- Scene v9 顶层必填 `camera`，原点表示视口左上角世界坐标，zoom 范围为 `0.125..8`；Scene v4—v8 读取为恒等 Camera。
- KSCN v9 在 v8 Tilemap 尾部追加 `origin f32[2] + zoom f32`；v4—v8 artifact 保持兼容。
- `Frame2D.view` 是 Renderer2D 唯一 Camera seam；世界到屏幕的变换、可见世界矩形、Tilemap 行列范围和 Sprite AABB 裁剪均隐藏在 Renderer2D。
- 可见 Tile 保持全图 row-major；可见 Sprite 保持 source order；不可见 Sprite 不形成 Texture run。
- Host 直接借用活动 Scene Camera，不保存第二份状态。Runtime Core 与公共 C ABI 未修改；RHI 只增加通用 opaque TextureHandle 生命周期预检，不含 Camera/世界矩形类型。
- Protocol/Workspace 使用 `ProjectModelScene.Camera` 与 nullable `AuthoringPatch.SceneCamera`；v8 恒等补丁为 no-op，非恒等补丁升级 v9，Undo/Redo 字节精确。
- Avalonia 提供独立 Camera2D 面板、Origin X/Y、Zoom 和恒等重置；非法草稿关闭 Apply。

## 产品夹具

默认产品 Scene 已升级 v9：Camera 为 `[1,0] / 1`，Tilemap 为 12×6、世界范围在横纵两轴均超过 960×540 可见区。Runtime Object 与 Tilemap 均保留原世界坐标；双平台在 `x=149` 增加 Camera 专用边界像素，忽略 Camera 的旧 Renderer 会读到透明 Tile1 而不是预期 Tile2，因此无法伪通过。Gameplay/collision authority 不受展示 Camera 影响。

## 验证证据

- Scene：24/24 测试通过，覆盖 v9 source/KSCN 往返、非法值、截断与 v8 identity 兼容。
- Renderer2D Null：20/20 测试通过，输出 `CAMERA_IDENTITY_COMPATIBLE`、`CAMERA_TILEMAP_CULLING`、`CAMERA_SPRITE_CULLING`。
- Zig：全部 10 个公开测试步骤通过，包括 Runtime Core/public C、SceneGeneration、Behavior、Audio、Replay 与 Resource。
- Editor：Debug/Release 全解决方案均为 0 警告；Workspace、Service、Client 三组 ContractVerifier 通过。
- Avalonia owned workflow：Camera Apply/Undo、Both Bake、Watch、Preview reload、Shutdown 与 File-ID cleanup 全部通过。
- Windows：真实 HWND/Vulkan 产品验证 PASS，输出 `CAMERA_PIXEL_ORACLE=true`。
- Linux：clean-extract + XCB/Lavapipe/Validation 产品验证 PASS，窗口证据输出 `CAMERA_PIXEL_ORACLE=true`。
- 边界检查：`runtime_core_diff_count=0`；RHI 两个 Adapter 仅增加同名 TextureHandle 预检，Camera 领域词匹配为 0。

Windows 成功证据目录：

`F:\Workspace\kadath-worktrees\inner-p1-renderer2d-camera2d-culling-01\.zig-cache\camera-windows-evidence-89ba6461f218434780c59d6fae57d899`

Linux 成功证据目录：

`/mnt/f/Workspace/kadath-worktrees/inner-p1-renderer2d-camera2d-culling-01/.zig-cache/linux-package-evidence/Debug-1464-1787882157`

## 机器字段

```text
CAMERA_SOURCE_V9=true
CAMERA_KSCN_V9=true
CAMERA_EDITOR_APPLY_UNDO_REDO=true
CAMERA_IDENTITY_COMPATIBLE=true
CAMERA_TILEMAP_CULLING=true
CAMERA_SPRITE_CULLING=true
CAMERA_PIXEL_ORACLE=true
RHI_CAMERA_DOMAIN_TYPES=0
RUNTIME_CORE_CAMERA_CHANGES=0
```

## 实现期修复

真实 Avalonia 工作流曾发现 Editor Service Snapshot 防御门禁仍把 schema 上限冻结在 v8。新增 `camera_snapshot_protocol` 直接回归用例后，统一修正 neutral Gameplay、最小对象数、Behavior 与 Snapshot 版本门禁，并增加 Camera 形状校验；原始端到端反馈环随后通过。

规格复核还发现不可见的已销毁非零 TextureHandle 会绕过绑定期校验。Renderer 不能自行判断 RHI generation，因此 Null/Vulkan 共同增加不暴露内部 slot 的 `validateTextureHandle`；Renderer 在 `beginFrame` 前对全部 Tilemap/Sprite handle 调用它，Camera/RHI 领域边界保持不变。
