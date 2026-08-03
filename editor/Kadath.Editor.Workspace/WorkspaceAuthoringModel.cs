using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

public enum WorkspaceAuthoringFailureKind
{
    InvalidExpectedRevision,
    RevisionConflict,
    InvalidPatch,
    Input,
    Commit,
    Invariant
}

public sealed class WorkspaceAuthoringException : Exception
{
    public WorkspaceAuthoringException(WorkspaceAuthoringFailureKind kind, string message, Exception? innerException = null)
        : base(message, innerException) => Kind = kind;

    public WorkspaceAuthoringFailureKind Kind { get; }
}

public sealed record WorkspaceAuthoringCommit(
    string State,
    string PreviousRevision,
    string Revision,
    string[] ChangedFields,
    AuthoringPatch? InversePatch,
    ProjectModelSnapshot ProjectSnapshot,
    HierarchySnapshot HierarchySnapshot);

public sealed class WorkspaceAuthoringModel
{
    private static readonly JsonSerializerOptions AuthoringJsonOptions = new(EditorProtocol.JsonOptions) { WriteIndented = true };
    private readonly Action? _beforeCommitValidation;
    private readonly Action<int>? _beforeReplace;

    public WorkspaceAuthoringModel() { }

    internal WorkspaceAuthoringModel(Action? beforeCommitValidation, Action<int>? beforeReplace)
    {
        _beforeCommitValidation = beforeCommitValidation;
        _beforeReplace = beforeReplace;
    }

    public Task<WorkspaceAuthoringCommit> ApplyAsync(
        ProjectSessionInfo project,
        string expectedRevision,
        AuthoringPatch? patch,
        CancellationToken cancellationToken) =>
        Task.FromResult(Execute(() => ApplyCore(project, expectedRevision, patch, cancellationToken), cancellationToken));

    private WorkspaceAuthoringCommit ApplyCore(
        ProjectSessionInfo project,
        string expectedRevision,
        AuthoringPatch? patch,
        CancellationToken cancellationToken)
    {
        ValidateExpectedRevision(expectedRevision);
        var original = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
        if (original.Scene.Length > 65536 || original.Script.Length > 65536)
        {
            throw Failure(WorkspaceAuthoringFailureKind.Input, "Authoring source exceeds the 64 KiB Runtime document budget.");
        }
        var current = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, original);
        if (!expectedRevision.Equals(current.Project.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
        {
            throw Failure(WorkspaceAuthoringFailureKind.RevisionConflict,
                $"Expected {expectedRevision} but current revision is {current.Project.AuthoringRevision}.");
        }

        var normalized = NormalizePatch(current.Project, patch);
        if (normalized.ChangedFields.Length == 0)
        {
            return new WorkspaceAuthoringCommit("unchanged", current.Project.AuthoringRevision, current.Project.AuthoringRevision,
                [], null, current.Project, current.Hierarchy);
        }

        var scene = ParseObject(original.Scene, "Scene");
        var script = ParseObject(original.Script, "Script");
        ApplyPatch(scene, script, normalized.Patch);
        var sceneBytes = normalized.SceneChanged ? Serialize(scene) : original.Scene;
        var scriptBytes = normalized.ScriptChanged ? Serialize(script) : original.Script;
        if (sceneBytes.Length > 65536 || scriptBytes.Length > 65536)
        {
            throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "Authoring result exceeds the 64 KiB Runtime document budget.");
        }
        var intended = original with { Scene = sceneBytes, Script = scriptBytes };
        WorkspaceProjectProjection committed;
        try { committed = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, intended); }
        catch (WorkspaceReadException exception)
        {
            throw Failure(exception.Kind == WorkspaceReadFailureKind.Invariant ? WorkspaceAuthoringFailureKind.Invariant : WorkspaceAuthoringFailureKind.InvalidPatch,
                exception.Message, exception);
        }

