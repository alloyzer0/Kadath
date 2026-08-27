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
    WorkspaceAuthoringUndoToken? UndoToken,
    ProjectModelSnapshot ProjectSnapshot,
    HierarchySnapshot HierarchySnapshot);

public sealed class WorkspaceAuthoringUndoToken
{
    internal WorkspaceAuthoringUndoToken(
        string projectName,
        string revisionAfter,
        byte[] scene,
        byte[] script,
        bool sceneChanged,
        bool scriptChanged)
    {
        ProjectName = projectName;
        RevisionAfter = revisionAfter;
        Scene = scene.ToArray();
        Script = script.ToArray();
        SceneChanged = sceneChanged;
        ScriptChanged = scriptChanged;
    }

    internal string ProjectName { get; }
    internal string RevisionAfter { get; }
    internal byte[] Scene { get; }
    internal byte[] Script { get; }
    internal bool SceneChanged { get; }
    internal bool ScriptChanged { get; }
}

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

    public Task<WorkspaceAuthoringCommit> UndoAsync(
        ProjectSessionInfo project,
        string expectedRevision,
        WorkspaceAuthoringUndoToken token,
        CancellationToken cancellationToken) =>
        Task.FromResult(Execute(() => UndoCore(project, expectedRevision, token, cancellationToken), cancellationToken));

    private WorkspaceAuthoringCommit ApplyCore(
        ProjectSessionInfo project,
        string expectedRevision,
        AuthoringPatch? patch,
        CancellationToken cancellationToken)
    {
        ValidateExpectedRevision(expectedRevision);
        var original = WorkspaceProjectValidator.ReadAndValidate(project, cancellationToken);
        var current = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, original);
        if (!expectedRevision.Equals(current.Project.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
        {
            throw Failure(WorkspaceAuthoringFailureKind.RevisionConflict,
                $"Expected {expectedRevision} but current revision is {current.Project.AuthoringRevision}.");
        }

        var assets = patch?.SceneTextures is not null ? WorkspaceReadModel.ReadAssetsCore(project, cancellationToken) : null;
        var normalized = NormalizePatch(current.Project, assets, patch);
        if (normalized.ChangedFields.Length == 0)
        {
            return new WorkspaceAuthoringCommit("unchanged", current.Project.AuthoringRevision, current.Project.AuthoringRevision,
                [], null, current.Project, current.Hierarchy);
        }

        ValidateBehaviorContractChanges(project, current.Project, normalized, cancellationToken);

        var script = ParseObject(original.Script, "Script");
        var sceneBytes = normalized.SceneChanged ? BuildSceneBytes(original.Scene, normalized) : original.Scene;
        ApplyScriptPatch(script, normalized.Patch);
        var scriptBytes = normalized.ScriptChanged ? Serialize(script) : original.Script;
        if (sceneBytes.Length > 65536 || scriptBytes.Length > 65536)
        {
            throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "Authoring result exceeds the 64 KiB Runtime document budget.");
        }
        var intended = original with { Scene = sceneBytes, Script = scriptBytes };
        WorkspaceProjectProjection committed;
        try
        {
            WorkspaceProjectValidator.ValidateBytes(project, intended, cancellationToken);
            committed = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, intended);
        }
        catch (WorkspaceProjectValidationException exception)
        {
            throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, exception.Message, exception);
        }
        catch (WorkspaceReadException exception)
        {
            throw Failure(exception.Kind == WorkspaceReadFailureKind.Invariant ? WorkspaceAuthoringFailureKind.Invariant : WorkspaceAuthoringFailureKind.InvalidPatch,
                exception.Message, exception);
        }

        Commit(project, original, intended, normalized.SceneChanged, normalized.ScriptChanged, cancellationToken);
        var undoToken = new WorkspaceAuthoringUndoToken(
            project.ProjectName,
            committed.Project.AuthoringRevision,
            original.Scene,
            original.Script,
            normalized.SceneChanged,
            normalized.ScriptChanged);
        return new WorkspaceAuthoringCommit("succeeded", current.Project.AuthoringRevision, committed.Project.AuthoringRevision,
            normalized.ChangedFields, undoToken, committed.Project, committed.Hierarchy);
    }

    private WorkspaceAuthoringCommit UndoCore(
        ProjectSessionInfo project,
        string expectedRevision,
        WorkspaceAuthoringUndoToken token,
        CancellationToken cancellationToken)
    {
        ValidateExpectedRevision(expectedRevision);
        ArgumentNullException.ThrowIfNull(token);
        var currentBytes = WorkspaceProjectValidator.ReadAndValidate(project, cancellationToken);
        var current = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, currentBytes);
        if (!expectedRevision.Equals(current.Project.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
        {
            throw Failure(WorkspaceAuthoringFailureKind.RevisionConflict,
                $"Expected {expectedRevision} but current revision is {current.Project.AuthoringRevision}.");
        }
        if (!string.Equals(token.ProjectName, project.ProjectName, StringComparison.OrdinalIgnoreCase)
            || !string.Equals(token.RevisionAfter, current.Project.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
        {
            throw Failure(WorkspaceAuthoringFailureKind.Invariant, "Authoring undo token does not match the current project revision.");
        }
        var intended = currentBytes with
        {
            Scene = token.SceneChanged ? token.Scene.ToArray() : currentBytes.Scene,
            Script = token.ScriptChanged ? token.Script.ToArray() : currentBytes.Script
        };
        WorkspaceProjectProjection restored;
        try
        {
            WorkspaceProjectValidator.ValidateBytes(project, intended, cancellationToken);
            restored = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, intended);
        }
        catch (WorkspaceProjectValidationException exception)
        {
            throw Failure(WorkspaceAuthoringFailureKind.Invariant, "Authoring undo token contains invalid source bytes.", exception);
        }
        catch (WorkspaceReadException exception)
        {
            throw Failure(WorkspaceAuthoringFailureKind.Invariant, "Authoring undo token cannot be projected.", exception);
        }
        Commit(project, currentBytes, intended, token.SceneChanged, token.ScriptChanged, cancellationToken);
        // 恢复前的当前字节就是反向恢复令牌；Undo 与 Redo 共用同一事务实现。
        var inverseToken = new WorkspaceAuthoringUndoToken(
            project.ProjectName,
            restored.Project.AuthoringRevision,
            currentBytes.Scene,
            currentBytes.Script,
            token.SceneChanged,
            token.ScriptChanged);
        return new WorkspaceAuthoringCommit("succeeded", current.Project.AuthoringRevision, restored.Project.AuthoringRevision,
            [], inverseToken, restored.Project, restored.Hierarchy);
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
        catch (WorkspaceProjectValidationException exception)
        {
            throw Failure(WorkspaceAuthoringFailureKind.Input, exception.Message, exception);
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

    private static NormalizedPatch NormalizePatch(ProjectModelSnapshot current, AssetCatalogSnapshot? assets, AuthoringPatch? patch)
    {
        if (patch is null) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "Authoring patch is required.");
        var gameplay = GameplayFromSnapshot(current.Scene);
        ValidateVector(patch.SceneGoalPosition, "scene.goal.position");
        ValidateVector(patch.ScriptGoalPosition, "script.goal.position");
        ValidateVector(patch.ScriptGoalVelocity, "script.goal.velocity");
        if (patch.SceneObjects is not null && (patch.SceneGoalPosition is not null || patch.ScenePlayerTextureId is not null
            || patch.SceneGoalTextureId is not null || patch.SceneHazardTextureId is not null))
        {
            throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "sceneObjects cannot be combined with fixed Scene fields.");
        }
        if (!gameplay.IsEnabled && (patch.SceneGoalPosition is not null || patch.ScenePlayerTextureId is not null
            || patch.SceneGoalTextureId is not null || patch.SceneHazardTextureId is not null))
        {
            throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "Neutral Scene must be authored through sceneObjects, not fixed Gameplay fields.");
        }
        var sceneTextures = NormalizeSceneTextures(current.Scene, assets, patch.SceneTextures);
        var textureSet = sceneTextures.ResolvedTextures ?? current.Scene.Textures ?? throw Failure(WorkspaceAuthoringFailureKind.Invariant, "Scene texture set is missing from the snapshot.");
        ValidateTextureId(textureSet, patch.ScenePlayerTextureId, "scene.player.textureId");
        ValidateTextureId(textureSet, patch.SceneGoalTextureId, "scene.goal.textureId");
        ValidateTextureId(textureSet, patch.SceneHazardTextureId, "scene.hazard.textureId");
        var workspaceTextures = textureSet.Select(value => new WorkspaceSceneTexture(value.TextureId, value.Artifact)).ToArray();
        var currentObjects = current.Scene.Objects ?? throw Failure(WorkspaceAuthoringFailureKind.Invariant, "Scene object set is missing from the snapshot.");
        WorkspaceSceneObject[]? normalizedObjects = null;
        if (patch.SceneObjects is not null)
        {
            try { normalizedObjects = WorkspaceSceneDocumentCodec.NormalizeDefinitions(patch.SceneObjects, workspaceTextures, TargetSceneSchema(current.Scene.SchemaVersion), gameplay); }
            catch (WorkspaceProjectValidationException exception) { throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, exception.Message, exception); }
        }
        else if (sceneTextures.ResolvedTextures is not null)
        {
            try
            {
                _ = WorkspaceSceneDocumentCodec.NormalizeDefinitions(
                    currentObjects.Select(ToDefinition).ToArray(), workspaceTextures, TargetSceneSchema(current.Scene.SchemaVersion), gameplay);
            }
            catch (WorkspaceProjectValidationException exception) { throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, exception.Message, exception); }
        }
        var provided = patch.SceneGoalPosition is not null || patch.ScriptGoalPosition is not null || patch.ScriptGoalVelocity is not null
            || patch.ScenePlayerTextureId is not null || patch.SceneGoalTextureId is not null || patch.SceneHazardTextureId is not null
            || patch.SceneTextures is not null || patch.SceneObjects is not null;
        if (!provided) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "At least one authoring field is required.");

        var sceneGoal = Changed(patch.SceneGoalPosition, current.Scene.GoalPosition) ? patch.SceneGoalPosition : null;
        var scriptGoal = Changed(patch.ScriptGoalPosition, current.Script.GoalPosition) ? patch.ScriptGoalPosition : null;
        var velocity = Changed(patch.ScriptGoalVelocity, current.Script.GoalVelocity) ? patch.ScriptGoalVelocity : null;
        var playerTexture = patch.ScenePlayerTextureId is not null && patch.ScenePlayerTextureId != current.Scene.PlayerTextureId ? patch.ScenePlayerTextureId : null;
        var goalTexture = patch.SceneGoalTextureId is not null && patch.SceneGoalTextureId != current.Scene.GoalTextureId ? patch.SceneGoalTextureId : null;
        var hazardTexture = patch.SceneHazardTextureId is not null && patch.SceneHazardTextureId != current.Scene.HazardTextureId ? patch.SceneHazardTextureId : null;
        var objectDefinitions = normalizedObjects is not null
            && (current.Scene.SchemaVersion != WorkspaceSceneDocumentCodec.CurrentSchemaVersion || !ObjectsEqual(currentObjects, normalizedObjects))
            ? normalizedObjects.Select(value => value.ToDefinition()).ToArray()
            : null;
        var normalized = new AuthoringPatch(sceneGoal, scriptGoal, velocity, playerTexture, goalTexture, hazardTexture,
            sceneTextures.RequestedTextures, objectDefinitions);
        var fields = ChangedFields(normalized);
        if (fields.Length == 0) return new NormalizedPatch(normalized, [], false, false, null, null);
        return new NormalizedPatch(normalized, fields,
            sceneGoal is not null || playerTexture is not null || goalTexture is not null || hazardTexture is not null
                || sceneTextures.ResolvedTextures is not null || objectDefinitions is not null,
            scriptGoal is not null || velocity is not null,
            sceneTextures.ResolvedTextures,
            objectDefinitions is null ? null : normalizedObjects);
    }

    private static byte[] BuildSceneBytes(byte[] original, NormalizedPatch normalized)
    {
        WorkspaceSceneDocument current;
        try { current = WorkspaceSceneDocumentCodec.Parse(original); }
        catch (WorkspaceProjectValidationException exception) { throw Failure(WorkspaceAuthoringFailureKind.Input, exception.Message, exception); }
        var textures = normalized.ResolvedSceneTextures is null
            ? current.Textures
            : normalized.ResolvedSceneTextures.Select(value => new WorkspaceSceneTexture(value.TextureId, value.Artifact)).ToArray();
        var objects = normalized.ResolvedSceneObjects ?? ApplyFixedObjectPatch(current.Objects, normalized.Patch);
        if (current.SourceSchemaVersion is WorkspaceSceneDocumentCodec.LegacySchemaVersion
            or WorkspaceSceneDocumentCodec.BehaviorSchemaVersion
            or WorkspaceSceneDocumentCodec.PrototypeSchemaVersion
            or WorkspaceSceneDocumentCodec.CurrentSchemaVersion
            || normalized.ResolvedSceneObjects is not null)
        {
            try
            {
                return current.SourceSchemaVersion switch
                {
                    WorkspaceSceneDocumentCodec.CurrentSchemaVersion => WorkspaceSceneDocumentCodec.SerializeV7(textures, objects, current.Prototypes, current.Gameplay),
                    WorkspaceSceneDocumentCodec.PrototypeSchemaVersion => WorkspaceSceneDocumentCodec.SerializeV6(textures, objects, current.Prototypes),
                    WorkspaceSceneDocumentCodec.BehaviorSchemaVersion => WorkspaceSceneDocumentCodec.SerializeV5(textures, objects),
                    _ => WorkspaceSceneDocumentCodec.SerializeV4(textures, objects)
                };
            }
            catch (WorkspaceProjectValidationException exception) { throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, exception.Message, exception); }
        }
        var scene = ParseObject(original, "Scene");
        ApplyLegacyScenePatch(scene, normalized.Patch, normalized.ResolvedSceneTextures);
        return Serialize(scene);
    }

    private static WorkspaceSceneObject[] ApplyFixedObjectPatch(WorkspaceSceneObject[] current, AuthoringPatch patch)
    {
        return current.Select(value => value.Kind switch
        {
            WorkspaceSceneDocumentCodec.PlayerKind => value with
            {
                TextureId = patch.ScenePlayerTextureId ?? value.TextureId
            },
            WorkspaceSceneDocumentCodec.GoalKind => value with
            {
                Position = patch.SceneGoalPosition?.ToArray() ?? value.Position.ToArray(),
                TextureId = patch.SceneGoalTextureId ?? value.TextureId
            },
            WorkspaceSceneDocumentCodec.PatrolHazardKind when value.ObjectId == current.First(item => item.Kind == WorkspaceSceneDocumentCodec.PatrolHazardKind).ObjectId => value with
            {
                TextureId = patch.SceneHazardTextureId ?? value.TextureId
            },
            _ => value with { Position = value.Position.ToArray(), Size = value.Size.ToArray(), Color = value.Color.ToArray() }
        }).ToArray();
    }

    private static void ApplyLegacyScenePatch(JsonObject scene, AuthoringPatch patch, ProjectModelTexture[]? resolvedSceneTextures)
    {
        var player = RequireObject(scene, "player", "Scene");
        var goal = RequireObject(scene, "goal", "Scene");
        var hazard = RequireObject(scene, "hazard", "Scene");
        if (resolvedSceneTextures is not null)
        {
            scene["textures"] = new JsonArray(resolvedSceneTextures.Select(texture => JsonSerializer.SerializeToNode(texture, EditorProtocol.JsonOptions)).ToArray());
        }
        if (patch.SceneGoalPosition is not null) goal["position"] = Vector(patch.SceneGoalPosition);
        if (patch.ScenePlayerTextureId is not null) player["textureId"] = patch.ScenePlayerTextureId.Value;
        if (patch.SceneGoalTextureId is not null) goal["textureId"] = patch.SceneGoalTextureId.Value;
        if (patch.SceneHazardTextureId is not null) hazard["textureId"] = patch.SceneHazardTextureId.Value;
    }

    private static void ApplyScriptPatch(JsonObject script, AuthoringPatch patch)
    {
        if (patch.ScriptGoalPosition is not null) RequireInstruction(script, "on_start", "set_goal_position")["value"] = Vector(patch.ScriptGoalPosition);
        if (patch.ScriptGoalVelocity is not null) RequireInstruction(script, "fixed_update", "move_goal_velocity")["value"] = Vector(patch.ScriptGoalVelocity);
    }

    private static bool ObjectsEqual(IReadOnlyList<ProjectModelSceneObject> current, IReadOnlyList<WorkspaceSceneObject> requested) =>
        current.Count == requested.Count && current.Zip(requested).All(pair =>
            pair.First.ObjectId == pair.Second.ObjectId
            && pair.First.Kind == pair.Second.Kind
            && pair.First.Position.SequenceEqual(pair.Second.Position)
            && pair.First.Size.SequenceEqual(pair.Second.Size)
            && pair.First.Color.SequenceEqual(pair.Second.Color)
            && pair.First.TextureId == pair.Second.TextureId
            && pair.First.MoveSpeed == pair.Second.MoveSpeed
            && pair.First.PatrolMinY == pair.Second.PatrolMinY
            && pair.First.PatrolMaxY == pair.Second.PatrolMaxY
            && pair.First.PatrolSpeed == pair.Second.PatrolSpeed
            && BehaviorsEqual(pair.First.Behaviors, pair.Second.Behaviors));

    private static bool BehaviorsEqual(
        IReadOnlyList<ProjectModelSceneBehaviorBinding>? current,
        IReadOnlyList<WorkspaceSceneBehaviorBinding>? requested)
    {
        var left = current ?? Array.Empty<ProjectModelSceneBehaviorBinding>();
        var right = requested ?? Array.Empty<WorkspaceSceneBehaviorBinding>();
        return left.Count == right.Count && left.Zip(right).All(pair =>
            pair.First.ScriptId == pair.Second.ScriptId
            && (pair.First.Parameters ?? Array.Empty<ProjectModelSceneBehaviorParameter>()).Count == pair.Second.Parameters.Length
            && (pair.First.Parameters ?? Array.Empty<ProjectModelSceneBehaviorParameter>()).Zip(pair.Second.Parameters).All(parameter =>
                parameter.First.Name == parameter.Second.Name && parameter.First.Value == parameter.Second.Value));
    }

    private static void ValidateBehaviorContractChanges(
        ProjectSessionInfo project,
        ProjectModelSnapshot current,
        NormalizedPatch normalized,
        CancellationToken cancellationToken)
    {
        if (normalized.ResolvedSceneObjects is not { } requested) return;
        var currentObjects = current.Scene.Objects
            ?? throw Failure(WorkspaceAuthoringFailureKind.Invariant, "Scene object set is missing from the snapshot.");
        if (current.Scene.SchemaVersion is not (WorkspaceSceneDocumentCodec.BehaviorSchemaVersion
            or WorkspaceSceneDocumentCodec.PrototypeSchemaVersion
            or WorkspaceSceneDocumentCodec.CurrentSchemaVersion)) return;
        if (!BehaviorCollectionsChanged(currentObjects, requested)) return;

        WorkspaceBehaviorContractObservation observation;
        try { observation = WorkspaceBehaviorContractModel.Read(project, cancellationToken); }
        catch (WorkspaceBehaviorContractException exception)
        {
            var kind = exception.Code == "behavior_contract_source_changed"
                ? WorkspaceAuthoringFailureKind.RevisionConflict
                : WorkspaceAuthoringFailureKind.InvalidPatch;
            throw Failure(kind, $"Behavior contract is unavailable: {exception.Code}: {exception.Message}", exception);
        }
        if (!observation.AuthoringRevision.Equals(current.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
            throw Failure(WorkspaceAuthoringFailureKind.RevisionConflict, "Behavior contract no longer matches the current authoring revision.");

        var entries = observation.Catalog.Entries.ToDictionary(entry => entry.ScriptId);
        foreach (var sceneObject in requested)
        {
            foreach (var binding in sceneObject.Behaviors ?? [])
            {
                if (!entries.TryGetValue(binding.ScriptId, out var entry))
                    throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch,
                        $"Scene.objects[{sceneObject.ObjectId}].behaviors references unknown scriptId {binding.ScriptId}.");
                var schemas = entry.Parameters.ToDictionary(parameter => parameter.Name, StringComparer.Ordinal);
                foreach (var parameter in binding.Parameters)
                {
                    if (!schemas.TryGetValue(parameter.Name, out var schema))
                        throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch,
                            $"Scene.objects[{sceneObject.ObjectId}].behaviors[{binding.ScriptId}] contains unknown parameter {parameter.Name}.");
                    if (parameter.Value < schema.Minimum || parameter.Value > schema.Maximum)
                        throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch,
                            $"Scene.objects[{sceneObject.ObjectId}].behaviors[{binding.ScriptId}].parameters.{parameter.Name} is outside [{schema.Minimum}, {schema.Maximum}].");
                }
            }
        }
    }

    private static bool BehaviorCollectionsChanged(
        IReadOnlyList<ProjectModelSceneObject> current,
        IReadOnlyList<WorkspaceSceneObject> requested)
    {
        var requestedById = requested.ToDictionary(value => value.ObjectId, StringComparer.Ordinal);
        foreach (var currentObject in current)
        {
            if (!requestedById.TryGetValue(currentObject.ObjectId, out var requestedObject))
            {
                if ((currentObject.Behaviors?.Count ?? 0) != 0) return true;
                continue;
            }
            if (!BehaviorsEqual(currentObject.Behaviors, requestedObject.Behaviors)) return true;
        }
        var currentIds = current.Select(value => value.ObjectId).ToHashSet(StringComparer.Ordinal);
        return requested.Any(value => !currentIds.Contains(value.ObjectId) && (value.Behaviors?.Length ?? 0) != 0);
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

    private static int TargetSceneSchema(int sourceSchemaVersion) =>
        sourceSchemaVersion switch
        {
            WorkspaceSceneDocumentCodec.CurrentSchemaVersion => WorkspaceSceneDocumentCodec.CurrentSchemaVersion,
            WorkspaceSceneDocumentCodec.PrototypeSchemaVersion => WorkspaceSceneDocumentCodec.PrototypeSchemaVersion,
            WorkspaceSceneDocumentCodec.BehaviorSchemaVersion => WorkspaceSceneDocumentCodec.BehaviorSchemaVersion,
            _ => WorkspaceSceneDocumentCodec.LegacySchemaVersion
        };

    private static WorkspaceSceneGameplay GameplayFromSnapshot(ProjectModelScene scene) =>
        new(scene.GameplayProfile, scene.GameplayProfile == WorkspaceSceneDocumentCodec.NoGameplayProfile
            ? 0
            : scene.GameplayTimeLimitSeconds ?? WorkspaceSceneDocumentCodec.LegacyGameplay.TimeLimitSeconds);

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
        if (patch.SceneTextures is not null) fields.Add("scene.textures");
        if (patch.SceneObjects is not null) fields.Add("scene.objects");
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

    private static void ValidateTextureId(IReadOnlyList<ProjectModelTexture> textures, uint? value, string field)
    {
        if (value is not null && value == 0) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, $"{field} must be a non-zero TextureId.");
        if (value is not null && textures.Count > 0 && !textures.Any(texture => texture.TextureId == value))
        {
            throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, $"{field} must reference a TextureId declared by the Scene texture set.");
        }
    }

    private static SceneTextureNormalization NormalizeSceneTextures(
        ProjectModelScene current,
        AssetCatalogSnapshot? assets,
        IReadOnlyList<SceneTextureAssignment>? requested)
    {
        if (requested is null) return new SceneTextureNormalization(null, null);
        if (assets is null) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "scene.textures requires an asset catalog snapshot.");
        if (requested.Count is < 1 or > 4) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "scene.textures must contain 1 to 4 entries.");

        var assetsById = assets.Items.ToDictionary(item => item.AssetId, StringComparer.Ordinal);
        var resolved = new ProjectModelTexture[requested.Count];
        var seenTextureIds = new HashSet<uint>();
        for (var index = 0; index < requested.Count; index++)
        {
            var item = requested[index];
            if (item.TextureId == 0) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, $"scene.textures[{index}].textureId must be non-zero.");
            if (!seenTextureIds.Add(item.TextureId)) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "scene.textures textureId values must be unique.");
            if (string.IsNullOrWhiteSpace(item.AssetId)) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, $"scene.textures[{index}].assetId is required.");
            if (!assetsById.TryGetValue(item.AssetId, out var asset))
            {
                throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, $"scene.textures[{index}].assetId must reference a texture in the current asset catalog.");
            }
            if (!WorkspaceProjectValidator.IsTextureArtifactPath(asset.RelativePath))
            {
                throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, $"scene.textures[{index}].assetId must resolve to a legal renderer2d texture artifact.");
            }
            resolved[index] = new ProjectModelTexture(item.TextureId, asset.RelativePath);
        }

        if (current.Textures is null || current.Textures.Count != resolved.Length || current.Textures.Where((texture, index) =>
            texture.TextureId != resolved[index].TextureId || !string.Equals(texture.Artifact, resolved[index].Artifact, StringComparison.Ordinal)).Any())
        {
            return new SceneTextureNormalization(resolved, requested.ToArray());
        }

        return new SceneTextureNormalization(null, null);
    }

    private static WorkspaceAuthoringException Failure(WorkspaceAuthoringFailureKind kind, string message, Exception? inner = null) => new(kind, message, inner);

    private sealed record NormalizedPatch(
        AuthoringPatch Patch,
        string[] ChangedFields,
        bool SceneChanged,
        bool ScriptChanged,
        ProjectModelTexture[]? ResolvedSceneTextures,
        WorkspaceSceneObject[]? ResolvedSceneObjects);
    private sealed record SceneTextureNormalization(ProjectModelTexture[]? ResolvedTextures, SceneTextureAssignment[]? RequestedTextures);
    private sealed record TransactionEntry(string TargetPath, string StagedPath, string RecoveryPath, byte[] Intended);
}
