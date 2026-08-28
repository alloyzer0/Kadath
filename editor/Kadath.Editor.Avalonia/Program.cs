using System.Globalization;
using System.Text.Json;
using System.Threading.Channels;
using Avalonia;
using Kadath.Editor.Avalonia.Client;
using Kadath.Editor.Avalonia.ViewModels;
using Kadath.Editor.Avalonia.Views;
using Kadath.Editor.Client;
using Kadath.Editor.Protocol;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Avalonia;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        if (args.Contains("--headless-smoke", StringComparer.Ordinal))
        {
            HeadlessSmokeAsync().GetAwaiter().GetResult();
            return;
        }
        if (args.Length >= 5 && string.Equals(args[0], "--workflow-smoke", StringComparison.Ordinal))
        {
            WorkflowSmokeAsync(args[1], args[2], args[3], args[4]).GetAwaiter().GetResult();
            return;
        }
        if (args.Length == 3 && string.Equals(args[0], "--workflow-smoke-owned", StringComparison.Ordinal))
        {
            AvaloniaWorkflowFixture.VerifyCleanupOwnershipContract(args[1], args[2]);
            Console.WriteLine("workflow_fixture_ownership=ok");
            using (var fixture = AvaloniaWorkflowFixture.Create(args[1], args[2]))
            {
                WorkflowSmokeAsync(
                    fixture.KadathRoot,
                    fixture.PackageRoot,
                    fixture.OpenProjectName,
                    fixture.CreatedProjectName,
                    fixture).GetAwaiter().GetResult();
            }
            Console.WriteLine("workflow_fixture_cleanup=ok");
            return;
        }


        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .LogToTrace();
    private static async Task WorkflowSmokeAsync(
        string kadathRootArgument,
        string packageRootArgument,
        string openProjectName,
        string createdProjectName,
        AvaloniaWorkflowFixture? ownershipFixture = null)
    {
        var kadathRoot = Path.GetFullPath(kadathRootArgument);
        var packageRoot = Path.GetFullPath(packageRootArgument);
        var editorRoot = Path.Combine(kadathRoot, "editor");
#if DEBUG
        const string serviceConfiguration = "Debug";
#else
        const string serviceConfiguration = "Release";
#endif
        var serviceDll = Path.Combine(editorRoot, "Kadath.Editor.Service", "bin", serviceConfiguration, "net8.0", "Kadath.Editor.Service.dll");
        if (!File.Exists(serviceDll)) { throw new FileNotFoundException("Editor Service 尚未构建。", serviceDll); }

        var transport = new StdioEditorRpcTransport(new EditorRpcProcessOptions(
            "dotnet",
            [serviceDll],
            kadathRoot));
        await using var client = new EditorRpcClient(transport, "kadath-editor-avalonia-workflow", "1");
        await using var workspace = new EditorWorkspaceViewModel(client, new InlineEditorViewDispatcher());
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        var cancellationToken = timeout.Token;

        await workspace.ConnectAsync(cancellationToken);
        Require(workspace.ConnectionState == EditorConnectionState.Ready, "workspace did not reach Ready");
        Console.WriteLine("workflow_connect=ok");

        var opened = await workspace.OpenProjectAsync(new ProjectOpenParameters(packageRoot, openProjectName), cancellationToken);
        Require(opened.ProjectName == openProjectName && workspace.Project.Session is not null, "project_open state mismatch");
        var avaloniaViewModel = new AvaloniaEditorViewModel(workspace, new InlineEditorViewDispatcher(), packageRoot);
        avaloniaViewModel.ProjectName = openProjectName;
        await avaloniaViewModel.RefreshSnapshotsForCurrentProjectAsync(cancellationToken);
        var expectedAssetCount = Directory.EnumerateFiles(Path.Combine(packageRoot, "bin", "assets"), "*", SearchOption.AllDirectories).Count();
        var openedHierarchy = workspace.HierarchySnapshot.Value ?? throw new InvalidOperationException("Opened hierarchy snapshot is missing.");
        var expectedOpenedHierarchyCount = openedHierarchy.ProjectModelVersion == EditorSnapshotVersions.ProjectModel
            && workspace.ProjectSnapshot.Value?.Scene.SchemaVersion is 5 or 6 or 7 or 8 or 9
            ? openedHierarchy.Nodes.Length
            : 13;
        Require(avaloniaViewModel.HierarchyItems.Count == expectedOpenedHierarchyCount
            && expectedAssetCount > 0
            && avaloniaViewModel.AssetItems.Count == expectedAssetCount,
            "Avalonia should project every asset from the current product package.");
        Require(avaloniaViewModel.SceneTextureAssignments.Count == 4
            && avaloniaViewModel.SceneTextureAssignments[0].TextureIdText == "1"
            && !string.IsNullOrWhiteSpace(avaloniaViewModel.SceneTextureAssignments[0].SelectedAssetItem),
            "Avalonia did not project the current Scene texture set into the authoring slots");
        Require(avaloniaViewModel.SceneObjectDrafts.Count == 5
            && avaloniaViewModel.SelectedSceneObject?.ObjectId == "goal"
            && avaloniaViewModel.InspectorText.Contains("scene.objects[goal]", StringComparison.Ordinal),
            "Avalonia hierarchy selection did not project the typed Scene Object inspector");
        Console.WriteLine("workflow_snapshot_projection=ok");
        Console.WriteLine("workflow_project_open=ok");

        var openedProject = workspace.ProjectSnapshot.Value ?? throw new InvalidOperationException("Opened project snapshot is missing.");
        if (openedProject.Scene.SchemaVersion is 7 or 8 or 9)
        {
            Require(avaloniaViewModel.SupportsSceneTilemapAuthoring,
                "Avalonia did not expose Tilemap authoring for Scene v7-v9");
            if (avaloniaViewModel.SceneTilemapDraft is null) avaloniaViewModel.AddSceneTilemapDraft();
            var tilemapDraft = avaloniaViewModel.SceneTilemapDraft
                ?? throw new InvalidOperationException("Avalonia did not create a Tilemap draft");
            // 同一事务同时切换 Atlas Texture/profile，覆盖 Workspace 的跨字段 candidate 校验。
            var atlasTextureSlot = avaloniaViewModel.SceneTextureAssignments[1];
            atlasTextureSlot.SamplingProfile = "pixel_art";
            tilemapDraft.TextureIdText = atlasTextureSlot.TextureIdText;
            tilemapDraft.Columns = "2";
            tilemapDraft.Rows = "2";
            tilemapDraft.AtlasColumns = "4";
            tilemapDraft.AtlasRows = "4";
            tilemapDraft.ResizeCells();
            Require(tilemapDraft.GridColumns == 2 && tilemapDraft.Cells.Count == 4,
                "Avalonia Tilemap grid did not preserve the authored row/column shape");
            foreach (var cell in tilemapDraft.Cells) cell.Value = 0;
            tilemapDraft.SelectedTileIndex = "6";
            tilemapDraft.PaintCell(2);
            var tilemapEdited = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
            Require(tilemapEdited.ChangedFields.SequenceEqual(["scene.textures", "scene.tilemaps"])
                && tilemapEdited.ProjectSnapshot.Scene.SchemaVersion == Math.Max(8, openedProject.Scene.SchemaVersion)
                && tilemapEdited.ProjectSnapshot.Scene.Tilemaps is [{ TilemapId: "background" }]
                && tilemapEdited.ProjectSnapshot.Scene.Tilemaps[0].Cells.SequenceEqual([0, 0, 6, 0]),
                "Avalonia did not commit the Tilemap draft through the existing authoring seam");
            var tilemapRestored = await avaloniaViewModel.UndoAuthoringForCurrentProjectAsync(cancellationToken);
            Require(tilemapRestored.ProjectSnapshot.Scene.SchemaVersion == openedProject.Scene.SchemaVersion,
                "Avalonia Tilemap Undo did not restore the original Scene schema");
            openedProject = workspace.ProjectSnapshot.Value ?? throw new InvalidOperationException("Tilemap Undo snapshot is missing.");
            Console.WriteLine("workflow_tilemap_authoring=ok");
        }
        if (openedProject.Scene.SchemaVersion is 8 or 9)
        {
            var originalCamera = openedProject.Scene.Camera ?? new ProjectModelSceneCamera([0, 0], 1);
            Require(avaloniaViewModel.SupportsSceneCameraAuthoring
                && double.Parse(avaloniaViewModel.SceneCameraDraft.OriginX, CultureInfo.InvariantCulture) == originalCamera.Origin[0]
                && double.Parse(avaloniaViewModel.SceneCameraDraft.OriginY, CultureInfo.InvariantCulture) == originalCamera.Origin[1]
                && double.Parse(avaloniaViewModel.SceneCameraDraft.Zoom, CultureInfo.InvariantCulture) == originalCamera.Zoom,
                "Avalonia did not project the Camera2D draft");
            avaloniaViewModel.SceneCameraDraft.OriginX = "240";
            avaloniaViewModel.SceneCameraDraft.OriginY = "140";
            avaloniaViewModel.SceneCameraDraft.Zoom = "2";
            var cameraEdited = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
            Require(cameraEdited.ChangedFields.SequenceEqual(["scene.camera"])
                && cameraEdited.ProjectSnapshot.Scene.SchemaVersion == 9
                && cameraEdited.ProjectSnapshot.Scene.Camera is { Origin: [240, 140], Zoom: 2 },
                "Avalonia did not commit Camera2D through the complete authoring patch seam");
            var cameraRestored = await avaloniaViewModel.UndoAuthoringForCurrentProjectAsync(cancellationToken);
            Require(cameraRestored.ProjectSnapshot.Scene.SchemaVersion == openedProject.Scene.SchemaVersion
                && double.Parse(avaloniaViewModel.SceneCameraDraft.OriginX, CultureInfo.InvariantCulture) == originalCamera.Origin[0]
                && double.Parse(avaloniaViewModel.SceneCameraDraft.OriginY, CultureInfo.InvariantCulture) == originalCamera.Origin[1]
                && double.Parse(avaloniaViewModel.SceneCameraDraft.Zoom, CultureInfo.InvariantCulture) == originalCamera.Zoom,
                "Avalonia Camera2D Undo did not restore the projected draft");
            openedProject = workspace.ProjectSnapshot.Value ?? throw new InvalidOperationException("Camera Undo snapshot is missing.");
            Console.WriteLine("workflow_camera_authoring=ok");
        }
        if (openedProject.Scene.SchemaVersion is 5 or 6 or 7 or 8 or 9)
        {
            var expectedBehaviors = CaptureBehaviorSignatures(openedProject);
            var hazardDraft = avaloniaViewModel.SceneObjectDrafts.First(draft => draft.Kind == "patrol_hazard");
            var originalHazardX = hazardDraft.PositionX;
            hazardDraft.PositionX = (double.Parse(hazardDraft.PositionX, CultureInfo.InvariantCulture) + 7d).ToString("R", CultureInfo.InvariantCulture);

            var preserved = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
            Require(preserved.ProjectSnapshot.Scene.SchemaVersion == openedProject.Scene.SchemaVersion
                && preserved.ProjectSnapshot.Scene.Objects?.Single(item => item.ObjectId == hazardDraft.ObjectId).Position[0]
                    == double.Parse(hazardDraft.PositionX, CultureInfo.InvariantCulture),
                "Avalonia did not commit the non-behavior Scene v5 object edit");
            RequireBehaviorSignatures(preserved.ProjectSnapshot, expectedBehaviors, "authoring apply");

            await avaloniaViewModel.RefreshSnapshotsForCurrentProjectAsync(cancellationToken);
            RequireBehaviorSignatures(
                workspace.ProjectSnapshot.Value ?? throw new InvalidOperationException("Refreshed project snapshot is missing."),
                expectedBehaviors,
                "snapshot refresh");

            var restored = await avaloniaViewModel.UndoAuthoringForCurrentProjectAsync(cancellationToken);
            Require(avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.ObjectId == hazardDraft.ObjectId).PositionX == originalHazardX,
                "Avalonia did not restore the Scene v5 object edit");
            RequireBehaviorSignatures(restored.ProjectSnapshot, expectedBehaviors, "authoring undo");

            Require(avaloniaViewModel.IsBehaviorContractReady
                && avaloniaViewModel.AvailableBehaviorContracts.Count == 2,
                "Avalonia did not project the Behavior Contract catalog");
            if (openedProject.Scene.SchemaVersion is 6 or 7 or 8 or 9)
            {
                Require(avaloniaViewModel.ScenePrototypeDrafts is [{ PrototypeId: "runtime-orb" }]
                    && !workspace.HierarchySnapshot.Value!.Nodes.Any(node =>
                        node.Id.Contains("prototype", StringComparison.OrdinalIgnoreCase)
                        || node.Kind.Contains("prototype", StringComparison.OrdinalIgnoreCase)),
                    "Avalonia did not keep the Spawn Prototype projection outside Scene Hierarchy");
                var prototypeDraft = avaloniaViewModel.ScenePrototypeDrafts[0];
                avaloniaViewModel.SelectedScenePrototype = prototypeDraft;
                var prototypeBinding = prototypeDraft.Behaviors.Single(binding => binding.ScriptId == 2);
                avaloniaViewModel.SelectedBehaviorBinding = prototypeBinding;
                var prototypeSpeed = prototypeBinding.Parameters.Single(parameter => parameter.Name == "speed");
                prototypeSpeed.ValueText = "1001";
                Require(!avaloniaViewModel.CanApplyAuthoring,
                    "Avalonia enabled Apply for an out-of-range Prototype behavior override");
                prototypeSpeed.ValueText = "200";
                avaloniaViewModel.SelectedBehaviorContract = avaloniaViewModel.AvailableBehaviorContracts.Single(
                    entry => entry.ScriptId == 1 && entry.SourcePath == "scripts/patrol.luau");
                Require(avaloniaViewModel.CanAddBehaviorBinding,
                    "Avalonia did not route shared Behavior commands to the selected Spawn Prototype");
                avaloniaViewModel.AddBehaviorBinding();
                var prototypeEdited = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
                Require(prototypeEdited.ChangedFields.SequenceEqual(["scene.prototypes"])
                    && prototypeEdited.ProjectSnapshot.Scene.Prototypes![0].Behaviors is { Count: 2 }
                    && prototypeEdited.ProjectSnapshot.Scene.Prototypes[0].Behaviors!
                        .Single(binding => binding.ScriptId == 2).Parameters!
                        .Single(parameter => parameter.Name == "speed").Value == 200,
                    "Avalonia did not commit Spawn Prototype Behavior authoring through the existing mutation seam");
                var prototypeBake = await workspace.BakeAsync(new BakeStartParameters("Both", "debug"), cancellationToken);
                Require(prototypeBake.SceneArtifactRevision is { Length: 64 }
                    && prototypeBake.SceneArtifactBytes is > 0,
                    "Authored Spawn Prototype did not reach the KSCN Bake product seam");
                _ = await workspace.StartPreviewAsync(
                    new PreviewStartParameters(ProjectName: openProjectName, LiveBake: true),
                    cancellationToken);
                await WaitUntilAsync(
                    () => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Loaded,
                    cancellationToken,
                    "authored Spawn Prototype Runtime load",
                    () => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Failed
                        || workspace.Preview.State is EditorPreviewState.Failed or EditorPreviewState.Stopped,
                    () => $"preview={workspace.Preview.State}; runtime={workspace.Preview.Runtime.State}; error={workspace.Preview.Runtime.ErrorCode}:{workspace.Preview.Runtime.ErrorMessage}");
                Require(workspace.Preview.Runtime.Scene.ArtifactRevision == prototypeBake.SceneArtifactRevision,
                    "Runtime did not load the KSCN artifact produced from the authored Spawn Prototype");
                await Task.Delay(250, cancellationToken);
                Require(workspace.Preview.State == EditorPreviewState.Running,
                    "Runtime did not remain active for the authored Spawn Prototype workload");
                _ = await workspace.StopPreviewAsync(cancellationToken);
                var prototypeRestored = await avaloniaViewModel.UndoAuthoringForCurrentProjectAsync(cancellationToken);
                Require(prototypeRestored.ProjectSnapshot.Scene.Prototypes![0].Behaviors is [{ ScriptId: 2 }]
                    && prototypeRestored.ProjectSnapshot.Scene.Prototypes[0].Behaviors![0].Parameters!
                        .Single(parameter => parameter.Name == "speed").Value == 180,
                    "Avalonia Undo did not restore the original Spawn Prototype binding collection");
                Console.WriteLine("workflow_spawn_prototype_authoring=ok");
            }
            var bindingGoalDraft = avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.Kind == "goal");
            Require(bindingGoalDraft.Behaviors is [{ ScriptId: 2 }],
                "Avalonia did not project the existing goal update binding");
            avaloniaViewModel.SelectedSceneObject = bindingGoalDraft;
            avaloniaViewModel.SelectedBehaviorContract = avaloniaViewModel.AvailableBehaviorContracts.Single(
                entry => entry.ScriptId == 1 && entry.SourcePath == "scripts/patrol.luau");
            Require(avaloniaViewModel.CanAddBehaviorBinding, "Avalonia did not enable a valid behavior binding candidate");
            avaloniaViewModel.AddBehaviorBinding();
            var bindingDraft = avaloniaViewModel.SelectedBehaviorBinding
                ?? throw new InvalidOperationException("Avalonia did not select the added behavior binding");
            Require(bindingDraft.Parameters.All(parameter => parameter.ValueText.Length == 0)
                && bindingDraft.CreateDefinition().Parameters?.Count == 0,
                "Avalonia persisted a schema default as an explicit override");
            Require(avaloniaViewModel.CanRemoveBehaviorBinding, "Avalonia did not allow removing an optional goal binding");
            avaloniaViewModel.RemoveBehaviorBinding();
            Require(bindingGoalDraft.Behaviors is [{ ScriptId: 2 }],
                "Avalonia did not remove only the optional goal Patrol binding draft");
            avaloniaViewModel.AddBehaviorBinding();
            bindingDraft = avaloniaViewModel.SelectedBehaviorBinding!;
            var speedParameter = bindingDraft.Parameters.Single(parameter => parameter.Name == "speed");
            speedParameter.ValueText = "1001";
            Require(!avaloniaViewModel.CanApplyAuthoring, "Avalonia enabled Apply for an out-of-range behavior override");
            speedParameter.ValueText = "120";
            var bound = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
            var boundGoal = bound.ProjectSnapshot.Scene.Objects!.Single(item => item.ObjectId == bindingGoalDraft.ObjectId);
            Require(boundGoal.Behaviors is { Count: 2 }
                && boundGoal.Behaviors.Single(value => value.ScriptId == 1).Parameters?.Single() is { Name: "speed", Value: 120 }
                && boundGoal.Behaviors.Any(value => value.ScriptId == 2),
                "Avalonia did not commit the behavior binding parameter override");
            var unbound = await avaloniaViewModel.UndoAuthoringForCurrentProjectAsync(cancellationToken);
            Require(unbound.ProjectSnapshot.Scene.Objects!.Single(item => item.ObjectId == bindingGoalDraft.ObjectId).Behaviors is [{ ScriptId: 2 }],
                "Avalonia Undo did not restore the previous behavior binding collection");
        }
        Console.WriteLine("workflow_behavior_preservation=ok");
        Console.WriteLine("workflow_behavior_binding_authoring=ok");

        Require(openedProject.Script.SchemaVersion == 2, "Avalonia script source workflow requires a Script v2 project");
        var scriptDependency = openedProject.Script.Dependencies?.SingleOrDefault(
            dependency => dependency.ScriptId == 2 && dependency.Source == "scripts/player_controller.luau")
            ?? throw new InvalidOperationException("Opened Script v2 project does not expose the Player controller dependency.");
        var scriptHierarchyLabel = avaloniaViewModel.HierarchyItems.Single(label =>
            label.Contains($"script.dependencies[{scriptDependency.ScriptId}]", StringComparison.Ordinal));
        avaloniaViewModel.SelectedHierarchyItem = scriptHierarchyLabel;
        await WaitUntilAsync(
            () => avaloniaViewModel.HasScriptSourceDocument && avaloniaViewModel.SelectedScriptSourceId == scriptDependency.ScriptId,
            cancellationToken,
            "selected script source document");
        var originalSourceDocument = workspace.ScriptSource.Document
            ?? throw new InvalidOperationException("Selected script source document is missing.");
        Require(originalSourceDocument.Source.Contains("kadath.input.move_axis", StringComparison.Ordinal),
            "Avalonia did not load the Player controller input source.");
        var projectDirectory = Path.GetFullPath(opened.ProjectDirectory);
        var projectPrefix = projectDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var sourcePath = Path.GetFullPath(Path.Combine(projectDirectory, originalSourceDocument.SourcePath));
        var pathComparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        Require(sourcePath.StartsWith(projectPrefix, pathComparison), "Script source workflow path escaped the opened project directory");
        var originalSourceBytes = File.ReadAllBytes(sourcePath);
        var originalSourceText = originalSourceDocument.Source;
        try
        {
            Require(avaloniaViewModel.SupportsScriptSourceAuthoring
                && avaloniaViewModel.HasScriptSourceDocument
                && !avaloniaViewModel.UsesHookScriptAuthoring
                && !avaloniaViewModel.IsScriptSourceDirty,
                "Avalonia did not expose the selected Script v2 source document");

            avaloniaViewModel.ScriptSourceText = originalSourceText + "\n-- Avalonia workflow source save\n";
            var sceneHierarchyLabel = avaloniaViewModel.HierarchyItems.Single(label => label.EndsWith("· scene.objects[goal]", StringComparison.Ordinal));
            avaloniaViewModel.SelectedHierarchyItem = sceneHierarchyLabel;
            Require(avaloniaViewModel.SelectedHierarchyItem == scriptHierarchyLabel,
                "Avalonia allowed switching Hierarchy while script source changes were dirty");
            Require(avaloniaViewModel.IsScriptSourceDirty
                && avaloniaViewModel.CanSaveScriptSource
                && !avaloniaViewModel.CanApplyAuthoring
                && !avaloniaViewModel.CanUndoAuthoring,
                "Unsaved script source did not gate conflicting authoring commands");
            var savedSource = await avaloniaViewModel.SaveScriptSourceForCurrentProjectAsync(cancellationToken);
            Require(string.Equals(savedSource.State, "succeeded", StringComparison.OrdinalIgnoreCase)
                && savedSource.Revision != originalSourceDocument.AuthoringRevision
                && savedSource.SourceDocument.Source == avaloniaViewModel.ScriptSourceText
                && !avaloniaViewModel.IsScriptSourceDirty
                && avaloniaViewModel.CanUndoScriptSource
                && workspace.ScriptSource.UndoDepth == 1
                && avaloniaViewModel.SelectedHierarchyItem == scriptHierarchyLabel,
                "Avalonia script source save did not refresh the document, revision, hierarchy, and undo state");

            var undoneSource = await avaloniaViewModel.UndoScriptSourceForCurrentProjectAsync(cancellationToken);
            Require(string.Equals(undoneSource.Operation, "undo", StringComparison.OrdinalIgnoreCase)
                && undoneSource.SourceDocument.Source == originalSourceText
                && avaloniaViewModel.ScriptSourceText == originalSourceText
                && !avaloniaViewModel.IsScriptSourceDirty
                && !avaloniaViewModel.CanUndoScriptSource
                && workspace.ScriptSource.UndoDepth == 0,
                "Avalonia script source undo did not restore the original source and UI state");

            var retainedBuffer = originalSourceText + "\n-- Avalonia retained conflict buffer\n";
            avaloniaViewModel.ScriptSourceText = retainedBuffer;
            File.AppendAllText(sourcePath, "\n-- external workflow edit\n", new System.Text.UTF8Encoding(false));
            await avaloniaViewModel.RefreshSnapshotsForCurrentProjectAsync(cancellationToken);
            Require(avaloniaViewModel.ScriptSourceText == retainedBuffer
                && avaloniaViewModel.IsScriptSourceDirty
                && avaloniaViewModel.SelectedHierarchyItem == scriptHierarchyLabel
                && avaloniaViewModel.IsScriptSourceSelection
                && workspace.ProjectSnapshot.Value?.AuthoringRevision != originalSourceDocument.AuthoringRevision,
                "Snapshot refresh overwrote the dirty source buffer or hid the external revision");
            try
            {
                _ = await avaloniaViewModel.SaveScriptSourceForCurrentProjectAsync(cancellationToken);
                throw new InvalidOperationException("Stale Avalonia script source save unexpectedly succeeded.");
            }
            catch (EditorRpcException exception) when (exception.Code == "script_source_revision_conflict") { }
            Require(avaloniaViewModel.ScriptSourceText == retainedBuffer
                && avaloniaViewModel.IsScriptSourceDirty
                && workspace.ScriptSource.State == EditorScriptSourceState.Failed
                && workspace.ScriptSource.ErrorCode == "script_source_revision_conflict"
                && workspace.ScriptSource.UndoDepth == 0,
                "Revision conflict did not preserve the Avalonia source buffer and invalidate stale undo state");
        }
        finally
        {
            File.WriteAllBytes(sourcePath, originalSourceBytes);
            if (avaloniaViewModel.IsScriptSourceDirty) { avaloniaViewModel.DiscardScriptSourceChangesCommand.Execute(null); }
            _ = await avaloniaViewModel.LoadScriptSourceForCurrentProjectAsync(scriptDependency.ScriptId, cancellationToken);
        }
        Require(avaloniaViewModel.ScriptSourceText == originalSourceText
            && !avaloniaViewModel.IsScriptSourceDirty
            && workspace.ScriptSource.State == EditorScriptSourceState.Ready,
            "Avalonia script source workflow did not restore its controlled fixture");
        Console.WriteLine("workflow_script_source_authoring=ok");

        await avaloniaViewModel.RefreshSnapshotsForCurrentProjectAsync(cancellationToken);
        var lifecycleOriginalRevision = workspace.ProjectSnapshot.Value?.AuthoringRevision
            ?? throw new InvalidOperationException("Script Asset lifecycle initial revision is missing.");
        var lifecycleSourcePath = $"scripts/avalonia_lifecycle_{Environment.ProcessId}.luau";
        var lifecycleRenamedPath = $"scripts/avalonia_lifecycle_{Environment.ProcessId}_renamed.luau";
        var lifecycleSourceFile = Path.Combine(projectDirectory, lifecycleSourcePath.Replace('/', Path.DirectorySeparatorChar));
        var lifecycleRenamedFile = Path.Combine(projectDirectory, lifecycleRenamedPath.Replace('/', Path.DirectorySeparatorChar));
        try
        {
            avaloniaViewModel.ScriptSourceText = originalSourceText + "\n-- lifecycle dirty gate\n";
            avaloniaViewModel.ScriptAssetPath = lifecycleSourcePath;
            Require(!avaloniaViewModel.CanCreateScriptAsset
                && !avaloniaViewModel.CanRenameScriptAsset
                && !avaloniaViewModel.CanDeleteScriptAsset
                && !avaloniaViewModel.CanUndoScriptAsset,
                "dirty Script Source buffer did not gate Script Asset lifecycle commands");
            try
            {
                _ = await avaloniaViewModel.CreateScriptAssetForCurrentProjectAsync(cancellationToken);
                throw new InvalidOperationException("dirty Script Source buffer unexpectedly allowed Script Asset create");
            }
            catch (EditorRpcException exception) when (exception.Code == "script_source_dirty") { }
            avaloniaViewModel.ScriptSourceText = workspace.ScriptSource.Document?.Source ?? string.Empty;

            Require(avaloniaViewModel.CanCreateScriptAsset, "Avalonia did not enable Script Asset create for a clean Script v2 project");
            var createdAsset = await avaloniaViewModel.CreateScriptAssetForCurrentProjectAsync(cancellationToken);
            Require(createdAsset.Asset.ScriptId == 3
                && createdAsset.Asset.SourcePath == lifecycleSourcePath
                && File.Exists(lifecycleSourceFile)
                && avaloniaViewModel.SelectedScriptSourceId == createdAsset.Asset.ScriptId
                && avaloniaViewModel.ScriptSourcePath == lifecycleSourcePath
                && workspace.ScriptAssetLifecycle.UndoDepth == 1,
                "Avalonia Script Asset create did not project the allocated identity and default source");

            avaloniaViewModel.ScriptSourceText += "\n-- lifecycle create dirty gate\n";
            Require(!avaloniaViewModel.CanRenameScriptAsset
                && !avaloniaViewModel.CanDeleteScriptAsset
                && !avaloniaViewModel.CanUndoScriptAsset,
                "dirty newly-created Script Source did not gate rename, delete, and lifecycle undo");
            avaloniaViewModel.ScriptSourceText = """
                --!strict

                return {
                    on_start = function(self: Kadath.Object)
                        self:translate(96, 0)
                    end,
                    fixed_update = function(self: Kadath.Object, dt: number)
                        self:translate(12 * dt, 0)
                    end,
                }
                """;
            var savedAssetSource = await avaloniaViewModel.SaveScriptSourceForCurrentProjectAsync(cancellationToken);
            Require(savedAssetSource.SourceDocument.ScriptId == createdAsset.Asset.ScriptId
                && savedAssetSource.SourceDocument.Source == avaloniaViewModel.ScriptSourceText
                && workspace.ScriptSource.UndoDepth == 1,
                "Avalonia did not edit the newly created Script Asset through the existing source-authoring seam");

            var lifecycleObject = avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.Kind == "player");
            var lifecycleContract = avaloniaViewModel.AvailableBehaviorContracts.Single(entry => entry.ScriptId == createdAsset.Asset.ScriptId);
            avaloniaViewModel.SelectedSceneObject = lifecycleObject;
            avaloniaViewModel.SelectedBehaviorContract = lifecycleContract;
            Require(avaloniaViewModel.CanAddBehaviorBinding, "new Script Asset was not available to Behavior Binding authoring");
            avaloniaViewModel.AddBehaviorBinding();
            var boundAsset = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
            Require(boundAsset.ProjectSnapshot.Scene.Objects!.Single(value => value.ObjectId == lifecycleObject.ObjectId)
                    .Behaviors?.Any(value => value.ScriptId == createdAsset.Asset.ScriptId) == true,
                "Avalonia did not bind the new Script Asset to the selected Scene Object");

            var preRenameBake = await workspace.BakeAsync(new BakeStartParameters("Both", "debug"), cancellationToken);
            Require(preRenameBake.ScriptArtifactRevision is { Length: 64 }
                && preRenameBake.ScriptArtifactBytes is > 0,
                "bound Script Asset did not publish its pre-rename KSCP artifact");
            _ = await workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: openProjectName, LiveBake: true), cancellationToken);
            await WaitUntilAsync(
                () => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Loaded,
                cancellationToken,
                "pre-rename Script Asset Runtime load",
                () => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Failed
                    || workspace.Preview.State is EditorPreviewState.Failed or EditorPreviewState.Stopped,
                () => $"preview={workspace.Preview.State}; runtime={workspace.Preview.Runtime.State}; error={workspace.Preview.Runtime.ErrorCode}:{workspace.Preview.Runtime.ErrorMessage}");
            await WaitUntilAsync(
                () => LatestBehaviorOnStartPlayerX(avaloniaViewModel.EventLog) is > 400,
                cancellationToken,
                "pre-rename Script Asset Runtime execution");
            Require(workspace.Preview.State == EditorPreviewState.Running
                && workspace.Preview.Runtime.Script.ArtifactRevision == preRenameBake.ScriptArtifactRevision,
                "Runtime did not execute the bound Script Asset before rename");
            _ = await workspace.StopPreviewAsync(cancellationToken);
            avaloniaViewModel.ClearEventLogCommand.Execute(null);

            avaloniaViewModel.ScriptAssetPath = lifecycleRenamedPath;
            var renamedAsset = await avaloniaViewModel.RenameScriptAssetForCurrentProjectAsync(cancellationToken);
            Require(renamedAsset.Asset.ScriptId == createdAsset.Asset.ScriptId
                && renamedAsset.Asset.SourcePath == lifecycleRenamedPath
                && !File.Exists(lifecycleSourceFile)
                && File.Exists(lifecycleRenamedFile)
                && avaloniaViewModel.SelectedScriptSourceId == createdAsset.Asset.ScriptId
                && renamedAsset.ProjectSnapshot.Scene.Objects!.Single(value => value.ObjectId == lifecycleObject.ObjectId)
                    .Behaviors?.Any(value => value.ScriptId == createdAsset.Asset.ScriptId) == true,
                "Avalonia Script Asset rename changed identity, binding, source selection, or file ownership");

            var lifecycleBake = await workspace.BakeAsync(new BakeStartParameters("Both", "debug"), cancellationToken);
            Require(lifecycleBake.ScriptArtifactRevision is { Length: 64 }
                && lifecycleBake.ScriptArtifactBytes is > 0,
                "renamed bound Script Asset did not publish a second KSCP artifact");
            _ = await workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: openProjectName, LiveBake: true), cancellationToken);
            await WaitUntilAsync(
                () => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Loaded,
                cancellationToken,
                "renamed Script Asset Runtime load",
                () => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Failed
                    || workspace.Preview.State is EditorPreviewState.Failed or EditorPreviewState.Stopped,
                () => $"preview={workspace.Preview.State}; runtime={workspace.Preview.Runtime.State}; error={workspace.Preview.Runtime.ErrorCode}:{workspace.Preview.Runtime.ErrorMessage}; "
                    + $"events={string.Join(" | ", avaloniaViewModel.EventLog.TakeLast(20).Select(item => $"{item.Event}:{item.Summary}"))}");
            await WaitUntilAsync(
                () => LatestBehaviorOnStartPlayerX(avaloniaViewModel.EventLog) is > 400,
                cancellationToken,
                "renamed Script Asset Runtime execution");
            Require(workspace.Preview.State == EditorPreviewState.Running
                && workspace.Preview.Runtime.Script.ArtifactRevision == lifecycleBake.ScriptArtifactRevision,
                "Runtime did not execute the renamed Script Asset package");

            var lifecycleRetainedManifest = File.ReadAllBytes(opened.ScriptPath);
            var lifecycleRetainedScene = File.ReadAllBytes(opened.ScenePath);
            var lifecycleRetainedSource = File.ReadAllBytes(lifecycleRenamedFile);
            var lifecycleRetainedArtifact = File.ReadAllBytes(Path.Combine(lifecycleBake.DerivedDirectory, "script.script"));
            var lifecycleRetainedRevision = workspace.ProjectSnapshot.Value?.AuthoringRevision;
            var lifecycleRetainedRuntimeIdentity = workspace.Preview.Runtime.Script.ArtifactRevision;
            try
            {
                _ = await avaloniaViewModel.DeleteScriptAssetForCurrentProjectAsync(cancellationToken);
                throw new InvalidOperationException("bound Script Asset deletion unexpectedly succeeded");
            }
            catch (EditorRpcException exception) when (exception.Code == "script_asset_in_use") { }
            Require(File.ReadAllBytes(opened.ScriptPath).AsSpan().SequenceEqual(lifecycleRetainedManifest)
                && File.ReadAllBytes(opened.ScenePath).AsSpan().SequenceEqual(lifecycleRetainedScene)
                && File.ReadAllBytes(lifecycleRenamedFile).AsSpan().SequenceEqual(lifecycleRetainedSource)
                && File.ReadAllBytes(Path.Combine(lifecycleBake.DerivedDirectory, "script.script")).AsSpan().SequenceEqual(lifecycleRetainedArtifact)
                && workspace.ProjectSnapshot.Value?.AuthoringRevision == lifecycleRetainedRevision
                && workspace.Preview.Runtime.Script.ArtifactRevision == lifecycleRetainedRuntimeIdentity,
                "in-use Script Asset rejection changed source, revision, artifact, or Runtime identity");
            _ = await workspace.StopPreviewAsync(cancellationToken);

            lifecycleObject = avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.Kind == "player");
            avaloniaViewModel.SelectedSceneObject = lifecycleObject;
            avaloniaViewModel.SelectedBehaviorBinding = lifecycleObject.Behaviors.Single(value => value.ScriptId == createdAsset.Asset.ScriptId);
            Require(avaloniaViewModel.CanRemoveBehaviorBinding, "bound Script Asset could not be removed before deletion");
            avaloniaViewModel.RemoveBehaviorBinding();
            var unboundAsset = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
            Require(unboundAsset.ProjectSnapshot.Scene.Objects!.Single(value => value.ObjectId == lifecycleObject.ObjectId).Behaviors is { Count: 1 } remainingBehaviors
                    && remainingBehaviors.Single().ScriptId == scriptDependency.ScriptId,
                "Avalonia did not remove the Script Asset binding while preserving the Player controller");

            var deletedAsset = await avaloniaViewModel.DeleteScriptAssetForCurrentProjectAsync(cancellationToken);
            Require(deletedAsset.Asset.ScriptId == createdAsset.Asset.ScriptId
                && !File.Exists(lifecycleRenamedFile)
                && avaloniaViewModel.SelectedScriptSourceId == scriptDependency.ScriptId,
                "Avalonia Script Asset delete did not select the remaining manifest neighbor");

            var deleteUndone = await avaloniaViewModel.UndoScriptAssetForCurrentProjectAsync(cancellationToken);
            Require(deleteUndone.Asset.ScriptId == createdAsset.Asset.ScriptId
                && File.Exists(lifecycleRenamedFile)
                && avaloniaViewModel.SelectedScriptSourceId == createdAsset.Asset.ScriptId
                && avaloniaViewModel.ScriptSourcePath == lifecycleRenamedPath,
                "Avalonia lifecycle undo did not restore the deleted Script Asset");

            var undoUnbind = await avaloniaViewModel.UndoAuthoringForCurrentProjectAsync(cancellationToken);
            Require(undoUnbind.ProjectSnapshot.Scene.Objects!.Single(value => value.ObjectId == lifecycleObject.ObjectId)
                    .Behaviors?.Any(value => value.ScriptId == createdAsset.Asset.ScriptId) == true,
                "interleaved Authoring undo did not restore the Script Asset binding");

            var renameUndone = await avaloniaViewModel.UndoScriptAssetForCurrentProjectAsync(cancellationToken);
            Require(renameUndone.Asset.ScriptId == createdAsset.Asset.ScriptId
                && File.Exists(lifecycleSourceFile)
                && !File.Exists(lifecycleRenamedFile)
                && avaloniaViewModel.ScriptSourcePath == lifecycleSourcePath
                && renameUndone.ProjectSnapshot.Scene.Objects!.Single(value => value.ObjectId == lifecycleObject.ObjectId)
                    .Behaviors?.Any(value => value.ScriptId == createdAsset.Asset.ScriptId) == true,
                "Avalonia lifecycle undo did not restore the pre-rename source path");
            var undoBind = await avaloniaViewModel.UndoAuthoringForCurrentProjectAsync(cancellationToken);
            Require(undoBind.ProjectSnapshot.Scene.Objects!.Single(value => value.ObjectId == lifecycleObject.ObjectId).Behaviors is { Count: 1 } restoredBehaviors
                    && restoredBehaviors.Single().ScriptId == scriptDependency.ScriptId,
                "interleaved Authoring undo did not restore the pre-binding Player controller state");
            var sourceUndone = await avaloniaViewModel.UndoScriptSourceForCurrentProjectAsync(cancellationToken);
            Require(sourceUndone.SourceDocument.Source == createdAsset.SourceDocument?.Source
                && workspace.ScriptSource.UndoDepth == 0,
                "interleaved Script Source undo did not restore the lifecycle default source");
            var createUndone = await avaloniaViewModel.UndoScriptAssetForCurrentProjectAsync(cancellationToken);
            Require(createUndone.Revision == lifecycleOriginalRevision
                && !File.Exists(lifecycleSourceFile)
                && workspace.ScriptAssetLifecycle.UndoDepth == 0
                && avaloniaViewModel.SelectedScriptSourceId == scriptDependency.ScriptId,
                "Avalonia lifecycle undo did not remove the created Script Asset and restore the original revision");
            Console.WriteLine("workflow_script_asset_runtime_execution=ok");
        }
        finally
        {
            if (avaloniaViewModel.IsScriptSourceDirty) { avaloniaViewModel.ScriptSourceText = workspace.ScriptSource.Document?.Source ?? string.Empty; }
            if (workspace.Preview.OwnsPublicationSync) { try { _ = await workspace.StopPreviewAsync(cancellationToken); } catch { } }
        }
        Console.WriteLine("workflow_script_asset_lifecycle=ok");

        var oldHierarchyLabel = avaloniaViewModel.HierarchyItems[0];
        var oldAssetLabel = avaloniaViewModel.AssetItems[0];
        avaloniaViewModel.SelectedHierarchyItem = oldHierarchyLabel;
        avaloniaViewModel.SelectedAssetItem = oldAssetLabel;
        var observedAtomicCacheClear = false;
        void ObserveCreatedSession(object? _, System.ComponentModel.PropertyChangedEventArgs args)
        {
            if (args.PropertyName != nameof(EditorProjectViewModel.Session)
                || workspace.Project.Session?.ProjectName != createdProjectName) { return; }
            Require(avaloniaViewModel.HierarchyItems.Count == 0
                && avaloniaViewModel.AssetItems.Count == 0
                && avaloniaViewModel.SelectedHierarchyItem is null
                && avaloniaViewModel.SelectedAssetItem is null
                && avaloniaViewModel.SelectedSceneObject is null
                && avaloniaViewModel.SceneObjectDrafts.Count == 0
                && avaloniaViewModel.SelectedScenePrototype is null
                && avaloniaViewModel.ScenePrototypeDrafts.Count == 0
                && avaloniaViewModel.InspectorText.Length == 0
                && avaloniaViewModel.SceneGoalX.Length == 0
                && avaloniaViewModel.SceneGoalY.Length == 0
                && avaloniaViewModel.ScriptGoalX.Length == 0
                && avaloniaViewModel.ScriptGoalY.Length == 0
                && avaloniaViewModel.ScriptVelocityX.Length == 0
                && avaloniaViewModel.ScriptVelocityY.Length == 0
                && avaloniaViewModel.SceneTextureAssignments.All(slot => slot.IsEmpty),
                "Avalonia retained old UI projection when the Workspace Session identity changed");

            // 通过公开选择属性探测字典；旧 label 不得再恢复旧 Inspector。
            avaloniaViewModel.SelectedHierarchyItem = oldHierarchyLabel;
            avaloniaViewModel.SelectedAssetItem = oldAssetLabel;
            Require(avaloniaViewModel.InspectorText.Length == 0,
                "Avalonia retained a stale hierarchy/asset lookup after Session switch");
            avaloniaViewModel.SelectedHierarchyItem = null;
            avaloniaViewModel.SelectedAssetItem = null;
            observedAtomicCacheClear = true;
        }

        workspace.Project.PropertyChanged += ObserveCreatedSession;
        ProjectSessionInfo created;
        try
        {
            avaloniaViewModel.ProjectName = createdProjectName;
            created = await avaloniaViewModel.CreateProjectForCurrentInputAsync(cancellationToken);
            // project_create 成功返回就是 created project 的最近所有权边界，不能延迟到 Dispose 猜测认领。
            ownershipFixture?.ClaimCreatedProject(created.ProjectDirectory);
        }
        finally { workspace.Project.PropertyChanged -= ObserveCreatedSession; }

        Require(observedAtomicCacheClear
            && created.ProjectName == createdProjectName
            && workspace.ProjectSnapshot.Value?.ProjectName == createdProjectName
            && workspace.HierarchySnapshot.Value?.ProjectName == createdProjectName
            && avaloniaViewModel.HierarchyItems.Count == (workspace.ProjectSnapshot.Value?.Scene.SchemaVersion is 5 or 6 or 7 or 8 or 9
                ? workspace.HierarchySnapshot.Value?.Nodes.Length
                : 13)
            && avaloniaViewModel.AssetItems.Count == expectedAssetCount
            && avaloniaViewModel.SceneObjectDrafts.Count == 5
            && (workspace.ProjectSnapshot.Value?.Scene.SchemaVersion is not (6 or 7 or 8 or 9)
                || avaloniaViewModel.ScenePrototypeDrafts is [{ PrototypeId: "runtime-orb" }])
            && avaloniaViewModel.InspectorText.Contains("scene.objects[goal]", StringComparison.Ordinal),
            "Avalonia public Create did not project the new Session snapshots after atomic cache invalidation");
        Console.WriteLine("workflow_project_create=ok");
        Require(workspace.Publication.State == EditorPublicationState.Missing, "fresh project should expose missing publication artifacts");
        Console.WriteLine("workflow_publication_missing=ok");

        // 工作流 smoke 覆盖真实 authoring transaction：Apply 更新文件并建立撤销记录，Undo 恢复原值。
        var originalObjectIds = avaloniaViewModel.SceneObjectDrafts.Select(draft => draft.ObjectId).ToArray();
        var originalGoalX = avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.Kind == "goal").PositionX;
        var originalPlayerTextureId = avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.Kind == "player").TextureIdText;
        var originalSceneTextureAsset = avaloniaViewModel.SceneTextureAssignments[0].SelectedAssetItem;
        var createdSceneSchemaVersion = workspace.ProjectSnapshot.Value?.Scene.SchemaVersion
            ?? throw new InvalidOperationException("Created project snapshot is missing.");
        var alternateSceneTextureAsset = avaloniaViewModel.AssetItems.FirstOrDefault(label => label.Contains("goal.texture", StringComparison.Ordinal) && label != originalSceneTextureAsset)
            ?? avaloniaViewModel.AssetItems.FirstOrDefault(label => label.Contains("test.texture", StringComparison.Ordinal) && label != originalSceneTextureAsset);
        Require(!string.IsNullOrWhiteSpace(alternateSceneTextureAsset), "workflow fixture did not expose an alternate renderer2d texture asset");
        var playerDraft = avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.Kind == "player");
        avaloniaViewModel.SelectedSceneObject = playerDraft;
        Require(!avaloniaViewModel.CanDeleteSelectedSceneObject && !avaloniaViewModel.DeleteSceneObjectCommand.CanExecute(null),
            "Avalonia allowed deletion of the unique Player");
        avaloniaViewModel.AddDecorativeSpriteDraft();
        var addedSpriteId = avaloniaViewModel.SelectedSceneObject?.ObjectId;
        string? addedHazardId = null;
        if (avaloniaViewModel.CanAddPatrolHazard)
        {
            avaloniaViewModel.AddPatrolHazardDraft();
            addedHazardId = avaloniaViewModel.SelectedSceneObject?.ObjectId
                ?? throw new InvalidOperationException("Avalonia did not select the new Patrol Hazard draft");
        }
        avaloniaViewModel.MoveSelectedSceneObjectUp();
        var goalDraft = avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.Kind == "goal");
        goalDraft.PositionX = (double.Parse(goalDraft.PositionX, CultureInfo.InvariantCulture) + 11d).ToString("R", CultureInfo.InvariantCulture);
        playerDraft.TextureIdText = originalPlayerTextureId == "1" ? "2" : "1";
        avaloniaViewModel.SceneTextureAssignments[0].SelectedAssetItem = alternateSceneTextureAsset;
        var appliedAuthoring = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(appliedAuthoring.State, "succeeded", StringComparison.OrdinalIgnoreCase)
            && workspace.Authoring.UndoDepth == 1
            && appliedAuthoring.ChangedFields.Contains("scene.objects")
            && appliedAuthoring.ChangedFields.Contains("scene.textures")
            && appliedAuthoring.ProjectSnapshot.Scene.SchemaVersion == createdSceneSchemaVersion
            && appliedAuthoring.ProjectSnapshot.Scene.Objects?.Count == originalObjectIds.Length + 1 + (addedHazardId is null ? 0 : 1)
            && appliedAuthoring.ProjectSnapshot.Scene.Objects.Any(item => item.ObjectId == addedSpriteId)
            && (addedHazardId is null || appliedAuthoring.ProjectSnapshot.Scene.Objects.Any(item => item.ObjectId == addedHazardId)),
            "authoring apply did not commit the complete Scene Object replacement");
        Require(avaloniaViewModel.SceneTextureAssignments[0].SelectedAssetItem == alternateSceneTextureAsset,
            "authoring apply did not keep the editable texture assignment in sync");
        Console.WriteLine("workflow_authoring_apply=ok");

        var undoneAuthoring = await avaloniaViewModel.UndoAuthoringForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(undoneAuthoring.Operation, "undo", StringComparison.OrdinalIgnoreCase)
            && workspace.Authoring.UndoDepth == 0
            && workspace.Authoring.RedoDepth == 1
            && avaloniaViewModel.SceneObjectDrafts.Select(draft => draft.ObjectId).SequenceEqual(originalObjectIds)
            && avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.Kind == "goal").PositionX == originalGoalX
            && avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.Kind == "player").TextureIdText == originalPlayerTextureId
            && avaloniaViewModel.SceneTextureAssignments[0].SelectedAssetItem == originalSceneTextureAsset, "authoring undo did not restore the prior values");
        Console.WriteLine("workflow_authoring_undo=ok");

        var redoneAuthoring = await avaloniaViewModel.RedoAuthoringForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(redoneAuthoring.Operation, "redo", StringComparison.OrdinalIgnoreCase)
            && workspace.Authoring.UndoDepth == 1
            && workspace.Authoring.RedoDepth == 0
            && avaloniaViewModel.SceneObjectDrafts.Any(draft => draft.ObjectId == addedSpriteId),
            "authoring redo did not restore the edited Scene Objects");
        _ = await avaloniaViewModel.UndoAuthoringForCurrentProjectAsync(cancellationToken);
        Require(avaloniaViewModel.SceneObjectDrafts.Select(draft => draft.ObjectId).SequenceEqual(originalObjectIds),
            "authoring undo after redo did not restore the baseline");
        Console.WriteLine("workflow_authoring_redo=ok");

        var validation = await workspace.ValidateProjectAsync(createdProjectName, cancellationToken);
        Require(string.Equals(validation.State, "valid", StringComparison.OrdinalIgnoreCase), "project_validate was not valid");
        Console.WriteLine("workflow_project_validate=ok");

        var baked = await workspace.BakeAsync(new BakeStartParameters("Both", "debug"), cancellationToken);
        Require(string.Equals(baked.State, "succeeded", StringComparison.OrdinalIgnoreCase), "bake did not succeed");
        Console.WriteLine("workflow_bake=ok");
        Require(workspace.Publication.State == EditorPublicationState.Current, "full bake did not publish a current snapshot");
        var publishedGoalDraft = avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.Kind == "goal");
        publishedGoalDraft.PositionX = (double.Parse(publishedGoalDraft.PositionX, CultureInfo.InvariantCulture) + 5d).ToString("R", CultureInfo.InvariantCulture);
        var changedAfterPublish = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(changedAfterPublish.State, "succeeded", StringComparison.OrdinalIgnoreCase) && workspace.Publication.State == EditorPublicationState.SourceDirty, "published source edit did not become dirty");
        Console.WriteLine("workflow_publication_dirty=ok");
        var incremental = await workspace.BakeChangesAsync("debug", cancellationToken);
        Require(incremental?.Target == "Scene" && workspace.Publication.State == EditorPublicationState.Current, "Bake Changes did not choose Scene after source edit");
        Console.WriteLine("workflow_bake_changes=ok");

        var watched = await workspace.StartWatchAsync(new WatchStartParameters("Scene", "debug", 50, 100), cancellationToken);
        Require(string.Equals(watched.State, "watching", StringComparison.OrdinalIgnoreCase), "watch did not start");
        await WaitUntilAsync(() => workspace.Watch.State == EditorWatchState.Watching, cancellationToken, "watching state");
        Console.WriteLine("workflow_watch_start=ok");

        var stoppedWatch = await workspace.StopWatchAsync(cancellationToken);
        Require(string.Equals(stoppedWatch.State, "stopped", StringComparison.OrdinalIgnoreCase), "watch did not stop");
        await WaitUntilAsync(() => workspace.Watch.State == EditorWatchState.Stopped, cancellationToken, "watch stopped state");
        Console.WriteLine("workflow_watch_stop=ok");

        // Preview 仍使用独立 native window；27A 额外跨越 live bake/watch 验证 Runtime 实际确认 revision。
        var preview = await workspace.StartPreviewAsync(new PreviewStartParameters(
            ProjectName: createdProjectName,
            WatchChanges: true,
            PollIntervalMilliseconds: 50,
            DebounceMilliseconds: 100,
            LiveBake: true,
            BakeProfile: "debug"), cancellationToken);
        Require(string.Equals(preview.SurfaceMode, PreviewSurfaceModes.ExternalWindow, StringComparison.Ordinal), "preview surface mode mismatch");
        await WaitUntilAsync(() => workspace.Preview.Surface is not null && workspace.Preview.RuntimeProcessId is not null, cancellationToken, "preview surface/runtime pid");
        Console.WriteLine("workflow_preview_start=ok");
        await WaitUntilAsync(
            () => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Loaded,
            cancellationToken,
            "preview initial loaded identity",
            () => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Failed
                || workspace.Preview.State is EditorPreviewState.Failed or EditorPreviewState.Stopped,
            () => $"preview={workspace.Preview.State}; runtime={workspace.Preview.Runtime.State}; "
                + $"runtimeError={workspace.Preview.Runtime.ErrorCode}:{workspace.Preview.Runtime.ErrorMessage}; "
                + $"events={string.Join(" | ", avaloniaViewModel.EventLog.TakeLast(20).Select(item => $"{item.Event}:{item.Summary}"))}");
        Require(workspace.Preview.Runtime.Scene.ArtifactRevision is { Length: 64 }
            && workspace.Preview.Runtime.Scene.ArtifactBytes is > 0
            && workspace.Preview.Runtime.Script.ArtifactRevision is { Length: 64 }
            && workspace.Preview.Runtime.Script.ArtifactBytes is > 0,
            "Avalonia did not project the atomic Runtime initial identity");
        Console.WriteLine("workflow_preview_initial_loaded=ok");

        var createdScriptDependency = workspace.ProjectSnapshot.Value?.Script.Dependencies?.SingleOrDefault(
            dependency => dependency.ScriptId == 2 && dependency.Source == "scripts/player_controller.luau")
            ?? throw new InvalidOperationException("Created Script v2 project does not expose the Player controller dependency.");
        var createdScriptHierarchyLabel = avaloniaViewModel.HierarchyItems.Single(label =>
            label.Contains($"script.dependencies[{createdScriptDependency.ScriptId}]", StringComparison.Ordinal));
        avaloniaViewModel.SelectedHierarchyItem = createdScriptHierarchyLabel;
        await WaitUntilAsync(
            () => avaloniaViewModel.HasScriptSourceDocument
                && avaloniaViewModel.SelectedScriptSourceId == createdScriptDependency.ScriptId,
            cancellationToken,
            "created project Script source document");
        var createdScriptDocument = workspace.ScriptSource.Document
            ?? throw new InvalidOperationException("Created Script source document is missing.");
        var retainedScriptArtifactRevision = workspace.Preview.Runtime.Script.ArtifactRevision
            ?? throw new InvalidOperationException("Runtime Script artifact identity is missing.");
        var retainedScriptSourceRevision = workspace.Preview.Runtime.Script.SourceRevision;
        var retainedScriptReloadRequest = workspace.Preview.Reload.Script.LatestRequestId;
        var scriptArtifactPath = Path.Combine(baked.DerivedDirectory, "script.script");
        var retainedScriptArtifact = File.ReadAllBytes(scriptArtifactPath);
        var retainedManifest = File.ReadAllBytes(baked.ManifestPath);
        var liveBakeFailureCount = avaloniaViewModel.EventLog.Count(item => item.Event == "live_bake_failed");

        const string invalidScriptBuffer = "--!strict\nlocal value: string = 1\nreturn {}";
        avaloniaViewModel.ScriptSourceText = invalidScriptBuffer;
        await WaitUntilAsync(
            () => workspace.ScriptDiagnostics.State == EditorScriptDiagnosticsState.Invalid
                && workspace.ScriptDiagnostics.Items.Count > 0,
            cancellationToken,
            "invalid Script buffer diagnostics");
        Require(avaloniaViewModel.CanSaveScriptSource,
            "Invalid diagnostics incorrectly disabled Script source save.");
        var invalidSaved = await avaloniaViewModel.SaveScriptSourceForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(invalidSaved.State, "succeeded", StringComparison.OrdinalIgnoreCase)
            && invalidSaved.SourceDocument.Source == invalidScriptBuffer,
            "Avalonia did not persist the intentionally invalid Script buffer.");
        await WaitUntilAsync(
            () => avaloniaViewModel.EventLog.Count(item => item.Event == "live_bake_failed") > liveBakeFailureCount,
            cancellationToken,
            "invalid Script Live Bake failure");
        Require(File.ReadAllBytes(scriptArtifactPath).AsSpan().SequenceEqual(retainedScriptArtifact)
            && File.ReadAllBytes(baked.ManifestPath).AsSpan().SequenceEqual(retainedManifest)
            && workspace.Preview.Runtime.Script.ArtifactRevision == retainedScriptArtifactRevision
            && workspace.Preview.Runtime.Script.SourceRevision == retainedScriptSourceRevision
            && workspace.Preview.Reload.Script.LatestRequestId == retainedScriptReloadRequest,
            "Invalid Script Live Bake replaced the retained KSCP or advanced Runtime identity.");

        var fixedScriptBuffer = createdScriptDocument.Source + "\n-- Avalonia diagnostics workflow fixed\n";
        avaloniaViewModel.ScriptSourceText = fixedScriptBuffer;
        await WaitUntilAsync(
            () => workspace.ScriptDiagnostics.State == EditorScriptDiagnosticsState.Valid,
            cancellationToken,
            "fixed Script buffer diagnostics");
        var fixedSaved = await avaloniaViewModel.SaveScriptSourceForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(fixedSaved.State, "succeeded", StringComparison.OrdinalIgnoreCase)
            && fixedSaved.SourceDocument.Source == fixedScriptBuffer,
            "Avalonia did not persist the fixed Script buffer.");
        await WaitUntilAsync(
            () => workspace.Preview.Reload.Script.State == EditorPreviewReloadState.Acknowledged
                && workspace.Preview.Reload.Script.LatestRequestId > retainedScriptReloadRequest
                && workspace.Preview.Reload.Script.AcknowledgedArtifactRevision is { } revision
                && revision != retainedScriptArtifactRevision,
            cancellationToken,
            "fixed Script Runtime reload acknowledgement");
        Require(!File.ReadAllBytes(scriptArtifactPath).AsSpan().SequenceEqual(retainedScriptArtifact)
            && !File.ReadAllBytes(baked.ManifestPath).AsSpan().SequenceEqual(retainedManifest)
            && workspace.Preview.Runtime.Script.ArtifactRevision != retainedScriptArtifactRevision,
            "Fixed Script Live Bake did not publish and load a new KSCP identity.");
        Console.WriteLine("workflow_script_diagnostics_publication=ok");

        var liveGoalDraft = avaloniaViewModel.SceneObjectDrafts.Single(draft => draft.Kind == "goal");
        liveGoalDraft.PositionX = (double.Parse(liveGoalDraft.PositionX, CultureInfo.InvariantCulture) + 3d).ToString("R", CultureInfo.InvariantCulture);
        var liveEdited = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(liveEdited.State, "succeeded", StringComparison.OrdinalIgnoreCase), "live Preview authoring update failed");
        await WaitUntilAsync(() => workspace.Preview.Reload.Scene.State == EditorPreviewReloadState.Acknowledged, cancellationToken, "Scene Runtime reload acknowledgement");
        Require(workspace.Preview.Reload.Scene.AcknowledgedSourceRevision is { Length: 64 }
            && workspace.Preview.Reload.Scene.AcknowledgedArtifactRevision is { Length: 64 }
            && avaloniaViewModel.RuntimeSyncStatus.Contains("Scene loaded", StringComparison.Ordinal),
            "Avalonia did not project the acknowledged Scene revision");
        Console.WriteLine("workflow_preview_reload_ack=ok");

        var stoppedPreview = await workspace.StopPreviewAsync(cancellationToken);
        Require(string.Equals(stoppedPreview.State, "stopped", StringComparison.OrdinalIgnoreCase), "preview_stop response mismatch");
        await WaitUntilAsync(() => workspace.Preview.State == EditorPreviewState.Stopped, cancellationToken, "preview stopped event");
        Console.WriteLine("workflow_preview_stop=ok");

        var importAssetName = $"workflow_imported_{Guid.NewGuid():N}"[..26];
        var importedRelativePath = $"assets/renderer2d/{importAssetName}.texture";
        var importedAssetPath = Path.Combine(packageRoot, "bin", "assets", "renderer2d", $"{importAssetName}.texture");
        try
        {
            avaloniaViewModel.TextureImportSourcePath = Path.Combine(kadathRoot, "assets", "renderer2d", "test.png");
            avaloniaViewModel.TextureImportAssetName = importAssetName;
            avaloniaViewModel.TextureImportProfile = "debug";
            var imported = await avaloniaViewModel.ImportTextureForCurrentProjectAsync(cancellationToken);
            var importedLabel = avaloniaViewModel.AssetItems.FirstOrDefault(label => label.Contains($"{importAssetName}.texture", StringComparison.Ordinal));
            Require(string.Equals(imported.State, "succeeded", StringComparison.OrdinalIgnoreCase)
                && imported.RelativePath == importedRelativePath
                && workspace.TextureImport.State == EditorTextureImportState.Succeeded
                && workspace.AssetCatalogSnapshot.Value?.ItemCount == expectedAssetCount + 1
                && imported.AssetCatalog.ItemCount == expectedAssetCount + 1
                && importedLabel is not null
                && avaloniaViewModel.SelectedAssetItem == importedLabel
                && avaloniaViewModel.TextureImportStatus.Contains("成功", StringComparison.Ordinal),
                "Avalonia texture import did not refresh and select the imported asset projection");
            Console.WriteLine("workflow_texture_import=ok");
        }
        finally
        {
            if (File.Exists(importedAssetPath)) { File.Delete(importedAssetPath); }
        }

        await workspace.ShutdownAsync(cancellationToken);
        await avaloniaViewModel.DisposeAsync();
        Console.WriteLine("workflow_shutdown=ok");
        Console.WriteLine("verification=ok");
    }

    private static async Task WaitUntilAsync(
        Func<bool> predicate,
        CancellationToken cancellationToken,
        string description,
        Func<bool>? terminalFailure = null,
        Func<string>? failureDetails = null)
    {
        while (!predicate())
        {
            if (terminalFailure?.Invoke() == true)
            {
                throw new InvalidOperationException($"{description} failed: {failureDetails?.Invoke() ?? "terminal failure"}");
            }
            await Task.Delay(50, cancellationToken);
        }

        // 保持描述参数用于调用点自解释；条件已满足时不产生额外输出，输出协议保持稳定。
        _ = description;
    }

    private static double? LatestBehaviorOnStartPlayerX(IEnumerable<EditorEventLogItem> eventLog)
    {
        foreach (var item in eventLog.Reverse().Where(value => value.Event == "runtime_log"))
        {
            try
            {
                using var document = JsonDocument.Parse(item.Summary);
                var message = document.RootElement.GetProperty("message").GetString();
                const string marker = "player_position=(";
                var start = message?.IndexOf(marker, StringComparison.Ordinal) ?? -1;
                if (start < 0) continue;
                start += marker.Length;
                var end = message!.IndexOf(',', start);
                if (end > start && double.TryParse(message.AsSpan(start, end - start), NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
                    return value;
            }
            catch (JsonException) { }
        }
        return null;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }

    private static IReadOnlyDictionary<string, string> CaptureBehaviorSignatures(ProjectModelSnapshot project)
    {
        var objects = project.Scene.Objects ?? throw new InvalidOperationException("Project snapshot does not expose Scene Objects.");
        return objects.ToDictionary(
            sceneObject => sceneObject.ObjectId,
            sceneObject => JsonSerializer.Serialize(sceneObject.Behaviors, EditorProtocol.JsonOptions),
            StringComparer.Ordinal);
    }

    private static void RequireBehaviorSignatures(
        ProjectModelSnapshot project,
        IReadOnlyDictionary<string, string> expected,
        string operation)
    {
        var actual = CaptureBehaviorSignatures(project);
        Require(actual.Count == expected.Count
            && expected.All(pair => actual.TryGetValue(pair.Key, out var signature) && signature == pair.Value),
            $"Avalonia {operation} changed Scene v5 behavior bindings");
    }

    private static async Task HeadlessSmokeAsync()
    {
        // 无窗口 smoke 检查编译后的 Avalonia resource，避免平台 backend 启动消息循环。
        var assembly = typeof(MainWindow).Assembly;
        if (!assembly.GetManifestResourceNames().Contains("!AvaloniaResources", StringComparer.Ordinal)
            || !assembly.GetTypes().Any(type => type.FullName?.Contains("Views/MainWindow.axaml", StringComparison.Ordinal) == true))
        {
            throw new InvalidOperationException("Compiled MainWindow XAML resource is missing.");
        }
        Console.WriteLine("avalonia_compiled_xaml=ok");

        await using var transport = new SmokeTransport();
        await using var client = new EditorRpcClient(transport, "avalonia-smoke", "1");
        await using var workspace = new EditorWorkspaceViewModel(client, new InlineEditorViewDispatcher());
        var viewModel = new AvaloniaEditorViewModel(workspace, new InlineEditorViewDispatcher(), Environment.CurrentDirectory);
        await workspace.ConnectAsync();
        if (!ReferenceEquals(viewModel.Workspace, workspace)) { throw new InvalidOperationException("Avalonia ViewModel did not retain injected Workspace."); }
        await transport.EmitPreviewStatusAsync("live_bake_failed");
        using var eventProjectionTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await WaitUntilAsync(
            () => viewModel.EventLog.Any(item => item.Event == "live_bake_failed"),
            eventProjectionTimeout.Token,
            "preview_status nested event projection");
        Console.WriteLine("preview_status_event_log_projection=ok");
        var sourceDocument = await workspace.ReadScriptSourceAsync(new ScriptSourceQueryParameters("smoke_created", 1));
        Require(workspace.ScriptSource.State == EditorScriptSourceState.Ready
            && workspace.ScriptSource.Document == sourceDocument
            && sourceDocument.SourcePath == "scripts/patrol.luau"
            && sourceDocument.Source.Contains("fixed_update", StringComparison.Ordinal),
            "shared Workspace did not expose the selected Behavior Script Asset source");
        Console.WriteLine("script_source_read_model=ok");
        const string invalidBuffer = "-- invalid\nreturn {}";
        workspace.ObserveScriptSourceBuffer(sourceDocument, invalidBuffer);
        using var diagnosticsTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await WaitUntilAsync(
            () => workspace.ScriptDiagnostics.State == EditorScriptDiagnosticsState.Invalid,
            diagnosticsTimeout.Token,
            "headless Script diagnostics");
        Require(viewModel.HasScriptDiagnostics
            && viewModel.ScriptDiagnostics.Count == 1
            && viewModel.ScriptDiagnosticsStatus.Contains("1 个错误", StringComparison.Ordinal)
            && viewModel.ReanalyzeScriptSourceCommand.CanExecute(null),
            "Avalonia did not project the shared Script diagnostics state and command");
        viewModel.SelectedScriptDiagnostic = viewModel.ScriptDiagnostics[0];
        Require(viewModel.ScriptSourceCaretIndex == 0,
            "Avalonia diagnostic selection did not move the source caret");
        workspace.ObserveScriptSourceBuffer(sourceDocument, sourceDocument.Source);
        await WaitUntilAsync(
            () => workspace.ScriptDiagnostics.State == EditorScriptDiagnosticsState.Valid,
            diagnosticsTimeout.Token,
            "headless valid Script diagnostics");
        Require(!viewModel.HasScriptDiagnostics && viewModel.ScriptDiagnosticsStatus == "未发现问题。",
            "Avalonia did not clear diagnostics after the buffer became valid");
        Console.WriteLine("script_source_diagnostics=ok");
        // Live Bake/Watch 保持 opt-in，打开编辑器本身不能隐式启动派生构建。
        if (viewModel.LiveBakeEnabled || viewModel.WatchChanges) { throw new InvalidOperationException("Live Bake/Watch must be disabled by default."); }
        Console.WriteLine("live_bake_opt_in=ok");
        Require(!viewModel.CanImportTexture
            && !viewModel.ImportTextureCommand.CanExecute(null)
            && viewModel.TextureImportSourcePath.Length == 0
            && viewModel.TextureImportAssetName == "imported"
            && viewModel.TextureImportProfile == "debug",
            "Avalonia texture import controls were not initialized behind project/capability gating");
        Console.WriteLine("texture_import_controls=ok");

        var textureIds = new System.Collections.ObjectModel.ObservableCollection<string>(["1"]);
        var v5Draft = SceneObjectDraftViewModel.FromSnapshot(
            new ProjectModelSceneObject(
                "hazard-v5",
                "patrol_hazard",
                [0, 0],
                [1, 1],
                [1, 1, 1, 1],
                1,
                Behaviors:
                [
                    new ProjectModelSceneBehaviorBinding(
                        7,
                        [new ProjectModelSceneBehaviorParameter("speed", 80)]),
                    new ProjectModelSceneBehaviorBinding(
                        11,
                        [new ProjectModelSceneBehaviorParameter("weight", 0.5)])
                ]),
            textureIds);
        var v5Definitions = v5Draft.CreateBehaviorDefinitions();
        var v5Binding = v5Definitions?.FirstOrDefault();
        var v5SecondBinding = v5Definitions?.Skip(1).FirstOrDefault();
        Require(!v5Draft.UsesNativePatrol
            && v5Binding is not null
            && v5Binding.ScriptId == 7
            && v5Binding.Parameters is { } v5Parameters
            && v5Parameters.TryGetValue("speed", out var speed)
            && speed == 80,
            "Avalonia did not preserve Scene v5 behavior bindings in the draft model");
        Require(v5SecondBinding is not null
            && v5SecondBinding.ScriptId == 11
            && v5Definitions?.Count == 2,
            "Avalonia did not preserve Scene v5 behavior binding order");
        var contract7 = new BehaviorContractEntry(7, "scripts/seven.luau", new string('7', 64),
            [new BehaviorParameterSchema("speed", "number", 80, 0, 1000)]);
        v5Draft.ApplyBehaviorContracts(new Dictionary<uint, BehaviorContractEntry> { [7] = contract7 }, catalogAvailable: true);
        Require(!v5Draft.AreBehaviorsValid
            && v5Draft.Behaviors.Single(binding => binding.ScriptId == 11).Status.Contains("不在当前契约目录", StringComparison.Ordinal),
            "Avalonia accepted an existing binding whose scriptId is absent from the current catalog");
        var identityDraft = SceneBehaviorBindingDraftViewModel.FromSnapshot(
            new ProjectModelSceneBehaviorBinding(7, [new ProjectModelSceneBehaviorParameter("speed", 80)]));
        identityDraft.ApplyContract(contract7, catalogAvailable: true);
        identityDraft.ApplyContract(contract7 with { SourceHash = new string('8', 64) }, catalogAvailable: true);
        Require(identityDraft.HasIdentityConflict && !identityDraft.IsValid,
            "Avalonia silently reused a binding draft after its Script source identity changed");
        var schemaIdentityDraft = SceneBehaviorBindingDraftViewModel.FromSnapshot(
            new ProjectModelSceneBehaviorBinding(7, [new ProjectModelSceneBehaviorParameter("speed", 80)]));
        schemaIdentityDraft.ApplyContract(contract7, catalogAvailable: true);
        schemaIdentityDraft.ApplyContract(contract7 with
        {
            Parameters = [new BehaviorParameterSchema("speed", "number", 90, 0, 1000)]
        }, catalogAvailable: true);
        Require(schemaIdentityDraft.HasIdentityConflict && !schemaIdentityDraft.IsValid,
            "Avalonia silently reused a binding draft after its parameter schema identity changed");

        var v4Draft = SceneObjectDraftViewModel.FromSnapshot(
            new ProjectModelSceneObject(
                "hazard-v4",
                "patrol_hazard",
                [0, 0],
                [1, 1],
                [1, 1, 1, 1],
                1,
                PatrolMinY: -1,
                PatrolMaxY: 1,
                PatrolSpeed: 2,
                Behaviors: []),
            textureIds);
        Require(v4Draft.UsesNativePatrol && v4Draft.CreateBehaviorDefinitions() is { Count: 0 },
            "Avalonia did not retain Scene v4 native Patrol semantics");
        Console.WriteLine("behavior_binding_projection=ok");

        if (!viewModel.SupportsExternalWindow || viewModel.SupportsSharedTexture || viewModel.SupportsFrameStream)
        {
            throw new InvalidOperationException("Preview capability gating does not match the v1 external-window contract.");
        }

        Require(viewModel.CanCreateProject && viewModel.CreateProjectCommand.CanExecute(null),
            "project_create capability did not enable the Avalonia command while both lifecycles were stopped");
        viewModel.PackageRoot = "C:/smoke-package";
        viewModel.ProjectName = "smoke_created";
        transport.DelayNextCreateResponse();
        using var createTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var createTask = viewModel.CreateProjectForCurrentInputAsync(createTimeout.Token);
        await WaitUntilAsync(() => transport.DelayedCreatePending, createTimeout.Token, "headless project_create request");
        Require(viewModel.IsBusy
            && workspace.Project.State == EditorProjectState.Creating
            && !viewModel.CanCreateProject
            && !viewModel.CreateProjectCommand.CanExecute(null),
            "Project.Creating did not disable the Avalonia Create command");
        await transport.ReleaseDelayedCreateAsync();
        var created = await createTask.WaitAsync(createTimeout.Token);
        Require(created.ProjectName == "smoke_created"
            && viewModel.HierarchyItems.Count == 4
            && viewModel.AssetItems.Count == 1
            && viewModel.SceneObjectDrafts.Count == 3
            && viewModel.SelectedSceneObject?.ObjectId == "goal",
            "public Avalonia Create workflow did not project the created snapshots");
        Require(viewModel.SceneGameplayProfile == "goal_hazard_v1"
            && viewModel.SceneGameplayTimeLimitSeconds == "3"
            && viewModel.IsGameplayEnabled,
            "Avalonia did not project the Gameplay Profile authoring fields");
        viewModel.SceneGameplayProfile = "none";
        Require(!viewModel.IsGameplayEnabled,
            "Avalonia did not update Gameplay-dependent authoring state after Profile changed");
        viewModel.SceneGameplayProfile = "goal_hazard_v1";

        var retainedSceneGoalX = viewModel.SceneGoalX;
        await transport.EmitProjectCreatedAsync(created with
        {
            PackageRoot = "c:\\smoke-package\\.",
            ProjectName = "SMOKE_CREATED"
        });
        await transport.EmitReplayBarrierAsync();
        await WaitUntilAsync(
            () => viewModel.EventLog.LastOrDefault()?.Event == "headless_project_replay_barrier",
            createTimeout.Token,
            "same-identity project_created replay");
        Require(viewModel.HierarchyItems.Count == 4
            && viewModel.AssetItems.Count == 1
            && viewModel.SceneObjectDrafts.Count == 3
            && viewModel.SceneGoalX == retainedSceneGoalX,
            "normalized same-identity project_created replay cleared the Avalonia projection");

        viewModel.SelectedSceneObject = viewModel.SceneObjectDrafts.Single(draft => draft.Kind == "player");
        Require(!viewModel.DeleteSceneObjectCommand.CanExecute(null), "unique Player delete command was enabled");
        viewModel.AddDecorativeSpriteCommand.Execute(null);
        var addedSprite = viewModel.SelectedSceneObject;
        viewModel.AddPatrolHazardCommand.Execute(null);
        var addedHazard = viewModel.SelectedSceneObject;
        Require(viewModel.SceneObjectDrafts.Count == 5
            && addedSprite?.Kind == "sprite"
            && addedHazard?.Kind == "patrol_hazard"
            && viewModel.DeleteSceneObjectCommand.CanExecute(null),
            "Scene Object add/delete command gating mismatch");
        var hazardIndex = viewModel.SceneObjectDrafts.IndexOf(addedHazard!);
        viewModel.MoveSceneObjectUpCommand.Execute(null);
        Require(viewModel.SceneObjectDrafts.IndexOf(addedHazard!) == hazardIndex - 1, "Scene Object move-up did not change source order");
        viewModel.DeleteSceneObjectCommand.Execute(null);
        viewModel.SelectedSceneObject = viewModel.SceneObjectDrafts.Single(draft => draft.Kind == "patrol_hazard");
        Require(!viewModel.DeleteSceneObjectCommand.CanExecute(null), "last Patrol Hazard delete command was enabled");
        viewModel.SelectedSceneObject = addedSprite;
        viewModel.DeleteSceneObjectCommand.Execute(null);
        Require(viewModel.SceneObjectDrafts.Count == 3, "Scene Object draft cleanup did not restore the baseline count");
        Console.WriteLine("scene_object_draft_commands=ok");

        var createEnvelope = transport.LastProjectCreateRequest
            ?? throw new InvalidOperationException("Avalonia Create did not cross the typed Client transport seam");
        var createParameters = createEnvelope.GetProperty("params");
        var createParameterNames = createParameters.EnumerateObject()
            .Select(property => property.Name)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();
        Require(createParameterNames.SequenceEqual(["packageRoot", "projectName"])
            && createParameters.GetProperty("packageRoot").GetString() == "C:/smoke-package"
            && createParameters.GetProperty("projectName").GetString() == "smoke_created",
            "Avalonia Create added parameters outside PackageRoot/ProjectName");
        Console.WriteLine("project_create_gating=ok");

        viewModel.TextureImportSourcePath = "C:/source/smoke.ppm";
        viewModel.TextureImportAssetName = "smoke_imported";
        viewModel.TextureImportProfile = "debug";
        Require(viewModel.CanImportTexture && viewModel.ImportTextureCommand.CanExecute(null),
            "texture_import capability did not enable the Avalonia import command for an open project");
        var imported = await viewModel.ImportTextureForCurrentProjectAsync(createTimeout.Token);
        var importedLabel = viewModel.AssetItems.FirstOrDefault(label => label.Contains("smoke_imported.texture", StringComparison.Ordinal));
        Require(imported.RelativePath == "assets/renderer2d/smoke_imported.texture"
            && workspace.TextureImport.State == EditorTextureImportState.Succeeded
            && workspace.AssetCatalogSnapshot.Value?.ItemCount == 2
            && viewModel.AssetItems.Count == 2
            && importedLabel is not null
            && viewModel.SelectedAssetItem == importedLabel,
            "Avalonia texture import did not refresh and select the new Asset Catalog item");
        Console.WriteLine("texture_import_projection=ok");

        transport.FailNextWatchStart();
        try
        {
            _ = await workspace.StartWatchAsync(new WatchStartParameters("Scene", "debug"), createTimeout.Token);
            throw new InvalidOperationException("injected watch_start failure unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "watch_start_failed") { }
        Require(workspace.Watch.State == EditorWatchState.Failed
            && !viewModel.CanCreateProject
            && viewModel.CanRequestWatchStop
            && viewModel.StopWatchCommand.CanExecute(null),
            "Watch Failed did not keep Stop enabled while Create stayed disabled");
        viewModel.StopWatchCommand.Execute(null);
        await WaitUntilAsync(() => workspace.Watch.State == EditorWatchState.Stopped, createTimeout.Token, "failed watch recovery");
        Require(viewModel.CanCreateProject, "Create did not recover after Watch returned to Stopped");

        transport.FailNextPreviewStart();
        try
        {
            _ = await workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: "smoke_created"), createTimeout.Token);
            throw new InvalidOperationException("injected preview_start failure unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "preview_start_failed") { }
        Require(workspace.Preview.State == EditorPreviewState.Failed
            && !viewModel.CanCreateProject
            && viewModel.CanRequestPreviewStop
            && viewModel.StopPreviewCommand.CanExecute(null),
            "Preview Failed did not keep Stop enabled while Create stayed disabled");
        viewModel.StopPreviewCommand.Execute(null);
        await WaitUntilAsync(() => workspace.Preview.State == EditorPreviewState.Stopped, createTimeout.Token, "failed preview recovery");
        Require(viewModel.CanCreateProject,
            "Create did not recover after both Watch and Preview returned to Stopped");
        Console.WriteLine("failed_lifecycle_stop_recovery=ok");

        await using (var gameplayTransport = new SmokeTransport(sceneV7: true))
        await using (var gameplayClient = new EditorRpcClient(gameplayTransport, "avalonia-gameplay-authoring-smoke", "1"))
        await using (var gameplayWorkspace = new EditorWorkspaceViewModel(gameplayClient, new InlineEditorViewDispatcher()))
        {
            var gameplayViewModel = new AvaloniaEditorViewModel(gameplayWorkspace, new InlineEditorViewDispatcher(), "C:/gameplay-package");
            await gameplayWorkspace.ConnectAsync(createTimeout.Token);
            gameplayViewModel.PackageRoot = "C:/gameplay-package";
            gameplayViewModel.ProjectName = "gameplay";
            _ = await gameplayViewModel.CreateProjectForCurrentInputAsync(createTimeout.Token);
            Require(gameplayViewModel.SceneGameplayProfile == "goal_hazard_v1"
                && gameplayViewModel.SceneGameplayTimeLimitSeconds == "3",
                "Scene v7 Gameplay authoring projection mismatch");
            Require(gameplayViewModel.ScenePrototypeDrafts is [{ PrototypeId: "runtime-orb", Kind: "sprite" }]
                && gameplayViewModel.HierarchyItems.Count == 4,
                "Avalonia did not project Spawn Prototypes separately from the Scene Hierarchy");
            gameplayViewModel.SelectedScenePrototype = gameplayViewModel.ScenePrototypeDrafts[0];
            gameplayViewModel.AddScenePrototypeCommand.Execute(null);
            var addedPrototype = gameplayViewModel.SelectedScenePrototype;
            Require(gameplayViewModel.ScenePrototypeDrafts.Count == 2
                && addedPrototype?.PrototypeId == "prototype-1"
                && gameplayViewModel.DeleteScenePrototypeCommand.CanExecute(null),
                "Spawn Prototype add/delete command gating mismatch");
            gameplayViewModel.MoveScenePrototypeUpCommand.Execute(null);
            Require(gameplayViewModel.ScenePrototypeDrafts[0] == addedPrototype,
                "Spawn Prototype move-up did not preserve Source Prototype Order");
            gameplayViewModel.DeleteScenePrototypeCommand.Execute(null);
            Require(gameplayViewModel.ScenePrototypeDrafts is [{ PrototypeId: "runtime-orb" }],
                "Spawn Prototype draft cleanup did not restore the baseline collection");

            gameplayViewModel.SelectedScenePrototype = gameplayViewModel.ScenePrototypeDrafts[0];
            gameplayViewModel.SelectedScenePrototype.SizeX = "0";
            Require(!gameplayViewModel.CanApplyAuthoring,
                "Invalid Spawn Prototype draft did not disable Authoring Apply");
            gameplayViewModel.SelectedScenePrototype.SizeX = "52";
            Require(gameplayViewModel.CanApplyAuthoring,
                "Corrected Spawn Prototype draft did not re-enable Authoring Apply");
            var prototypeApplied = await gameplayViewModel.ApplyAuthoringForCurrentProjectAsync(createTimeout.Token);
            var prototypePatch = gameplayTransport.LastAuthoringApplyRequest?.GetProperty("params").GetProperty("patch")
                ?? throw new InvalidOperationException("Avalonia Prototype Apply did not cross the typed transport seam");
            Require(prototypeApplied.ChangedFields.Contains("scene.prototypes")
                && prototypePatch.GetProperty("scenePrototypes")[0].GetProperty("prototypeId").GetString() == "runtime-orb"
                && prototypePatch.GetProperty("scenePrototypes")[0].GetProperty("size")[0].GetDouble() == 52,
                "Avalonia did not send the edited Spawn Prototype collection");

            gameplayViewModel.SceneGameplayProfile = "none";
            var disabledGameplay = await gameplayViewModel.ApplyAuthoringForCurrentProjectAsync(createTimeout.Token);
            var disabledPatch = gameplayTransport.LastAuthoringApplyRequest?.GetProperty("params").GetProperty("patch")
                ?? throw new InvalidOperationException("Avalonia Gameplay Apply did not cross the typed transport seam");
            Require(disabledGameplay.ChangedFields.Contains("scene.gameplay.profile")
                && disabledPatch.GetProperty("sceneGameplayProfile").GetString() == "none",
                "Avalonia did not send the disabled Gameplay Profile");

            // 中立场景只要求至少一个对象，UI 不能继续套用旧 Gameplay 三角色约束。
            while (gameplayViewModel.SceneObjectDrafts.Count > 1)
                gameplayViewModel.SceneObjectDrafts.RemoveAt(gameplayViewModel.SceneObjectDrafts.Count - 1);
            gameplayViewModel.SceneObjectDrafts[0].PositionX = "12";
            _ = await gameplayViewModel.ApplyAuthoringForCurrentProjectAsync(createTimeout.Token);

            gameplayViewModel.SceneGameplayProfile = "goal_hazard_v1";
            gameplayViewModel.SceneGameplayTimeLimitSeconds = "4.25";
            var enabledGameplay = await gameplayViewModel.ApplyAuthoringForCurrentProjectAsync(createTimeout.Token);
            var enabledPatch = gameplayTransport.LastAuthoringApplyRequest!.Value.GetProperty("params").GetProperty("patch");
            Require(enabledGameplay.ChangedFields.Contains("scene.gameplay.profile")
                && enabledGameplay.ChangedFields.Contains("scene.gameplay.timeLimitSeconds")
                && enabledPatch.GetProperty("sceneGameplayProfile").GetString() == "goal_hazard_v1"
                && enabledPatch.GetProperty("sceneGameplayTimeLimitSeconds").GetDouble() == 4.25,
                "Avalonia did not send the enabled Gameplay Profile and time limit");
        }
        Console.WriteLine("gameplay_profile_authoring=ok");

        await using var noCreateTransport = new SmokeTransport(advertiseProjectCreate: false);
        await using var noCreateClient = new EditorRpcClient(noCreateTransport, "avalonia-no-create-smoke", "1");
        await using var noCreateWorkspace = new EditorWorkspaceViewModel(noCreateClient, new InlineEditorViewDispatcher());
        var noCreateViewModel = new AvaloniaEditorViewModel(noCreateWorkspace, new InlineEditorViewDispatcher(), Environment.CurrentDirectory);
        await noCreateWorkspace.ConnectAsync(createTimeout.Token);
        Require(!noCreateViewModel.CanCreateProject
            && !noCreateViewModel.CreateProjectCommand.CanExecute(null),
            "Avalonia enabled Create without the negotiated project_create capability");
        Console.WriteLine("project_create_capability_absence=ok");

        Console.WriteLine("shared_workspace_injection=ok");
        Console.WriteLine("capability_gating=ok");
        Console.WriteLine("verification=ok");
    }

    private sealed class SmokeTransport : IEditorRpcTransport
    {
        private readonly Channel<string> _lines = Channel.CreateUnbounded<string>();
        private long _sequence;
        private string _activePackageRoot = "C:/smoke-package";
        private string _activeProjectName = "smoke_created";
        private string? _importedRelativePath;
        private bool _delayNextCreate;
        private bool _failNextWatchStart;
        private bool _failNextPreviewStart;
        private readonly bool _advertiseProjectCreate;
        private readonly bool _sceneV7;
        private string _gameplayProfile = "goal_hazard_v1";
        private double? _gameplayTimeLimitSeconds = 3;
        private string _authoringRevision = new('1', 64);
        private int _authoringMutationCount;
        private TaskCompletionSource<bool>? _delayedCreateRelease;
        private TaskCompletionSource<bool>? _delayedCreateCompleted;
        public bool IsOpen { get; private set; }
        public bool DelayedCreatePending => _delayedCreateRelease is not null;
        public JsonElement? LastProjectCreateRequest { get; private set; }
        public JsonElement? LastAuthoringApplyRequest { get; private set; }

        public SmokeTransport(bool advertiseProjectCreate = true, bool sceneV7 = false)
        {
            _advertiseProjectCreate = advertiseProjectCreate;
            _sceneV7 = sceneV7;
        }

        public Task StartAsync(CancellationToken cancellationToken = default)
        {
            IsOpen = true;
            var hello = new EditorHello(EditorProtocol.SchemaVersion, "hello", EditorProtocol.ProtocolName, EditorProtocol.SchemaVersion, [EditorProtocol.TransportName], ["rpc", "preview-surface"]);
            _lines.Writer.TryWrite(JsonSerializer.Serialize(hello, EditorProtocol.JsonOptions));
            return Task.CompletedTask;
        }

        public async Task SendLineAsync(string line, CancellationToken cancellationToken = default)
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!root.TryGetProperty("method", out var methodElement)) { return; }
            var method = methodElement.GetString();
            var id = root.GetProperty("id").GetString()!;
            switch (method)
            {
                case "get_capabilities":
                    await SendResponseAsync(id, new EditorCapabilities(
                        CreateCommands(),
                        [EditorProtocol.TransportName],
                        [
                            new PreviewSurfaceCapability(PreviewSurfaceModes.ExternalWindow, "native-window", true),
                            new PreviewSurfaceCapability(PreviewSurfaceModes.SharedTexture, "gpu-shared-resource", false),
                            new PreviewSurfaceCapability(PreviewSurfaceModes.FrameStream, "encoded-frame-stream", false)
                        ])).ConfigureAwait(false);
                    break;
                case "project_create":
                    LastProjectCreateRequest = root.Clone();
                    var parameters = root.GetProperty("params");
                    var packageRoot = parameters.GetProperty("packageRoot").GetString()!;
                    var projectName = parameters.GetProperty("projectName").GetString()!;
                    var session = NewSession(packageRoot, projectName);
                    if (_delayNextCreate)
                    {
                        _delayNextCreate = false;
                        _delayedCreateRelease = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                        _delayedCreateCompleted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                        _ = CompleteDelayedCreateAsync(id, session, _delayedCreateRelease.Task, _delayedCreateCompleted);
                        break;
                    }
                    await CompleteCreateAsync(id, session).ConfigureAwait(false);
                    break;
                case "project_snapshot":
                    var project = NewProjectSnapshot();
                    await EmitEventAsync("project_snapshot_created", project, id).ConfigureAwait(false);
                    await SendResponseAsync(id, project).ConfigureAwait(false);
                    break;
                case "hierarchy_snapshot":
                    var hierarchy = NewHierarchySnapshot();
                    await EmitEventAsync("hierarchy_snapshot_created", hierarchy, id).ConfigureAwait(false);
                    await SendResponseAsync(id, hierarchy).ConfigureAwait(false);
                    break;
                case "asset_catalog_snapshot":
                    var assets = NewAssetCatalogSnapshot();
                    await EmitEventAsync("asset_catalog_snapshot_created", assets, id).ConfigureAwait(false);
                    await SendResponseAsync(id, assets).ConfigureAwait(false);
                    break;
                case "script_source_read":
                    await SendResponseAsync(id, new ScriptSourceDocument(
                        _activeProjectName,
                        1,
                        "scripts/patrol.luau",
                        "return { fixed_update = function() end }\n",
                        new string('1', 64))).ConfigureAwait(false);
                    break;
                case "script_source_analyze":
                    var analysisParameters = root.GetProperty("params");
                    var analysisSource = analysisParameters.GetProperty("source").GetString() ?? string.Empty;
                    var diagnostics = analysisSource.Contains("-- invalid", StringComparison.Ordinal)
                        ? new[]
                        {
                            new ScriptSourceDiagnostic(
                                "error",
                                "analysis",
                                "LUAU_ANALYSIS_ERROR",
                                "injected analysis error",
                                "scripts/patrol.luau",
                                new ScriptSourceRange(
                                    new ScriptSourcePosition(1, 1),
                                    new ScriptSourcePosition(1, 2)))
                        }
                        : [];
                    await SendResponseAsync(id, new ScriptSourceAnalysisResult(
                        diagnostics.Length == 0 ? "valid" : "invalid",
                        analysisParameters.GetProperty("projectName").GetString() ?? _activeProjectName,
                        analysisParameters.GetProperty("scriptId").GetUInt32(),
                        "scripts/patrol.luau",
                        analysisParameters.GetProperty("sourceHash").GetString() ?? string.Empty,
                        new string('1', 64),
                        "luau-0.732-decb2d0",
                        diagnostics)).ConfigureAwait(false);
                    break;
                case "texture_import":
                    var importParameters = root.GetProperty("params");
                    var assetName = importParameters.GetProperty("assetName").GetString()!;
                    var normalizedAssetName = assetName.EndsWith(".texture", StringComparison.Ordinal) ? assetName : $"{assetName}.texture";
                    _importedRelativePath = $"assets/renderer2d/{normalizedAssetName}";
                    var importedCatalog = NewAssetCatalogSnapshot();
                    var importResult = new TextureImportResult(
                        "succeeded",
                        _activeProjectName,
                        importParameters.GetProperty("sourcePath").GetString()!,
                        "asset://" + _importedRelativePath["assets/".Length..],
                        _importedRelativePath,
                        importParameters.TryGetProperty("profile", out var profile) ? profile.GetString() ?? "debug" : "debug",
                        "P3-PPM",
                        "KDAT-TEXTURE-V1",
                        1,
                        1,
                        1,
                        "smoke-import",
                        64,
                        new string('a', 64),
                        importedCatalog);
                    await EmitEventAsync("texture_import_completed", importResult, id).ConfigureAwait(false);
                    await SendResponseAsync(id, importResult).ConfigureAwait(false);
                    break;
                case "authoring_apply":
                    LastAuthoringApplyRequest = root.Clone();
                    var authoringParameters = root.GetProperty("params");
                    var authoringPatch = authoringParameters.GetProperty("patch");
                    var changedFields = new List<string>();
                    if (authoringPatch.TryGetProperty("sceneGameplayProfile", out var gameplayProfile)
                        && gameplayProfile.ValueKind == JsonValueKind.String)
                    {
                        _gameplayProfile = gameplayProfile.GetString()!;
                        if (_gameplayProfile == "none") _gameplayTimeLimitSeconds = null;
                        changedFields.Add("scene.gameplay.profile");
                    }
                    if (authoringPatch.TryGetProperty("sceneGameplayTimeLimitSeconds", out var gameplayTimeLimit)
                        && gameplayTimeLimit.ValueKind == JsonValueKind.Number)
                    {
                        _gameplayTimeLimitSeconds = gameplayTimeLimit.GetDouble();
                        changedFields.Add("scene.gameplay.timeLimitSeconds");
                    }
                    if (authoringPatch.TryGetProperty("sceneObjects", out var sceneObjects)
                        && sceneObjects.ValueKind == JsonValueKind.Array)
                    {
                        changedFields.Add("scene.objects");
                    }
                    if (authoringPatch.TryGetProperty("scenePrototypes", out var scenePrototypes)
                        && scenePrototypes.ValueKind == JsonValueKind.Array)
                    {
                        changedFields.Add("scene.prototypes");
                    }
                    if (authoringPatch.TryGetProperty("sceneTextures", out var sceneTextures)
                        && sceneTextures.ValueKind == JsonValueKind.Array)
                    {
                        changedFields.Add("scene.textures");
                    }
                    var previousRevision = _authoringRevision;
                    _authoringMutationCount++;
                    _authoringRevision = new string("23456789abcdef"[_authoringMutationCount - 1], 64);
                    var authoredProject = NewProjectSnapshot();
                    await SendResponseAsync(id, new AuthoringMutationResult(
                        "apply",
                        "succeeded",
                        _activeProjectName,
                        previousRevision,
                        _authoringRevision,
                        changedFields.Distinct(StringComparer.Ordinal).ToArray(),
                        1,
                        authoredProject,
                        NewHierarchySnapshot())).ConfigureAwait(false);
                    break;
                case "watch_start":
                    if (_failNextWatchStart)
                    {
                        _failNextWatchStart = false;
                        await SendErrorAsync(id, "watch_start_failed", "injected watch start failure").ConfigureAwait(false);
                        break;
                    }
                    var watched = new EditorWatchResult("watching", _activeProjectName, "Scene", "debug", null);
                    await EmitEventAsync("watch_started", watched, id).ConfigureAwait(false);
                    await SendResponseAsync(id, watched).ConfigureAwait(false);
                    break;
                case "watch_stop":
                    var stoppedWatch = new EditorWatchResult("stopped", _activeProjectName, "Scene", "debug", null);
                    await EmitEventAsync("watch_stopped", stoppedWatch, id).ConfigureAwait(false);
                    await SendResponseAsync(id, stoppedWatch).ConfigureAwait(false);
                    break;
                case "preview_start":
                    if (_failNextPreviewStart)
                    {
                        _failNextPreviewStart = false;
                        await SendErrorAsync(id, "preview_start_failed", "injected preview start failure").ConfigureAwait(false);
                        break;
                    }
                    await SendResponseAsync(id, new PreviewStartResult("starting", PreviewSurfaceModes.ExternalWindow)).ConfigureAwait(false);
                    break;
                case "preview_stop":
                    await EmitEventAsync("preview_stopped", new { exitCode = 0, requested = true }, id).ConfigureAwait(false);
                    await SendResponseAsync(id, new PreviewStopResult("stopped")).ConfigureAwait(false);
                    break;
            }
        }

        public void DelayNextCreateResponse() => _delayNextCreate = true;

        public void FailNextWatchStart() => _failNextWatchStart = true;

        public void FailNextPreviewStart() => _failNextPreviewStart = true;

        public Task EmitProjectCreatedAsync(ProjectSessionInfo session) =>
            EmitEventAsync("project_created", session);

        public Task EmitReplayBarrierAsync() =>
            EmitEventAsync("headless_project_replay_barrier", new { });

        public Task EmitPreviewStatusAsync(string eventName) =>
            EmitEventAsync("preview_status", new { @event = eventName, errorCode = "injected" });

        private string[] CreateCommands()
        {
            var commands = new List<string>
            {
                "get_capabilities", "project_open", "project_validate", "project_snapshot", "hierarchy_snapshot",
                "asset_catalog_snapshot", "script_source_read", "script_source_analyze", "texture_import", "authoring_apply", "authoring_undo", "authoring_redo", "bake_start", "watch_start", "watch_stop", "preview_start", "preview_stop", "shutdown"
            };
            if (_advertiseProjectCreate) { commands.Insert(2, "project_create"); }
            return commands.ToArray();
        }

        public async Task ReleaseDelayedCreateAsync()
        {
            var release = _delayedCreateRelease ?? throw new InvalidOperationException("No delayed project_create is pending.");
            var completed = _delayedCreateCompleted ?? throw new InvalidOperationException("Delayed project_create completion is missing.");
            release.TrySetResult(true);
            await completed.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            _delayedCreateRelease = null;
            _delayedCreateCompleted = null;
        }

        private async Task CompleteDelayedCreateAsync(
            string id,
            ProjectSessionInfo session,
            Task release,
            TaskCompletionSource<bool> completed)
        {
            try
            {
                await release.ConfigureAwait(false);
                await CompleteCreateAsync(id, session).ConfigureAwait(false);
            }
            finally { completed.TrySetResult(true); }
        }

        private async Task CompleteCreateAsync(string id, ProjectSessionInfo session)
        {
            _activePackageRoot = session.PackageRoot;
            _activeProjectName = session.ProjectName;
            await EmitEventAsync("project_created", session, id).ConfigureAwait(false);
            await SendResponseAsync(id, session).ConfigureAwait(false);
        }

        private static ProjectSessionInfo NewSession(string packageRoot, string projectName)
        {
            var directory = $"{packageRoot}/bin/projects/{projectName}";
            return new ProjectSessionInfo(
                packageRoot,
                projectName,
                directory,
                $"{directory}/scene.json",
                $"{directory}/script.json",
                $"{directory}/preview.json",
                1);
        }

        private ProjectModelSnapshot NewProjectSnapshot()
        {
            var textures = new[]
            {
                new ProjectModelTexture(1, "assets/renderer2d/test.texture"),
                new ProjectModelTexture(2, "assets/renderer2d/goal.texture"),
                new ProjectModelTexture(3, "assets/renderer2d/hazard.texture")
            };
            var objects = new[]
            {
                new ProjectModelSceneObject("player", "player", [1d, 2d], [32d, 32d], [1d, 1d, 1d, 1d], 1, MoveSpeed: 180d, Behaviors: []),
                new ProjectModelSceneObject("goal", "goal", [3d, 4d], [24d, 24d], [1d, 0.75d, 0.1d, 1d], 2, Behaviors: []),
                _sceneV7
                    ? new ProjectModelSceneObject(
                        "hazard", "patrol_hazard", [5d, 6d], [24d, 24d], [1d, 0.2d, 0.2d, 1d], 3,
                        Behaviors: [new ProjectModelSceneBehaviorBinding(1, [])])
                    : new ProjectModelSceneObject(
                        "hazard", "patrol_hazard", [5d, 6d], [24d, 24d], [1d, 0.2d, 0.2d, 1d], 3,
                        PatrolMinY: 0d, PatrolMaxY: 10d, PatrolSpeed: 2d)
            };
            var gameplayEnabled = _gameplayProfile == "goal_hazard_v1";
            var prototypes = _sceneV7
                ? new[]
                {
                    new ProjectModelScenePrototype(
                        "runtime-orb",
                        "sprite",
                        [48d, 48d],
                        [0.35d, 0.85d, 1d, 1d],
                        2,
                        [new ProjectModelSceneBehaviorBinding(1, [])])
                }
                : Array.Empty<ProjectModelScenePrototype>();
            var scene = _sceneV7
                ? new ProjectModelScene(
                    7,
                    gameplayEnabled ? [3d, 4d] : [],
                    gameplayEnabled ? 1u : 0u,
                    gameplayEnabled ? 2u : 0u,
                    gameplayEnabled ? 3u : 0u,
                    textures,
                    objects,
                    GameplayProfile: _gameplayProfile,
                    GameplayTimeLimitSeconds: _gameplayTimeLimitSeconds,
                    Prototypes: prototypes)
                : new ProjectModelScene(4, [3d, 4d], 1, 2, 3, textures, objects);
            var script = _sceneV7
                ? new ProjectModelScript(2, [], [], [new ProjectModelScriptDependency(1, "scripts/patrol.luau")])
                : new ProjectModelScript(1, [3d, 4d], [1d, 0d]);
            return new ProjectModelSnapshot(
                1,
                _activeProjectName,
                _authoringRevision,
                new ProjectModelFiles(
                    $"{_activePackageRoot}/bin/projects/{_activeProjectName}",
                    $"{_activePackageRoot}/bin/projects/{_activeProjectName}/scene.json",
                    $"{_activePackageRoot}/bin/projects/{_activeProjectName}/script.json",
                    $"{_activePackageRoot}/bin/projects/{_activeProjectName}/preview.json"),
                scene,
                script,
                new ProjectModelPreview(1));
        }

        private HierarchySnapshot NewHierarchySnapshot() => new(
            2,
            1,
            _activeProjectName,
            [
                new HierarchyNode("scene", null, "Scene", "SceneDocument", []),
                new HierarchyNode("scene.objects[player]", "scene", "player", "SceneObject", []),
                new HierarchyNode("scene.objects[goal]", "scene", "goal", "SceneObject", []),
                new HierarchyNode("scene.objects[hazard]", "scene", "hazard", "SceneObject", [])
            ]);

        private AssetCatalogSnapshot NewAssetCatalogSnapshot()
        {
            var items = new List<AssetCatalogItem>
            {
                new("asset://scenes/smoke.scene", "smoke.scene", "assets/scenes/smoke.scene", "Scene", "scene", 64, [])
            };
            if (_sceneV7)
            {
                // v7 authoring smoke 需要真实 texture catalog 映射，避免绕过公开 SceneTextureAssignment seam。
                items.Add(new("asset://renderer2d/test.texture", "test.texture", "assets/renderer2d/test.texture", "Texture", "texture", 64, []));
                items.Add(new("asset://renderer2d/goal.texture", "goal.texture", "assets/renderer2d/goal.texture", "Texture", "texture", 64, []));
                items.Add(new("asset://renderer2d/hazard.texture", "hazard.texture", "assets/renderer2d/hazard.texture", "Texture", "texture", 64, []));
            }
            if (_importedRelativePath is not null)
            {
                items.Add(new AssetCatalogItem(
                    "asset://" + _importedRelativePath["assets/".Length..],
                    Path.GetFileName(_importedRelativePath),
                    _importedRelativePath,
                    "Texture",
                    "texture",
                    64,
                    []));
            }
            return new AssetCatalogSnapshot(1, "bin/assets", items.Count, items.ToArray());
        }

        private Task EmitEventAsync(string eventName, object data, string? requestId = null) =>
            WriteAsync(new EditorEvent(
                EditorProtocol.SchemaVersion,
                "event",
                Interlocked.Increment(ref _sequence),
                eventName,
                requestId,
                JsonSerializer.SerializeToElement(data, EditorProtocol.JsonOptions)));

        private Task SendResponseAsync<T>(string id, T result) =>
            WriteAsync(new EditorRpcResponse(
                EditorProtocol.SchemaVersion,
                "response",
                id,
                true,
                JsonSerializer.SerializeToElement(result, EditorProtocol.JsonOptions),
                null));

        private Task SendErrorAsync(string id, string code, string message) =>
            WriteAsync(new EditorRpcResponse(
                EditorProtocol.SchemaVersion,
                "response",
                id,
                false,
                null,
                new EditorRpcError(code, message)));

        private Task WriteAsync<T>(T value) =>
            _lines.Writer.WriteAsync(JsonSerializer.Serialize(value, EditorProtocol.JsonOptions)).AsTask();

        public async Task<string?> ReadLineAsync(CancellationToken cancellationToken = default) => await _lines.Reader.ReadAsync(cancellationToken);
        public ValueTask DisposeAsync() { IsOpen = false; _lines.Writer.TryComplete(); return ValueTask.CompletedTask; }
    }
}
