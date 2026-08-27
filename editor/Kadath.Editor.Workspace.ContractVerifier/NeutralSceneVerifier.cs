using System.Buffers.Binary;
using System.Text;
using Kadath.Editor.Protocol;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Workspace.ContractVerifier;

internal static class NeutralSceneVerifier
{
    internal static async Task VerifyAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), $"kadath-neutral-scene-{Guid.NewGuid():N}");
        try
        {
            var project = CreateProject(root);
            var readModel = new WorkspaceReadModel();
            var initial = await readModel.ReadProjectAsync(project, default);
            Require(initial.Scene.SchemaVersion == 7
                && initial.Scene.GameplayProfile == "none"
                && initial.Scene.GoalPosition.Length == 0
                && initial.Scene.Objects is [{ ObjectId: "decor" }],
                "Neutral Scene v7 projection mismatch.");

            var originalScene = File.ReadAllBytes(project.ScenePath);
            var decor = initial.Scene.Objects![0];
            var authoring = new WorkspaceAuthoringModel();
            var commit = await authoring.ApplyAsync(project, initial.AuthoringRevision, new AuthoringPatch(SceneObjects:
            [
                new SceneObjectDefinition(
                    decor.ObjectId,
                    decor.Kind,
                    [30, 40],
                    decor.Size,
                    decor.Color,
                    decor.TextureId,
                    Behaviors: decor.Behaviors?.Select(binding => new SceneBehaviorBindingDefinition(
                        binding.ScriptId,
                        binding.Parameters?.ToDictionary(parameter => parameter.Name, parameter => parameter.Value, StringComparer.Ordinal))).ToArray())
            ]), default);
            Require(commit.ChangedFields.SequenceEqual(["scene.objects"])
                && commit.ProjectSnapshot.Scene.Objects![0].Position.SequenceEqual([30, 40]),
                "Neutral Scene authoring commit mismatch.");
            var editedScene = File.ReadAllBytes(project.ScenePath);
            var undone = await authoring.UndoAsync(project, commit.Revision, commit.UndoToken!, default);
            Require(undone.ProjectSnapshot.Scene.Objects![0].Position.SequenceEqual([10, 20])
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Neutral Scene authoring undo was not byte-exact.");
            var redone = await authoring.UndoAsync(project, undone.Revision, undone.UndoToken!, default);
            Require(redone.ProjectSnapshot.Scene.Objects![0].Position.SequenceEqual([30, 40])
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(editedScene),
                "Neutral Scene authoring redo did not restore the edited state.");
            undone = await authoring.UndoAsync(project, redone.Revision, redone.UndoToken!, default);
            Require(File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Neutral Scene second undo was not byte-exact.");

            var artifact = WorkspaceSceneCodec.EncodeSource(originalScene);
            var info = WorkspaceSceneCodec.ValidateArtifact(artifact);
            Require(BinaryPrimitives.ReadUInt32LittleEndian(artifact.AsSpan(4, 4)) == 7
                && info.Format == "KSCN-SCENE-V7",
                "Neutral Scene bake did not produce KSCN v7.");

            var preview = new WorkspacePreviewModel(new WorkspacePublicationModel());
            var plan = await preview.PrepareAsync(new PreviewStartParameters(
                ConfigPath: project.PreviewPath,
                PackageRoot: root,
                ProjectName: project.ProjectName,
                LiveBake: true), default);
            Require(plan.InitialBake is { State: "succeeded" }
                && plan.RuntimeArguments.Contains("projects/neutral/.kadath/derived/scene.scene", StringComparer.Ordinal)
                && File.Exists(Path.Combine(project.ProjectDirectory, ".kadath", "derived", "scene.scene")),
                "Neutral Scene Live Bake preview plan mismatch.");
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    private static ProjectSessionInfo CreateProject(string root)
    {
        var projectDirectory = Path.Combine(root, "bin", "projects", "neutral");
        Directory.CreateDirectory(projectDirectory);
        Directory.CreateDirectory(Path.Combine(root, "bin", "assets", "renderer2d"));
        File.WriteAllBytes(Path.Combine(root, VerifierPlatform.RuntimeRelativePath), [0]);
        File.WriteAllText(Path.Combine(projectDirectory, "scene.json"), SceneJson, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "script.json"), ScriptJson, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "preview.json"), $$$"""
        {"schemaVersion":1,"runtime":{"executable":"{{{VerifierPlatform.RuntimeRelativePath}}}","workingDirectory":"bin","arguments":["--scene","projects/neutral/scene.json","--script","projects/neutral/script.json"]}}
        """, new UTF8Encoding(false));
        return new ProjectSessionInfo(root, "neutral", projectDirectory,
            Path.Combine(projectDirectory, "scene.json"),
            Path.Combine(projectDirectory, "script.json"),
            Path.Combine(projectDirectory, "preview.json"), 1);
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private const string SceneJson = """
    {
      "schemaVersion": 7,
      "textures": [
        { "textureId": 1, "artifact": "assets/renderer2d/test.texture" }
      ],
      "objects": [
        { "objectId": "decor", "kind": "sprite", "transform": { "position": [10, 20] }, "sprite": { "size": [16, 16], "color": [1, 1, 1, 1], "textureId": 1 }, "behaviors": [] }
      ],
      "prototypes": []
    }
    """;

    private const string ScriptJson = """
    {
      "schemaVersion": 1,
      "instructions": [
        { "hook": "on_start", "op": "set_goal_position", "value": [0, 0] },
        { "hook": "fixed_update", "op": "move_goal_velocity", "value": [0, 0] }
      ]
    }
    """;
}
