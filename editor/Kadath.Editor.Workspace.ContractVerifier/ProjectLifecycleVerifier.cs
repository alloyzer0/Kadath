using System.Text;
using System.Text.Json;
using Kadath.Editor.Protocol;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Workspace.ContractVerifier;

internal static class ProjectLifecycleVerifier
{
    internal static async Task VerifyAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), $"kadath-project-lifecycle-{Guid.NewGuid():N}");
        try
        {
            var templates = CreatePackage(root);
            var lifecycle = new WorkspaceProjectLifecycleModel();
            var created = await lifecycle.CreateAsync(new ProjectCreateParameters(root, "created"), default);
            Require(File.ReadAllBytes(created.ScenePath).AsSpan().SequenceEqual(templates.Scene), "Create did not preserve Scene template bytes.");
            Require(File.ReadAllBytes(created.ScriptPath).AsSpan().SequenceEqual(templates.Script), "Create did not preserve Script template bytes.");
            Require(!File.Exists(Path.Combine(created.ProjectDirectory, ".kadath-create-claim")), "Successful Create left an ownership claim.");
            var createdSnapshot = await new WorkspaceReadModel().ReadProjectAsync(created, default);
            Require(createdSnapshot.Scene.SchemaVersion == 4 && createdSnapshot.Scene.Objects?.Count == 5,
                "Create did not project the Scene v4 object template.");
            using (var preview = JsonDocument.Parse(File.ReadAllBytes(created.PreviewPath)))
            {
                var runtime = preview.RootElement.GetProperty("runtime");
                var expectedExecutable = OperatingSystem.IsWindows() ? "bin/kadath.exe" : "bin/kadath";
                Require(runtime.GetProperty("executable").GetString() == expectedExecutable, "Create generated the wrong platform executable.");
                Require(runtime.GetProperty("workingDirectory").GetString() == "bin", "Create generated the wrong working directory.");
                Require(runtime.GetProperty("arguments").EnumerateArray().Select(value => value.GetString()).SequenceEqual(
                    new[] { "--scene", "projects/created/scene.json", "--script", "projects/created/script.json" }), "Create generated the wrong source arguments.");
            }

            var opened = await lifecycle.OpenAsync(new ProjectOpenParameters(root, "created"), default);
            Require(opened == created, "Open did not return the normalized project identity.");
            var beforeValidation = TreeIdentity(root);
            var validation = await lifecycle.ValidateAsync(created, default);
            Require(validation.State == "valid" && validation.ProjectName == "created" && validation.Diagnostics[0] == "validation_engine=native", "Validate result mismatch.");
            Require(beforeValidation == TreeIdentity(root), "Validate modified the package tree.");

            var existingDirectory = Path.Combine(root, "bin", "projects", "existing");
            Directory.CreateDirectory(existingDirectory);
            var sentinel = Path.Combine(existingDirectory, "sentinel.bin");
            File.WriteAllBytes(sentinel, [1, 2, 3]);
            var existingIdentity = TreeIdentity(existingDirectory);
            await ExpectLifecycleFailureAsync(
                () => lifecycle.CreateAsync(new ProjectCreateParameters(root, "existing"), default),
                WorkspaceProjectLifecycleFailureKind.AlreadyExists);
            Require(existingIdentity == TreeIdentity(existingDirectory), "Create modified a preexisting project.");

            await VerifyConcurrentCreateAsync(root);
            await VerifyPreflightFailuresAsync(root, templates);
            await VerifyOwnershipFailureClassificationAsync(root);
            await VerifyStrictValidationAsync(root, lifecycle, created);
            await VerifyFailureClassificationAsync(root, lifecycle, created);
            await VerifyOwnedCleanupAsync(root);
            await VerifyForeignOwnershipAsync(root);
            await VerifyQuarantineRacesAsync(root);
            await VerifyDirectoryReplacementAsync(root);
            await VerifyCancellationAsync(root);
            await VerifyCaseSensitiveContainmentAsync(root, lifecycle, created);
            await VerifyReparseBoundariesAsync(root, lifecycle, created);
            await VerifyBehaviorProjectLifecycleAsync(root);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    private static async Task VerifyConcurrentCreateAsync(string root)
    {
        for (var round = 0; round < 4; round++)
        {
            var projectName = $"race-{round}";
            var tasks = Enumerable.Range(0, 12).Select(async _ =>
            {
                try
                {
                    await new WorkspaceProjectLifecycleModel().CreateAsync(new ProjectCreateParameters(root, projectName), default);
                    return (Succeeded: true, Failure: (WorkspaceProjectLifecycleFailureKind?)null);
                }
                catch (WorkspaceProjectLifecycleException exception)
                {
                    return (Succeeded: false, Failure: (WorkspaceProjectLifecycleFailureKind?)exception.Kind);
                }
            }).ToArray();
            var results = await Task.WhenAll(tasks);
            Require(results.Count(result => result.Succeeded) == 1, "Concurrent Create did not produce exactly one owner.");
            Require(results.Count(result => result.Failure == WorkspaceProjectLifecycleFailureKind.AlreadyExists) == 11, "Concurrent Create did not reject every losing owner.");
        }
    }

    private static async Task VerifyPreflightFailuresAsync(string root, TemplateBytes templates)
    {
        var sceneTemplate = Path.Combine(root, "bin", "assets", "scenes", "preview.scene.json");
        File.Delete(sceneTemplate);
        await ExpectLifecycleFailureAsync(
            () => new WorkspaceProjectLifecycleModel().CreateAsync(new ProjectCreateParameters(root, "missing-template"), default),
            WorkspaceProjectLifecycleFailureKind.Validation);
        Require(!Directory.Exists(Path.Combine(root, "bin", "projects", "missing-template")), "Missing template created a target directory.");
        File.WriteAllBytes(sceneTemplate, templates.Scene);

        File.WriteAllText(sceneTemplate, "{}", Encoding.UTF8);
        await ExpectLifecycleFailureAsync(
            () => new WorkspaceProjectLifecycleModel().CreateAsync(new ProjectCreateParameters(root, "invalid-template"), default),
            WorkspaceProjectLifecycleFailureKind.Validation);
        Require(!Directory.Exists(Path.Combine(root, "bin", "projects", "invalid-template")), "Invalid template created a target directory.");
        File.WriteAllBytes(sceneTemplate, templates.Scene);

        var runtimePath = Path.Combine(root, "bin", OperatingSystem.IsWindows() ? "kadath.exe" : "kadath");
        File.Delete(runtimePath);
        await ExpectLifecycleFailureAsync(
            () => new WorkspaceProjectLifecycleModel().CreateAsync(new ProjectCreateParameters(root, "missing-runtime"), default),
            WorkspaceProjectLifecycleFailureKind.Validation);
        Require(!Directory.Exists(Path.Combine(root, "bin", "projects", "missing-runtime")), "Missing runtime created a target directory.");
        File.WriteAllBytes(runtimePath, [0]);
    }

    private static async Task VerifyStrictValidationAsync(string root, WorkspaceProjectLifecycleModel lifecycle, ProjectSessionInfo project)
    {
        var originalScene = File.ReadAllBytes(project.ScenePath);
        var originalScript = File.ReadAllBytes(project.ScriptPath);
        var originalPreview = File.ReadAllBytes(project.PreviewPath);

        File.WriteAllText(project.ScenePath, AddRootProperty(Encoding.UTF8.GetString(originalScene), "\"unknown\":true"), Encoding.UTF8);
        await ExpectLifecycleFailureAsync(() => lifecycle.ValidateAsync(project, default), WorkspaceProjectLifecycleFailureKind.Validation);
        File.WriteAllBytes(project.ScenePath, originalScene);

        File.WriteAllText(project.ScriptPath, "{", Encoding.UTF8);
        await ExpectLifecycleFailureAsync(() => lifecycle.ValidateAsync(project, default), WorkspaceProjectLifecycleFailureKind.Validation);
        File.WriteAllBytes(project.ScriptPath, originalScript);

        File.WriteAllBytes(project.ScenePath, new byte[WorkspaceProjectValidator.MaxDocumentBytes + 1]);
        await ExpectLifecycleFailureAsync(() => lifecycle.ValidateAsync(project, default), WorkspaceProjectLifecycleFailureKind.Validation);
        File.WriteAllBytes(project.ScenePath, originalScene);

        File.WriteAllText(project.PreviewPath, """
        {"schemaVersion":1,"runtime":{"executable":"bin/kadath","workingDirectory":"bin","arguments":["--scene","../outside.json","--script","projects/created/script.json"]}}
        """, Encoding.UTF8);
        await ExpectLifecycleFailureAsync(() => lifecycle.ValidateAsync(project, default), WorkspaceProjectLifecycleFailureKind.Validation);
        File.WriteAllBytes(project.PreviewPath, originalPreview);

        File.Delete(project.ScriptPath);
        await ExpectLifecycleFailureAsync(() => lifecycle.OpenAsync(new ProjectOpenParameters(root, project.ProjectName), default), WorkspaceProjectLifecycleFailureKind.ProjectFileMissing);
        File.WriteAllBytes(project.ScriptPath, originalScript);
    }

    private static async Task VerifyFailureClassificationAsync(string root, WorkspaceProjectLifecycleModel lifecycle, ProjectSessionInfo project)
    {
        await ExpectLifecycleFailureAsync(
            () => lifecycle.OpenAsync(new ProjectOpenParameters(root, "../invalid"), default),
            WorkspaceProjectLifecycleFailureKind.InvalidProjectName);
        await ExpectLifecycleFailureAsync(
            () => lifecycle.OpenAsync(new ProjectOpenParameters(Path.Combine(root, "missing-package"), project.ProjectName), default),
            WorkspaceProjectLifecycleFailureKind.PackageNotFound);

        var originalScene = File.ReadAllBytes(project.ScenePath);
        File.Delete(project.ScenePath);
        try
        {
            await ExpectLifecycleFailureAsync(
                () => lifecycle.ValidateAsync(project, default),
                WorkspaceProjectLifecycleFailureKind.Validation);
            await ExpectLifecycleFailureAsync(
                () => lifecycle.OpenAsync(new ProjectOpenParameters(root, project.ProjectName), default),
                WorkspaceProjectLifecycleFailureKind.ProjectFileMissing);
        }
        finally
        {
            File.WriteAllBytes(project.ScenePath, originalScene);
        }

        var originalPreview = File.ReadAllBytes(project.PreviewPath);
        File.WriteAllText(project.PreviewPath, """
        {"schemaVersion":1,"runtime":{"executable":"bin/kadath","workingDirectory":"bin","arguments":["--scene","../../outside.json","--script","projects/created/script.json"]}}
        """, Encoding.UTF8);
        try
        {
            await ExpectLifecycleFailureAsync(
                () => lifecycle.ValidateAsync(project, default),
                WorkspaceProjectLifecycleFailureKind.Validation);
            await ExpectLifecycleFailureAsync(
                () => lifecycle.OpenAsync(new ProjectOpenParameters(root, project.ProjectName), default),
                WorkspaceProjectLifecycleFailureKind.Validation);
        }
        finally
        {
            File.WriteAllBytes(project.PreviewPath, originalPreview);
        }

        var missingRoot = Path.Combine(root, "missing-session-package");
        var missingDirectory = Path.Combine(missingRoot, "bin", "projects", project.ProjectName);
        var missingProject = project with
        {
            PackageRoot = missingRoot,
            ProjectDirectory = missingDirectory,
            ScenePath = Path.Combine(missingDirectory, "scene.json"),
            ScriptPath = Path.Combine(missingDirectory, "script.json"),
            PreviewPath = Path.Combine(missingDirectory, "preview.json")
        };
        await ExpectLifecycleFailureAsync(
            () => lifecycle.ValidateAsync(missingProject, default),
            WorkspaceProjectLifecycleFailureKind.Validation);
    }

    private static async Task VerifyOwnershipFailureClassificationAsync(string root)
    {
        var ioPackage = Path.Combine(root, "ownership-io-package");
        CreatePackage(ioPackage);
        var projectsPath = Path.Combine(ioPackage, "bin", "projects");
        var lifecycle = new WorkspaceProjectLifecycleModel(phase =>
        {
            if (phase != WorkspaceProjectCreatePhase.BeforeOwnership) return;
            Directory.Delete(projectsPath);
            File.WriteAllText(projectsPath, "foreign parent", Encoding.UTF8);
        });
        await ExpectLifecycleFailureAsync(
            () => lifecycle.CreateAsync(new ProjectCreateParameters(ioPackage, "io-failure"), default),
            WorkspaceProjectLifecycleFailureKind.Create);
        Require(File.ReadAllText(projectsPath, Encoding.UTF8) == "foreign parent", "Ownership I/O failure modified the foreign parent path.");

        var collisionPackage = Path.Combine(root, "ownership-collision-package");
        CreatePackage(collisionPackage);
        var projectDirectory = Path.Combine(collisionPackage, "bin", "projects", "claim-collision");
        var claimPath = Path.Combine(projectDirectory, ".kadath-create-claim");
        lifecycle = new WorkspaceProjectLifecycleModel(phase =>
        {
            if (phase != WorkspaceProjectCreatePhase.BeforeOwnership) return;
            Directory.CreateDirectory(projectDirectory);
            File.WriteAllText(claimPath, "foreign-owner", Encoding.UTF8);
        });
        await ExpectLifecycleFailureAsync(
            () => lifecycle.CreateAsync(new ProjectCreateParameters(collisionPackage, "claim-collision"), default),
            WorkspaceProjectLifecycleFailureKind.AlreadyExists);
        Require(File.ReadAllText(claimPath, Encoding.UTF8) == "foreign-owner", "Lost-claim classification modified the foreign claim.");
    }

    private static async Task VerifyOwnedCleanupAsync(string root)
    {
        var projectName = "owned-cleanup";
        var lifecycle = new WorkspaceProjectLifecycleModel(phase =>
        {
            if (phase == WorkspaceProjectCreatePhase.AfterPreview) throw new IOException("injected create failure");
        });
        await ExpectLifecycleFailureAsync(
            () => lifecycle.CreateAsync(new ProjectCreateParameters(root, projectName), default),
            WorkspaceProjectLifecycleFailureKind.Create);
        Require(!Directory.Exists(Path.Combine(root, "bin", "projects", projectName)), "Owned Create failure left project content.");

        var foreignProjectName = "foreign-file";
        var foreignPath = Path.Combine(root, "bin", "projects", foreignProjectName, "foreign.bin");
        lifecycle = new WorkspaceProjectLifecycleModel(phase =>
        {
            if (phase != WorkspaceProjectCreatePhase.AfterScene) return;
            File.WriteAllBytes(foreignPath, [9, 9, 9]);
            throw new IOException("injected foreign file failure");
        });
        await ExpectLifecycleFailureAsync(
            () => lifecycle.CreateAsync(new ProjectCreateParameters(root, foreignProjectName), default),
            WorkspaceProjectLifecycleFailureKind.Create);
        Require(File.Exists(foreignPath), "Owned cleanup removed a foreign file.");
        Require(!File.Exists(Path.Combine(Path.GetDirectoryName(foreignPath)!, "scene.json")), "Owned cleanup preserved an unchanged owned file.");

        var replacedProjectName = "replaced-owned-file";
        var replacedScenePath = Path.Combine(root, "bin", "projects", replacedProjectName, "scene.json");
        lifecycle = new WorkspaceProjectLifecycleModel(phase =>
        {
            if (phase != WorkspaceProjectCreatePhase.AfterScene) return;
            File.WriteAllText(replacedScenePath, "foreign replacement", Encoding.UTF8);
            throw new IOException("injected owned-file replacement");
        });
        await ExpectLifecycleFailureAsync(
            () => lifecycle.CreateAsync(new ProjectCreateParameters(root, replacedProjectName), default),
            WorkspaceProjectLifecycleFailureKind.Create);
        Require(File.ReadAllText(replacedScenePath, Encoding.UTF8) == "foreign replacement", "Owned cleanup removed a replaced file.");
    }

    private static async Task VerifyForeignOwnershipAsync(string root)
    {
        var projectName = "foreign-claim";
        var projectDirectory = Path.Combine(root, "bin", "projects", projectName);
        var claimPath = Path.Combine(projectDirectory, ".kadath-create-claim");
        var lifecycle = new WorkspaceProjectLifecycleModel(phase =>
        {
            if (phase != WorkspaceProjectCreatePhase.BeforeCommit) return;
            File.Delete(claimPath);
            File.WriteAllText(claimPath, "foreign-owner", Encoding.UTF8);
        });
        await ExpectLifecycleFailureAsync(
            () => lifecycle.CreateAsync(new ProjectCreateParameters(root, projectName), default),
            WorkspaceProjectLifecycleFailureKind.Invariant);
        Require(File.ReadAllText(claimPath, Encoding.UTF8) == "foreign-owner", "Cleanup removed a foreign ownership claim.");
        Require(File.Exists(Path.Combine(projectDirectory, "scene.json")), "Cleanup removed Scene content after ownership loss.");
        Require(File.Exists(Path.Combine(projectDirectory, "script.json")), "Cleanup removed Script content after ownership loss.");
        Require(File.Exists(Path.Combine(projectDirectory, "preview.json")), "Cleanup removed Preview content after ownership loss.");
    }

    private static async Task VerifyQuarantineRacesAsync(string root)
    {
        var replacedFileProjectName = "cleanup-quarantine-race";
        var replacedFileDirectory = Path.Combine(root, "bin", "projects", replacedFileProjectName);
        var replacedPreviewPath = Path.Combine(replacedFileDirectory, "preview.json");
        var replacedPreview = false;
        var lifecycle = new WorkspaceProjectLifecycleModel(
            phase =>
            {
                if (phase == WorkspaceProjectCreatePhase.AfterPreview) throw new IOException("injected cleanup failure");
            },
            (phase, path) =>
            {
                if (replacedPreview || phase != WorkspaceProjectCleanupPhase.BeforeOwnedFileQuarantine || path != replacedPreviewPath) return;
                replacedPreview = true;
                File.WriteAllText(path, "foreign replacement", Encoding.UTF8);
            });
        await ExpectLifecycleFailureAsync(
            () => lifecycle.CreateAsync(new ProjectCreateParameters(root, replacedFileProjectName), default),
            WorkspaceProjectLifecycleFailureKind.Create);
        Require(File.ReadAllText(replacedPreviewPath, Encoding.UTF8) == "foreign replacement", "Quarantine cleanup removed a file replaced after identity validation.");
        Require(!File.Exists(Path.Combine(replacedFileDirectory, "scene.json")), "Quarantine cleanup preserved unchanged owned Scene content.");
        Require(!File.Exists(Path.Combine(replacedFileDirectory, "script.json")), "Quarantine cleanup preserved unchanged owned Script content.");
        Require(!File.Exists(Path.Combine(replacedFileDirectory, ".kadath-create-claim")), "Quarantine cleanup left an unchanged ownership claim.");

        var replacedClaimProjectName = "claim-quarantine-race";
        var replacedClaimDirectory = Path.Combine(root, "bin", "projects", replacedClaimProjectName);
        var replacedClaimPath = Path.Combine(replacedClaimDirectory, ".kadath-create-claim");
        var replacedClaim = false;
        lifecycle = new WorkspaceProjectLifecycleModel(
            null,
            (phase, path) =>
            {
                if (replacedClaim || phase != WorkspaceProjectCleanupPhase.BeforeClaimQuarantine || path != replacedClaimPath) return;
                replacedClaim = true;
                File.WriteAllText(path, "foreign-owner", Encoding.UTF8);
            });
        await ExpectLifecycleFailureAsync(
            () => lifecycle.CreateAsync(new ProjectCreateParameters(root, replacedClaimProjectName), default),
            WorkspaceProjectLifecycleFailureKind.Invariant);
        Require(File.ReadAllText(replacedClaimPath, Encoding.UTF8) == "foreign-owner", "Claim quarantine removed a claim replaced after identity validation.");
        Require(File.Exists(Path.Combine(replacedClaimDirectory, "scene.json")), "Claim quarantine failure removed Scene content after ownership loss.");
        Require(File.Exists(Path.Combine(replacedClaimDirectory, "script.json")), "Claim quarantine failure removed Script content after ownership loss.");
        Require(File.Exists(Path.Combine(replacedClaimDirectory, "preview.json")), "Claim quarantine failure removed Preview content after ownership loss.");
    }

    private static async Task VerifyDirectoryReplacementAsync(string root)
    {
        if (OperatingSystem.IsWindows()) return;
        var packageRoot = Path.Combine(root, "directory-replacement-package");
        CreatePackage(packageRoot);
        var projectName = "directory-replacement";
        var projectDirectory = Path.Combine(packageRoot, "bin", "projects", projectName);
        var displacedDirectory = projectDirectory + ".owned";
        var foreignPath = Path.Combine(projectDirectory, "foreign.bin");
        var lifecycle = new WorkspaceProjectLifecycleModel(phase =>
        {
            if (phase != WorkspaceProjectCreatePhase.BeforeCommit) return;
            Directory.Move(projectDirectory, displacedDirectory);
            Directory.CreateDirectory(projectDirectory);
            File.WriteAllBytes(foreignPath, [7, 7, 7]);
        });
        await ExpectLifecycleFailureAsync(
            () => lifecycle.CreateAsync(new ProjectCreateParameters(packageRoot, projectName), default),
            WorkspaceProjectLifecycleFailureKind.Invariant);
        Require(File.ReadAllBytes(foreignPath).AsSpan().SequenceEqual(new byte[] { 7, 7, 7 }), "Directory replacement cleanup modified foreign content.");
        Require(File.Exists(Path.Combine(displacedDirectory, "scene.json")), "Directory replacement cleanup removed displaced owned Scene content.");
        Require(File.Exists(Path.Combine(displacedDirectory, "script.json")), "Directory replacement cleanup removed displaced owned Script content.");
        Require(File.Exists(Path.Combine(displacedDirectory, "preview.json")), "Directory replacement cleanup removed displaced owned Preview content.");
        Require(File.Exists(Path.Combine(displacedDirectory, ".kadath-create-claim")), "Directory replacement cleanup removed the displaced ownership claim.");
    }

    private static async Task VerifyCancellationAsync(string root)
    {
        using var beforeClaim = new CancellationTokenSource();
        beforeClaim.Cancel();
        await ExpectAsync<OperationCanceledException>(() => new WorkspaceProjectLifecycleModel().CreateAsync(new ProjectCreateParameters(root, "cancel-before"), beforeClaim.Token));
        Require(!Directory.Exists(Path.Combine(root, "bin", "projects", "cancel-before")), "Pre-cancelled Create changed the package.");

        using var afterClaim = new CancellationTokenSource();
        var lifecycle = new WorkspaceProjectLifecycleModel(phase =>
        {
            if (phase == WorkspaceProjectCreatePhase.AfterClaim) afterClaim.Cancel();
        });
        await ExpectAsync<OperationCanceledException>(() => lifecycle.CreateAsync(new ProjectCreateParameters(root, "cancel-after"), afterClaim.Token));
        Require(!Directory.Exists(Path.Combine(root, "bin", "projects", "cancel-after")), "Cancelled owned Create left project content.");
    }

    private static async Task VerifyCaseSensitiveContainmentAsync(
        string root,
        WorkspaceProjectLifecycleModel lifecycle,
        ProjectSessionInfo project)
    {
        if (!OperatingSystem.IsLinux()) return;

        var siblingRoot = Path.Combine(Path.GetDirectoryName(root)!, Path.GetFileName(root).ToUpperInvariant());
        var originalPreview = File.ReadAllBytes(project.PreviewPath);
        try
        {
            CreatePackage(siblingRoot);
            _ = await lifecycle.CreateAsync(new ProjectCreateParameters(siblingRoot, project.ProjectName), default);
            var escapedWorkingDirectory = Path.GetRelativePath(root, Path.Combine(siblingRoot, "bin")).Replace('\\', '/');
            File.WriteAllText(project.PreviewPath, JsonSerializer.Serialize(new
            {
                schemaVersion = 1,
                runtime = new
                {
                    executable = "bin/kadath",
                    workingDirectory = escapedWorkingDirectory,
                    arguments = new[]
                    {
                        "--scene",
                        $"projects/{project.ProjectName}/scene.json",
                        "--script",
                        $"projects/{project.ProjectName}/script.json"
                    }
                }
            }), Encoding.UTF8);

            await ExpectLifecycleFailureAsync(
                () => lifecycle.ValidateAsync(project, default),
                WorkspaceProjectLifecycleFailureKind.Validation);
        }
        finally
        {
            File.WriteAllBytes(project.PreviewPath, originalPreview);
            if (Directory.Exists(siblingRoot)) Directory.Delete(siblingRoot, recursive: true);
        }
    }

    private static async Task VerifyReparseBoundariesAsync(string root, WorkspaceProjectLifecycleModel lifecycle, ProjectSessionInfo project)
    {
        if (OperatingSystem.IsWindows()) return;
        var packageAlias = root + $".link-{Guid.NewGuid():N}";
        Directory.CreateSymbolicLink(packageAlias, root);
        try
        {
            await ExpectLifecycleFailureAsync(
                () => lifecycle.OpenAsync(new ProjectOpenParameters(packageAlias, project.ProjectName), default),
                WorkspaceProjectLifecycleFailureKind.Validation);
        }
        finally
        {
            Directory.Delete(packageAlias);
        }

        await VerifyDirectorySymlinkFailureAsync(
            Path.Combine(root, "bin"),
            () => lifecycle.OpenAsync(new ProjectOpenParameters(root, project.ProjectName), default));
        await VerifyDirectorySymlinkFailureAsync(
            Path.Combine(root, "bin", "projects"),
            () => lifecycle.OpenAsync(new ProjectOpenParameters(root, project.ProjectName), default));
        await VerifyDirectorySymlinkFailureAsync(
            project.ProjectDirectory,
            () => lifecycle.OpenAsync(new ProjectOpenParameters(root, project.ProjectName), default));

        await VerifyFileSymlinkFailureAsync(project.ScenePath, () => lifecycle.ValidateAsync(project, default));
        await VerifyFileSymlinkFailureAsync(project.ScriptPath, () => lifecycle.ValidateAsync(project, default));
        await VerifyFileSymlinkFailureAsync(project.PreviewPath, () => lifecycle.ValidateAsync(project, default));
        await VerifyFileSymlinkFailureAsync(Path.Combine(root, "bin", "kadath"), () => lifecycle.ValidateAsync(project, default));

        var sceneTemplate = Path.Combine(root, "bin", "assets", "scenes", "preview.scene.json");
        await VerifyFileSymlinkFailureAsync(
            sceneTemplate,
            () => lifecycle.CreateAsync(new ProjectCreateParameters(root, "scene-template-reparse"), default));
        var scriptTemplate = Path.Combine(root, "bin", "assets", "scripts", "preview.script.json");
        await VerifyFileSymlinkFailureAsync(
            scriptTemplate,
            () => lifecycle.CreateAsync(new ProjectCreateParameters(root, "script-template-reparse"), default));
        await VerifyDirectorySymlinkFailureAsync(
            Path.Combine(root, "bin", "assets", "scenes"),
            () => lifecycle.CreateAsync(new ProjectCreateParameters(root, "scene-template-directory-reparse"), default));
    }

    private static async Task VerifyFileSymlinkFailureAsync(string path, Func<Task> action)
    {
        var realPath = $"{path}.real-{Guid.NewGuid():N}";
        File.Move(path, realPath);
        File.CreateSymbolicLink(path, realPath);
        try
        {
            await ExpectLifecycleFailureAsync(action, WorkspaceProjectLifecycleFailureKind.Validation);
        }
        finally
        {
            File.Delete(path);
            File.Move(realPath, path);
        }
    }

    private static async Task VerifyDirectorySymlinkFailureAsync(string path, Func<Task> action)
    {
        var realPath = $"{path}.real-{Guid.NewGuid():N}";
        Directory.Move(path, realPath);
        Directory.CreateSymbolicLink(path, realPath);
        try
        {
            await ExpectLifecycleFailureAsync(action, WorkspaceProjectLifecycleFailureKind.Validation);
        }
        finally
        {
            Directory.Delete(path);
            Directory.Move(realPath, path);
        }
    }

    private static TemplateBytes CreatePackage(string root)
    {
        var scene = Encoding.UTF8.GetBytes("""
        {"schemaVersion":4,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"},{"textureId":2,"artifact":"assets/renderer2d/goal.texture"},{"textureId":3,"artifact":"assets/renderer2d/goal.texture"}],"objects":[{"objectId":"decoration-1","kind":"sprite","transform":{"position":[100,420]},"sprite":{"size":[80,80],"color":[0.45,0.65,1,0.8],"textureId":2}},{"objectId":"goal","kind":"goal","transform":{"position":[700,200]},"sprite":{"size":[96,96],"color":[1,0.75,0.1,1],"textureId":2}},{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[650,280]},"sprite":{"size":[96,96],"color":[0.95,0.2,0.2,1],"textureId":3},"patrol":{"minY":245,"maxY":330,"speed":80}},{"objectId":"hazard-2","kind":"patrol_hazard","transform":{"position":[500,420]},"sprite":{"size":[72,72],"color":[1,0.35,0.2,1],"textureId":3},"patrol":{"minY":380,"maxY":460,"speed":55}},{"objectId":"player","kind":"player","transform":{"position":[312,130]},"sprite":{"size":[320,240],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":180}}]}
        """);
        var script = Encoding.UTF8.GetBytes("""
        {"schemaVersion":1,"instructions":[{"hook":"on_start","op":"set_goal_position","value":[680,200]},{"hook":"fixed_update","op":"move_goal_velocity","value":[-12,0]}]}
        """);
        Directory.CreateDirectory(Path.Combine(root, "bin", "assets", "scenes"));
        Directory.CreateDirectory(Path.Combine(root, "bin", "assets", "scripts"));
        Directory.CreateDirectory(Path.Combine(root, "bin", "projects"));
        File.WriteAllBytes(Path.Combine(root, "bin", "assets", "scenes", "preview.scene.json"), scene);
        File.WriteAllBytes(Path.Combine(root, "bin", "assets", "scripts", "preview.script.json"), script);
        File.WriteAllBytes(Path.Combine(root, "bin", OperatingSystem.IsWindows() ? "kadath.exe" : "kadath"), [0]);
        return new TemplateBytes(scene, script);
    }

    private static async Task VerifyBehaviorProjectLifecycleAsync(string root)
    {
        var packageRoot = Path.Combine(root, "behavior-package");
        var productAssets = Path.Combine(Directory.GetCurrentDirectory(), "packaging", "linux-assets");
        var scene = File.ReadAllBytes(Path.Combine(productAssets, "preview.scene.json"));
        var script = File.ReadAllBytes(Path.Combine(productAssets, "preview.script.json"));
        var patrol = File.ReadAllBytes(Path.Combine(productAssets, "scripts", "patrol.luau"));
        Directory.CreateDirectory(Path.Combine(packageRoot, "bin", "assets", "scenes"));
        Directory.CreateDirectory(Path.Combine(packageRoot, "bin", "assets", "scripts"));
        Directory.CreateDirectory(Path.Combine(packageRoot, "bin", "projects"));
        File.WriteAllBytes(Path.Combine(packageRoot, "bin", "assets", "scenes", "preview.scene.json"), scene);
        File.WriteAllBytes(Path.Combine(packageRoot, "bin", "assets", "scripts", "preview.script.json"), script);
        var templateDependencyPath = Path.Combine(packageRoot, "bin", "assets", "scripts", "patrol.luau");
        File.WriteAllBytes(templateDependencyPath, patrol);
        File.WriteAllBytes(Path.Combine(packageRoot, "bin", OperatingSystem.IsWindows() ? "kadath.exe" : "kadath"), [0]);

        var lifecycle = new WorkspaceProjectLifecycleModel();
        var created = await lifecycle.CreateAsync(new ProjectCreateParameters(packageRoot, "behavior-created"), default);
        var createdDependencyPath = Path.Combine(created.ProjectDirectory, "scripts", "patrol.luau");
        Require(File.ReadAllBytes(created.ScenePath).AsSpan().SequenceEqual(scene), "Behavior Create did not preserve the Scene v5 template.");
        Require(File.ReadAllBytes(created.ScriptPath).AsSpan().SequenceEqual(script), "Behavior Create did not preserve the Script v2 manifest.");
        Require(File.ReadAllBytes(createdDependencyPath).AsSpan().SequenceEqual(patrol), "Behavior Create did not copy the declared Luau dependency.");
        Require(!File.Exists(Path.Combine(created.ProjectDirectory, ".kadath-create-claim")), "Behavior Create left an ownership claim.");
        using (var document = JsonDocument.Parse(File.ReadAllBytes(created.ScenePath)))
        {
            Require(document.RootElement.GetProperty("schemaVersion").GetInt32() == 5, "Behavior Create did not produce Scene v5.");
        }
        var sceneArtifact = WorkspaceSceneCodec.EncodeSource(File.ReadAllBytes(created.ScenePath));
        var sceneInfo = WorkspaceSceneCodec.ValidateArtifact(sceneArtifact);
        Require(sceneInfo.Format == "KSCN-SCENE-V5" && sceneInfo.ImporterVersion == 5 && sceneInfo.BakerVersion == 5,
            "Behavior Create Scene did not encode as KSCN v5.");
        Require(WorkspaceScriptDependencySet.ComputeRevision(created.ScriptPath).Length == 64,
            "Behavior Create Script dependency revision is invalid.");
        var readModel = new WorkspaceReadModel();
        var snapshot = await readModel.ReadProjectAsync(created, default);
        Require(snapshot.Scene.SchemaVersion == 5 && snapshot.Script.SchemaVersion == 2,
            "Behavior ReadModel did not preserve v5/v2 schema versions.");
        Require(snapshot.Script.Dependencies?.Single().Source == "scripts/patrol.luau",
            "Behavior ReadModel did not expose Script dependency metadata.");
        Require(snapshot.Scene.Objects?.Single(value => value.ObjectId == "hazard-1").Behaviors?.Single().ScriptId == 1,
            "Behavior ReadModel did not expose Scene behavior bindings.");
        var hierarchy = await readModel.ReadHierarchyAsync(created, default);
        Require(hierarchy.Nodes.Any(node => node.Kind == "ScriptDependency" && node.Id == "script.dependencies[1]"),
            "Behavior hierarchy did not expose Script dependency node.");
        Require(hierarchy.Nodes.Any(node => node.Kind == "SceneBehavior" && node.Id == "scene.objects[hazard-1].behaviors[1]"),
            "Behavior hierarchy did not expose Scene behavior node.");
        var authoring = new WorkspaceAuthoringModel();
        var editedObjects = snapshot.Scene.Objects!
            .Select(value => value.ObjectId == "hazard-1"
                ? value with
                {
                    Behaviors = value.Behaviors?.Select(binding => binding with
                    {
                        Parameters = binding.Parameters?.Select(parameter => parameter.Name == "speed"
                            ? parameter with { Value = 96 }
                            : parameter).ToArray()
                    }).ToArray()
                }
                : value)
            .Select(ToDefinition)
            .ToArray();
        var edit = await authoring.ApplyAsync(created, snapshot.AuthoringRevision,
            new AuthoringPatch(SceneObjects: editedObjects), default);
        Require(edit.State == "succeeded" && edit.ProjectSnapshot.Scene.SchemaVersion == 5
            && edit.ProjectSnapshot.Scene.Objects!.Single(value => value.ObjectId == "hazard-1").Behaviors!.Single().Parameters!.Single(value => value.Name == "speed").Value == 96,
            "Behavior Authoring did not preserve and update Scene v5 binding parameters.");
        using (var editedScene = JsonDocument.Parse(File.ReadAllBytes(created.ScenePath)))
        {
            Require(editedScene.RootElement.GetProperty("schemaVersion").GetInt32() == 5
                && editedScene.RootElement.GetProperty("objects")[2].GetProperty("behaviors")[0].GetProperty("parameters").GetProperty("speed").GetDouble() == 96,
                "Behavior Authoring serialized an invalid Scene v5 document.");
        }
        var undo = await authoring.UndoAsync(created, edit.Revision, edit.UndoToken!, default);
        Require(undo.State == "succeeded" && undo.ProjectSnapshot.Scene.Objects!.Single(value => value.ObjectId == "hazard-1").Behaviors!.Single().Parameters!.Single(value => value.Name == "speed").Value == 80,
            "Behavior Authoring undo did not restore the original binding parameters.");

        var sourceAuthoring = new WorkspaceScriptSourceAuthoringModel();
        var sourceDocument = await sourceAuthoring.ReadAsync(created, 1, default);
        Require(sourceDocument.SourcePath == "scripts/patrol.luau"
            && sourceDocument.Source == Encoding.UTF8.GetString(patrol)
            && sourceDocument.AuthoringRevision == undo.Revision,
            "Behavior source authoring read snapshot mismatch.");
        var editedSource = sourceDocument.Source + "\n-- editor-source-authoring\n";
        var sourceEdit = await sourceAuthoring.ApplyAsync(created, sourceDocument.AuthoringRevision, 1, editedSource, default);
        Require(sourceEdit.State == "succeeded"
            && sourceEdit.PreviousRevision == sourceDocument.AuthoringRevision
            && sourceEdit.Revision != sourceEdit.PreviousRevision
            && sourceEdit.ProjectSnapshot.AuthoringRevision == sourceEdit.Revision
            && File.ReadAllText(createdDependencyPath, Encoding.UTF8) == editedSource,
            "Behavior source authoring did not commit the Luau source atomically.");
        var unchangedSource = await sourceAuthoring.ApplyAsync(created, sourceEdit.Revision, 1, editedSource, default);
        Require(unchangedSource.State == "unchanged" && unchangedSource.Revision == sourceEdit.Revision && unchangedSource.UndoToken is null,
            "Behavior source authoring unchanged result mismatch.");
        await ExpectAuthoringFailureAsync(
            () => sourceAuthoring.ApplyAsync(created, sourceDocument.AuthoringRevision, 1, editedSource + "-- stale", default),
            WorkspaceAuthoringFailureKind.RevisionConflict);
        await ExpectAuthoringFailureAsync(
            () => sourceAuthoring.ApplyAsync(created, sourceEdit.Revision, 999, editedSource, default),
            WorkspaceAuthoringFailureKind.InvalidPatch);
        await ExpectAuthoringFailureAsync(
            () => sourceAuthoring.ApplyAsync(created, sourceEdit.Revision, 1, new string('x', 65537), default),
            WorkspaceAuthoringFailureKind.Input);
        File.WriteAllText(createdDependencyPath, editedSource + "-- external", new UTF8Encoding(false));
        await ExpectAuthoringFailureAsync(
            () => sourceAuthoring.UndoAsync(created, sourceEdit.Revision, sourceEdit.UndoToken!, default),
            WorkspaceAuthoringFailureKind.RevisionConflict);
        File.WriteAllText(createdDependencyPath, editedSource, new UTF8Encoding(false));
        var sourceUndo = await sourceAuthoring.UndoAsync(created, sourceEdit.Revision, sourceEdit.UndoToken!, default);
        Require(sourceUndo.State == "succeeded"
            && sourceUndo.Revision == sourceDocument.AuthoringRevision
            && File.ReadAllBytes(createdDependencyPath).AsSpan().SequenceEqual(patrol)
            && !Directory.EnumerateFiles(Path.GetDirectoryName(createdDependencyPath)!, "*.authoring.*").Any(),
            "Behavior source authoring undo or temporary-file cleanup mismatch.");
        Require(await lifecycle.OpenAsync(new ProjectOpenParameters(packageRoot, "behavior-created"), default) == created,
            "Behavior Open did not preserve project identity.");
        var validation = await lifecycle.ValidateAsync(created, default);
        Require(validation.State == "valid", "Behavior project validation failed.");

        var cleanupProjectDirectory = Path.Combine(packageRoot, "bin", "projects", "behavior-cleanup");
        var cleanupLifecycle = new WorkspaceProjectLifecycleModel(phase =>
        {
            if (phase == WorkspaceProjectCreatePhase.AfterScriptDependencies) throw new IOException("injected dependency cleanup failure");
        });
        await ExpectLifecycleFailureAsync(
            () => cleanupLifecycle.CreateAsync(new ProjectCreateParameters(packageRoot, "behavior-cleanup"), default),
            WorkspaceProjectLifecycleFailureKind.Create);
        Require(!Directory.Exists(cleanupProjectDirectory), "Behavior Create failure left dependency files or directories.");

        File.Delete(templateDependencyPath);
        await ExpectLifecycleFailureAsync(
            () => lifecycle.CreateAsync(new ProjectCreateParameters(packageRoot, "behavior-missing-source"), default),
            WorkspaceProjectLifecycleFailureKind.Validation);
        Require(!Directory.Exists(Path.Combine(packageRoot, "bin", "projects", "behavior-missing-source")),
            "Missing Script template dependency created a partial project.");
    }

    private static async Task ExpectLifecycleFailureAsync(Func<Task> action, WorkspaceProjectLifecycleFailureKind kind)
    {
        try { await action(); }
        catch (WorkspaceProjectLifecycleException exception) when (exception.Kind == kind) { return; }
        throw new InvalidOperationException($"Expected WorkspaceProjectLifecycleException with kind {kind}.");
    }

    private static async Task ExpectAuthoringFailureAsync(Func<Task> action, WorkspaceAuthoringFailureKind kind)
    {
        try { await action(); }
        catch (WorkspaceAuthoringException exception) when (exception.Kind == kind) { return; }
        throw new InvalidOperationException($"Expected WorkspaceAuthoringException with kind {kind}.");
    }

    private static SceneObjectDefinition ToDefinition(ProjectModelSceneObject value) => new(
        value.ObjectId,
        value.Kind,
        value.Position,
        value.Size,
        value.Color,
        value.TextureId,
        value.MoveSpeed,
        value.PatrolMinY,
        value.PatrolMaxY,
        value.PatrolSpeed,
        value.Behaviors?.Select(binding => new SceneBehaviorBindingDefinition(
            binding.ScriptId,
            binding.Parameters?.ToDictionary(parameter => parameter.Name, parameter => parameter.Value, StringComparer.Ordinal))).ToArray());

    private static async Task ExpectAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static string TreeIdentity(string root)
    {
        var files = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
            .OrderBy(path => path, StringComparer.Ordinal)
            .Select(path => $"{Path.GetRelativePath(root, path).Replace('\\', '/')}:{Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(path)))}");
        return string.Join("\n", files);
    }

    private static string AddRootProperty(string json, string property)
    {
        var end = json.LastIndexOf('}');
        if (end < 0) throw new InvalidOperationException("JSON fixture has no root closing brace.");
        return json.Insert(end, $",{property}");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed record TemplateBytes(byte[] Scene, byte[] Script);
}