        Commit(project, original, intended, normalized.SceneChanged, normalized.ScriptChanged, cancellationToken);
        return new WorkspaceAuthoringCommit("succeeded", current.Project.AuthoringRevision, committed.Project.AuthoringRevision,
            normalized.ChangedFields, normalized.InversePatch, committed.Project, committed.Hierarchy);
    }

    private static T Execute<T>(Func<T> operation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try { return operation(); }
        catch (OperationCanceledException) { throw; }
        catch (WorkspaceAuthoringException) { throw; }
        catch (WorkspaceReadException exception)
        {
            throw Failure(exception.Kind == WorkspaceReadFailureKind.Invariant ? WorkspaceAuthoringFailureKind.Invariant : WorkspaceAuthoringFailureKind.Input,
                exception.Message, exception);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or FormatException or OverflowException)
        {
            throw Failure(WorkspaceAuthoringFailureKind.Input, exception.Message, exception);
        }
    }

    private void Commit(
        ProjectSessionInfo project,
        WorkspaceProjectBytes original,
        WorkspaceProjectBytes intended,
        bool sceneChanged,
        bool scriptChanged,
        CancellationToken cancellationToken)
    {
        var entries = new List<TransactionEntry>();
        var committedCount = 0;
        var attemptedIndex = -1;
        try
        {
            if (sceneChanged) entries.Add(Stage(original.ScenePath, original.Scene, intended.Scene, cancellationToken));
            if (scriptChanged) entries.Add(Stage(original.ScriptPath, original.Script, intended.Script, cancellationToken));
            _beforeCommitValidation?.Invoke();
            var latest = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
            if (!latest.Scene.AsSpan().SequenceEqual(original.Scene) || !latest.Script.AsSpan().SequenceEqual(original.Script))
            {
                throw Failure(WorkspaceAuthoringFailureKind.RevisionConflict, "Authoring sources changed while the transaction was staged.");
            }
            cancellationToken.ThrowIfCancellationRequested();

            for (var index = 0; index < entries.Count; index++)
            {
                attemptedIndex = index;
                _beforeReplace?.Invoke(index);
                File.Move(entries[index].StagedPath, entries[index].TargetPath, true);
                committedCount++;
            }
        }
        catch (OperationCanceledException) when (committedCount == 0)
        {
            throw;
        }
        catch (WorkspaceAuthoringException exception) when (committedCount == 0 && exception.Kind == WorkspaceAuthoringFailureKind.RevisionConflict)
        {
            throw;
        }
        catch (Exception commitException)
        {
            var rollbackFailures = Rollback(entries, committedCount, attemptedIndex);
            if (rollbackFailures.Count > 0)
            {
                throw Failure(WorkspaceAuthoringFailureKind.Invariant,
                    $"Authoring commit failed: {commitException.Message}; rollback failed: {string.Join(" | ", rollbackFailures.Select(value => value.Message))}",
                    new AggregateException(new[] { commitException }.Concat(rollbackFailures)));
            }
            throw Failure(WorkspaceAuthoringFailureKind.Commit, $"Authoring commit failed and the original sources were restored: {commitException.Message}", commitException);
        }
        finally
        {
            foreach (var entry in entries)
            {
                DeleteTemporary(entry.StagedPath);
                DeleteTemporary(entry.RecoveryPath);
            }
        }
    }

    private static TransactionEntry Stage(string targetPath, byte[] original, byte[] intended, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var token = Guid.NewGuid().ToString("N");
        var stagedPath = $"{targetPath}.authoring.{token}.stage";
        var recoveryPath = $"{targetPath}.authoring.{token}.recovery";
        try
        {
            WriteNewFile(stagedPath, intended);
            WriteNewFile(recoveryPath, original);
            return new TransactionEntry(targetPath, stagedPath, recoveryPath, intended);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            DeleteTemporary(stagedPath);
            DeleteTemporary(recoveryPath);
            throw Failure(WorkspaceAuthoringFailureKind.Commit, $"Failed to stage authoring source {targetPath}: {exception.Message}", exception);
        }
    }

    private static List<Exception> Rollback(IReadOnlyList<TransactionEntry> entries, int committedCount, int attemptedIndex)
    {
        var failures = new List<Exception>();
        for (var index = 0; index < entries.Count; index++)
        {
            var entry = entries[index];
            var needsRestore = index < committedCount;
            if (!needsRestore && index == attemptedIndex)
            {
                try { needsRestore = File.Exists(entry.TargetPath) && File.ReadAllBytes(entry.TargetPath).AsSpan().SequenceEqual(entry.Intended); }
                catch (Exception exception) { failures.Add(exception); continue; }
            }
            if (!needsRestore) continue;
            try { File.Move(entry.RecoveryPath, entry.TargetPath, true); }
            catch (Exception exception) { failures.Add(exception); }
        }
        return failures;
    }

    private static void WriteNewFile(string path, byte[] bytes)
    {
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough);
        stream.Write(bytes);
        stream.Flush(true);
    }

    private static void DeleteTemporary(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { }
    }

    private static NormalizedPatch NormalizePatch(ProjectModelSnapshot current, AuthoringPatch? patch)
    {
        if (patch is null) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "Authoring patch is required.");
        ValidateVector(patch.SceneGoalPosition, "scene.goal.position");
        ValidateVector(patch.ScriptGoalPosition, "script.goal.position");
        ValidateVector(patch.ScriptGoalVelocity, "script.goal.velocity");
        ValidateTextureId(current.Scene, patch.ScenePlayerTextureId, "scene.player.textureId");
        ValidateTextureId(current.Scene, patch.SceneGoalTextureId, "scene.goal.textureId");
        ValidateTextureId(current.Scene, patch.SceneHazardTextureId, "scene.hazard.textureId");
        var provided = patch.SceneGoalPosition is not null || patch.ScriptGoalPosition is not null || patch.ScriptGoalVelocity is not null
            || patch.ScenePlayerTextureId is not null || patch.SceneGoalTextureId is not null || patch.SceneHazardTextureId is not null;
        if (!provided) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "At least one authoring field is required.");

        var sceneGoal = Changed(patch.SceneGoalPosition, current.Scene.GoalPosition) ? patch.SceneGoalPosition : null;
        var scriptGoal = Changed(patch.ScriptGoalPosition, current.Script.GoalPosition) ? patch.ScriptGoalPosition : null;
        var velocity = Changed(patch.ScriptGoalVelocity, current.Script.GoalVelocity) ? patch.ScriptGoalVelocity : null;
        var playerTexture = patch.ScenePlayerTextureId is not null && patch.ScenePlayerTextureId != current.Scene.PlayerTextureId ? patch.ScenePlayerTextureId : null;
        var goalTexture = patch.SceneGoalTextureId is not null && patch.SceneGoalTextureId != current.Scene.GoalTextureId ? patch.SceneGoalTextureId : null;
        var hazardTexture = patch.SceneHazardTextureId is not null && patch.SceneHazardTextureId != current.Scene.HazardTextureId ? patch.SceneHazardTextureId : null;
        var normalized = new AuthoringPatch(sceneGoal, scriptGoal, velocity, playerTexture, goalTexture, hazardTexture);
        var fields = ChangedFields(normalized);
        if (fields.Length == 0) return new NormalizedPatch(normalized, null, [], false, false);
        var inverse = new AuthoringPatch(
            sceneGoal is null ? null : current.Scene.GoalPosition.ToArray(),
            scriptGoal is null ? null : current.Script.GoalPosition.ToArray(),
            velocity is null ? null : current.Script.GoalVelocity.ToArray(),
            playerTexture is null ? null : current.Scene.PlayerTextureId,
            goalTexture is null ? null : current.Scene.GoalTextureId,
            hazardTexture is null ? null : current.Scene.HazardTextureId);
        return new NormalizedPatch(normalized, inverse, fields,
            sceneGoal is not null || playerTexture is not null || goalTexture is not null || hazardTexture is not null,
            scriptGoal is not null || velocity is not null);
    }

    private static void ApplyPatch(JsonObject scene, JsonObject script, AuthoringPatch patch)
    {
        var player = RequireObject(scene, "player", "Scene");
        var goal = RequireObject(scene, "goal", "Scene");
        var hazard = RequireObject(scene, "hazard", "Scene");
        if (patch.SceneGoalPosition is not null) goal["position"] = Vector(patch.SceneGoalPosition);
        if (patch.ScenePlayerTextureId is not null) player["textureId"] = patch.ScenePlayerTextureId.Value;
        if (patch.SceneGoalTextureId is not null) goal["textureId"] = patch.SceneGoalTextureId.Value;
        if (patch.SceneHazardTextureId is not null) hazard["textureId"] = patch.SceneHazardTextureId.Value;
        if (patch.ScriptGoalPosition is not null) RequireInstruction(script, "on_start", "set_goal_position")["value"] = Vector(patch.ScriptGoalPosition);
        if (patch.ScriptGoalVelocity is not null) RequireInstruction(script, "fixed_update", "move_goal_velocity")["value"] = Vector(patch.ScriptGoalVelocity);
    }

    private static JsonObject ParseObject(byte[] bytes, string name)
    {
        try
        {
            var offset = bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble) ? Encoding.UTF8.Preamble.Length : 0;
            return JsonNode.Parse(bytes.AsSpan(offset))?.AsObject() ?? throw Failure(WorkspaceAuthoringFailureKind.Input, $"{name} JSON root is missing.");
        }
        catch (JsonException exception) { throw Failure(WorkspaceAuthoringFailureKind.Input, $"Failed to parse {name}: {exception.Message}", exception); }
        catch (InvalidOperationException exception) { throw Failure(WorkspaceAuthoringFailureKind.Input, $"{name} JSON root must be an object.", exception); }
    }

    private static JsonObject RequireObject(JsonObject owner, string name, string context) =>
        owner[name] as JsonObject ?? throw Failure(WorkspaceAuthoringFailureKind.Invariant, $"{context}.{name} is not an object after validation.");

    private static JsonObject RequireInstruction(JsonObject script, string hook, string operation)
    {
        var instructions = script["instructions"] as JsonArray
            ?? throw Failure(WorkspaceAuthoringFailureKind.Invariant, "Script.instructions is not an array after validation.");
        var matches = instructions.OfType<JsonObject>().Where(value =>
            value["hook"]?.GetValue<string>() == hook && value["op"]?.GetValue<string>() == operation).ToArray();
        return matches.Length == 1 ? matches[0] : throw Failure(WorkspaceAuthoringFailureKind.Invariant, $"Script instruction {hook}/{operation} changed after validation.");
    }

    private static JsonArray Vector(IEnumerable<double> values) => new(values.Select(value => (JsonNode?)JsonValue.Create(value)).ToArray());
    private static byte[] Serialize(JsonObject value) => Encoding.UTF8.GetBytes(value.ToJsonString(AuthoringJsonOptions));
    private static bool Changed(double[]? requested, double[] current) => requested is not null && !requested.SequenceEqual(current);

    private static string[] ChangedFields(AuthoringPatch patch)
    {
        var fields = new List<string>();
        if (patch.SceneGoalPosition is not null) fields.Add("scene.goal.position");
        if (patch.ScriptGoalPosition is not null) fields.Add("script.goal.position");
        if (patch.ScriptGoalVelocity is not null) fields.Add("script.goal.velocity");
        if (patch.ScenePlayerTextureId is not null) fields.Add("scene.player.textureId");
        if (patch.SceneGoalTextureId is not null) fields.Add("scene.goal.textureId");
        if (patch.SceneHazardTextureId is not null) fields.Add("scene.hazard.textureId");
        return fields.ToArray();
    }

    private static void ValidateExpectedRevision(string expectedRevision)
    {
        if (string.IsNullOrWhiteSpace(expectedRevision) || expectedRevision.Length != 64 || expectedRevision.Any(value => !Uri.IsHexDigit(value)))
        {
            throw Failure(WorkspaceAuthoringFailureKind.InvalidExpectedRevision, "ExpectedRevision must be a SHA-256 hex value.");
        }
    }

    private static void ValidateVector(double[]? vector, string field)
    {
        if (vector is not null && (vector.Length != 2 || vector.Any(value => !double.IsFinite(value))))
        {
            throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, $"{field} must contain two finite values.");
        }
    }

    private static void ValidateTextureId(ProjectModelScene scene, uint? value, string field)
    {
        if (value is not null && value == 0) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, $"{field} must be a non-zero TextureId.");
        if (value is not null && scene.Textures is { Count: > 0 } && !scene.Textures.Any(texture => texture.TextureId == value))
        {
            throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, $"{field} must reference a TextureId declared by the Scene texture set.");
        }
    }

    private static WorkspaceAuthoringException Failure(WorkspaceAuthoringFailureKind kind, string message, Exception? inner = null) => new(kind, message, inner);

    private sealed record NormalizedPatch(AuthoringPatch Patch, AuthoringPatch? InversePatch, string[] ChangedFields, bool SceneChanged, bool ScriptChanged);
    private sealed record TransactionEntry(string TargetPath, string StagedPath, string RecoveryPath, byte[] Intended);
}
