using System.Text.Json;
using Kadath.Editor.Client;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.ViewModels;

public enum EditorConnectionState { Disconnected, Connecting, Ready, Stopping, Faulted }

/// <summary>
/// UI 的单一工作区状态入口。它把 RPC 事件转为可绑定状态，并在同一处执行 capability gating。
/// </summary>
public sealed class EditorWorkspaceViewModel : ObservableObject, IAsyncDisposable
{
    private readonly IEditorViewDispatcher _dispatcher;
    private EditorConnectionState _connectionState;
    private string? _lastErrorCode;
    private string? _lastErrorMessage;
    private string? _lastEventName;
    private long _lastEventSequence;
    private EditorRpcConnectionClosed? _lastConnectionClosed;
    private readonly object _behaviorContractRefreshLock = new();
    private BehaviorContractRefreshRequest? _pendingBehaviorContractRefresh;
    private bool _behaviorContractRefreshRunning;

    public EditorWorkspaceViewModel(IEditorRpcClient client, IEditorViewDispatcher? dispatcher = null)
    {
        Client = client ?? throw new ArgumentNullException(nameof(client));
        _dispatcher = dispatcher ?? new InlineEditorViewDispatcher();
        ScriptDiagnostics = new EditorScriptDiagnosticsViewModel(Client, _dispatcher);
        Client.EventReceived += HandleEventAsync;
        Client.ConnectionClosed += HandleConnectionClosedAsync;
        Publication.PropertyChanged += (_, _) => Preview.Runtime.Reconcile(Publication.Snapshot);
    }

    public IEditorRpcClient Client { get; }
    public EditorConnectionState ConnectionState { get => _connectionState; private set => SetProperty(ref _connectionState, value); }
    public EditorCapabilitiesViewModel Capabilities { get; } = new();
    public EditorProjectViewModel Project { get; } = new();
    public EditorSnapshotViewModel<ProjectModelSnapshot> ProjectSnapshot { get; } = new();
    public EditorSnapshotViewModel<HierarchySnapshot> HierarchySnapshot { get; } = new();
    public EditorSnapshotViewModel<AssetCatalogSnapshot> AssetCatalogSnapshot { get; } = new();
    public EditorScriptSourceViewModel ScriptSource { get; } = new();
    public EditorScriptAssetLifecycleViewModel ScriptAssetLifecycle { get; } = new();
    public EditorScriptDiagnosticsViewModel ScriptDiagnostics { get; }
    public EditorSnapshotViewModel<BehaviorContractSnapshotResult> BehaviorContract { get; } = new();
    public EditorPublicationViewModel Publication { get; } = new();
    public EditorTextureImportViewModel TextureImport { get; } = new();
    public EditorAuthoringViewModel Authoring { get; } = new();
    public EditorBakeViewModel Bake { get; } = new();
    public EditorWatchViewModel Watch { get; } = new();
    public EditorPreviewViewModel Preview { get; } = new();
    public string? LastErrorCode { get => _lastErrorCode; private set => SetProperty(ref _lastErrorCode, value); }
    public string? LastErrorMessage { get => _lastErrorMessage; private set => SetProperty(ref _lastErrorMessage, value); }
    public string? LastEventName { get => _lastEventName; private set => SetProperty(ref _lastEventName, value); }
    public long LastEventSequence { get => _lastEventSequence; private set => SetProperty(ref _lastEventSequence, value); }
    public EditorRpcConnectionClosed? LastConnectionClosed { get => _lastConnectionClosed; private set => SetProperty(ref _lastConnectionClosed, value); }

    public async Task ConnectAsync(CancellationToken cancellationToken = default)
    {
        await _dispatcher.InvokeAsync(() =>
        {
            ConnectionState = EditorConnectionState.Connecting;
            ClearError();
        }).ConfigureAwait(false);
        try
        {
            await Client.ConnectAsync(cancellationToken).ConfigureAwait(false);
            var capabilities = await Client.GetCapabilitiesAsync(cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() =>
            {
                Capabilities.Apply(capabilities);
                ScriptDiagnostics.SetSupported(Capabilities.CanAnalyzeScriptSource);
                ConnectionState = EditorConnectionState.Ready;
            }).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            await ApplyExceptionAsync(exception, "connect_failed").ConfigureAwait(false);
            throw;
        }
    }

    public async Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanOpenProject, "project_open");
        await _dispatcher.InvokeAsync(Project.BeginOpen).ConfigureAwait(false);
        try
        {
            var result = await Client.OpenProjectAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() =>
            {
                ApplyOpenedSession(result);
            }).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyProjectExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<ProjectSessionInfo> CreateProjectAsync(ProjectCreateParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanCreateProject, "project_create");
        EnsureProjectCreateIdle();
        await _dispatcher.InvokeAsync(Project.BeginCreate).ConfigureAwait(false);

        ProjectSessionInfo result;
        try
        {
            result = await Client.CreateProjectAsync(parameters, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // 本地停止等待不等于 Service 已拒绝；保留旧 Session，等待迟到事件对账。
            await _dispatcher.InvokeAsync(Project.ApplyCreateOutcomeUnknown).ConfigureAwait(false);
            throw;
        }
        catch (Exception exception)
        {
            await ApplyCreateExceptionAsync(exception, parameters).ConfigureAwait(false);
            throw;
        }

        await _dispatcher.InvokeAsync(() => ApplyCreatedSession(result)).ConfigureAwait(false);
        // Create 已由成功 response 确认；后续 snapshot 失败只影响新 Session 的读取状态。
        await RefreshCreatedSnapshotGroupAsync(result.ProjectName, cancellationToken).ConfigureAwait(false);
        return result;
    }

    public async Task<ProjectValidateResult> ValidateProjectAsync(string? projectName = null, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanValidateProject, "project_validate");
        await _dispatcher.InvokeAsync(Project.BeginValidate).ConfigureAwait(false);
        try
        {
            var result = await Client.ValidateProjectAsync(new ProjectValidateParameters(projectName), cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Project.ApplyValidation(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyProjectExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task RefreshSnapshotsAsync(string? projectName = null, CancellationToken cancellationToken = default)
    {
        // 先验证全部 capability，避免旧 Service 上只刷新一半快照。
        EnsureCommand(Capabilities.CanReadProjectSnapshot, "project_snapshot");
        EnsureCommand(Capabilities.CanReadHierarchySnapshot, "hierarchy_snapshot");
        EnsureCommand(Capabilities.CanReadAssetCatalogSnapshot, "asset_catalog_snapshot");
        await RefreshProjectSnapshotAsync(projectName, cancellationToken).ConfigureAwait(false);
        await RefreshHierarchySnapshotAsync(projectName, cancellationToken).ConfigureAwait(false);
        await RefreshAssetCatalogSnapshotAsync(projectName, cancellationToken).ConfigureAwait(false);
        if (Capabilities.CanReadBehaviorContract)
        {
            await RefreshBehaviorContractAsync(projectName, cancellationToken).ConfigureAwait(false);
        }
        if (Capabilities.CanReadPublicationSnapshot)
        {
            await RefreshPublicationAsync(projectName, cancellationToken: cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task<ProjectModelSnapshot> RefreshProjectSnapshotAsync(string? projectName = null, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanReadProjectSnapshot, "project_snapshot");
        await _dispatcher.InvokeAsync(ProjectSnapshot.Begin).ConfigureAwait(false);
        try
        {
            var result = await Client.GetProjectSnapshotAsync(new SnapshotQueryParameters(projectName), cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => ApplyRefreshedProjectSnapshot(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplySnapshotExceptionAsync(ProjectSnapshot, exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<HierarchySnapshot> RefreshHierarchySnapshotAsync(string? projectName = null, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanReadHierarchySnapshot, "hierarchy_snapshot");
        await _dispatcher.InvokeAsync(HierarchySnapshot.Begin).ConfigureAwait(false);
        try
        {
            var result = await Client.GetHierarchySnapshotAsync(new SnapshotQueryParameters(projectName), cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => HierarchySnapshot.Apply(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplySnapshotExceptionAsync(HierarchySnapshot, exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<AssetCatalogSnapshot> RefreshAssetCatalogSnapshotAsync(string? projectName = null, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanReadAssetCatalogSnapshot, "asset_catalog_snapshot");
        await _dispatcher.InvokeAsync(AssetCatalogSnapshot.Begin).ConfigureAwait(false);
        try
        {
            var result = await Client.GetAssetCatalogSnapshotAsync(new SnapshotQueryParameters(projectName), cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => AssetCatalogSnapshot.Apply(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplySnapshotExceptionAsync(AssetCatalogSnapshot, exception).ConfigureAwait(false);
            throw;
        }
    }

    public Task<BehaviorContractSnapshotResult> RefreshBehaviorContractAsync(string? projectName = null, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanReadBehaviorContract, "behavior_contract_snapshot");
        var requestProject = Project.Session;
        var request = new BehaviorContractRefreshRequest(
            projectName ?? requestProject?.ProjectName,
            requestProject,
            cancellationToken);
        lock (_behaviorContractRefreshLock)
        {
            _pendingBehaviorContractRefresh?.Completion.TrySetCanceled();
            _pendingBehaviorContractRefresh = request;
            if (!_behaviorContractRefreshRunning)
            {
                _behaviorContractRefreshRunning = true;
                _ = RunBehaviorContractRefreshQueueAsync();
            }
        }
        return request.Completion.Task;
    }

    private async Task RunBehaviorContractRefreshQueueAsync()
    {
        while (true)
        {
            BehaviorContractRefreshRequest? request;
            lock (_behaviorContractRefreshLock)
            {
                request = _pendingBehaviorContractRefresh;
                _pendingBehaviorContractRefresh = null;
                if (request is null)
                {
                    _behaviorContractRefreshRunning = false;
                    return;
                }
            }
            try
            {
                var result = await RefreshBehaviorContractCoreAsync(request).ConfigureAwait(false);
                request.Completion.TrySetResult(result);
            }
            catch (OperationCanceledException exception) { request.Completion.TrySetCanceled(exception.CancellationToken); }
            catch (Exception exception) { request.Completion.TrySetException(exception); }
        }
    }

    private async Task<BehaviorContractSnapshotResult> RefreshBehaviorContractCoreAsync(BehaviorContractRefreshRequest request)
    {
        var requestProject = request.Project;
        if (!IsCurrentBehaviorContractSession(requestProject, null))
            throw new OperationCanceledException("Behavior Contract refresh belongs to an inactive project.", request.CancellationToken);
        for (var attempt = 0; attempt < 2; attempt++)
        {
            request.CancellationToken.ThrowIfCancellationRequested();
            await _dispatcher.InvokeAsync(BehaviorContract.Begin).ConfigureAwait(false);
            try
            {
                var result = await Client.GetBehaviorContractSnapshotAsync(
                    new BehaviorContractSnapshotParameters(request.ProjectName), request.CancellationToken).ConfigureAwait(false);
                if (result.ErrorCode == "behavior_contract_source_changed" && attempt == 0) continue;
                await _dispatcher.InvokeAsync(() =>
                {
                    if (!IsCurrentBehaviorContractSession(requestProject, result)) return;
                    if (!IsCurrentBehaviorContractRequest(requestProject, result))
                    {
                        BehaviorContract.ApplyFailure("behavior_contract_stale", "行为契约响应已过期；保留最近一次成功目录。");
                        return;
                    }
                    if (result.State == "ready") BehaviorContract.Apply(result);
                    else BehaviorContract.ApplyFailure(
                        result.ErrorCode ?? "behavior_contract_unavailable",
                        "当前脚本契约不可用；保留最近一次成功目录。");
                }).ConfigureAwait(false);
                return result;
            }
            catch (Exception exception)
            {
                if (IsCurrentBehaviorContractSession(requestProject, null))
                    await ApplySnapshotExceptionAsync(BehaviorContract, exception).ConfigureAwait(false);
                throw;
            }
        }
        throw new EditorRpcException("behavior_contract_source_changed", "行为脚本源码在读取期间发生变化。");
    }

    private bool IsCurrentBehaviorContractSession(ProjectSessionInfo? requestProject, BehaviorContractSnapshotResult? result) =>
        requestProject is null
            || EditorProjectIdentity.Matches(Project.Session, requestProject)
                && (result is null || result.ProjectName.Equals(requestProject.ProjectName, StringComparison.Ordinal));

    private bool IsCurrentBehaviorContractRequest(ProjectSessionInfo? requestProject, BehaviorContractSnapshotResult result) =>
        IsCurrentBehaviorContractSession(requestProject, result)
        && (ProjectSnapshot.Value is null
            || result.AuthoringRevision.Equals(ProjectSnapshot.Value.AuthoringRevision, StringComparison.OrdinalIgnoreCase));

    public async Task<ScriptSourceDocument> ReadScriptSourceAsync(ScriptSourceQueryParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanReadScriptSource, "script_source_read");
        await _dispatcher.InvokeAsync(ScriptSource.BeginRead).ConfigureAwait(false);
        try
        {
            var result = await Client.GetScriptSourceAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => ScriptSource.ApplyRead(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyScriptSourceExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public void ObserveScriptSourceBuffer(
        ScriptSourceDocument? document,
        string source,
        bool eligible = true) => ScriptDiagnostics.Observe(
            document?.ProjectName,
            document?.ScriptId,
            document?.SourcePath,
            source,
            eligible && document is not null);

    public void ReanalyzeScriptSource() => ScriptDiagnostics.Reanalyze();

    public async Task<ScriptSourceMutationResult> EditScriptSourceAsync(ScriptSourceEditParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanEditScriptSource, "script_source_edit");
        await _dispatcher.InvokeAsync(ScriptSource.BeginEdit).ConfigureAwait(false);
        try
        {
            var result = await Client.EditScriptSourceAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => ApplyScriptSourceResult(result)).ConfigureAwait(false);
            await RefreshBehaviorContractAfterOperationAsync(result.ProjectName, cancellationToken).ConfigureAwait(false);
            await RefreshPublicationAfterOperationAsync(result.ProjectName, Publication.Profile, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyScriptSourceExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<ScriptSourceMutationResult> UndoScriptSourceAsync(ScriptSourceUndoParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanUndoScriptSource, "script_source_undo");
        await _dispatcher.InvokeAsync(ScriptSource.BeginUndo).ConfigureAwait(false);
        try
        {
            var result = await Client.UndoScriptSourceAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => ApplyScriptSourceResult(result)).ConfigureAwait(false);
            await RefreshBehaviorContractAfterOperationAsync(result.ProjectName, cancellationToken).ConfigureAwait(false);
            await RefreshPublicationAfterOperationAsync(result.ProjectName, Publication.Profile, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyScriptSourceExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<ScriptAssetMutationResult> CreateScriptAssetAsync(ScriptAssetCreateParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureScriptAssetLifecycleReady();
        await _dispatcher.InvokeAsync(() => ScriptAssetLifecycle.Begin("create")).ConfigureAwait(false);
        try
        {
            var result = await Client.CreateScriptAssetAsync(parameters, cancellationToken).ConfigureAwait(false);
            await ApplyScriptAssetLifecycleResultAsync(result, ScriptSource.Document?.ScriptId, ProjectSnapshot.Value?.Script.Dependencies, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyScriptAssetLifecycleExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<ScriptAssetMutationResult> RenameScriptAssetAsync(ScriptAssetRenameParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureScriptAssetLifecycleReady();
        await _dispatcher.InvokeAsync(() => ScriptAssetLifecycle.Begin("rename")).ConfigureAwait(false);
        try
        {
            var result = await Client.RenameScriptAssetAsync(parameters, cancellationToken).ConfigureAwait(false);
            await ApplyScriptAssetLifecycleResultAsync(result, ScriptSource.Document?.ScriptId, ProjectSnapshot.Value?.Script.Dependencies, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyScriptAssetLifecycleExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<ScriptAssetMutationResult> DeleteScriptAssetAsync(ScriptAssetDeleteParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureScriptAssetLifecycleReady();
        var selectedScriptId = ScriptSource.Document?.ScriptId;
        var previousDependencies = ProjectSnapshot.Value?.Script.Dependencies;
        await _dispatcher.InvokeAsync(() => ScriptAssetLifecycle.Begin("delete")).ConfigureAwait(false);
        try
        {
            var result = await Client.DeleteScriptAssetAsync(parameters, cancellationToken).ConfigureAwait(false);
            await ApplyScriptAssetLifecycleResultAsync(result, selectedScriptId, previousDependencies, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyScriptAssetLifecycleExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<ScriptAssetMutationResult> UndoScriptAssetAsync(ScriptAssetUndoParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureScriptAssetLifecycleReady();
        var selectedScriptId = ScriptSource.Document?.ScriptId;
        var previousDependencies = ProjectSnapshot.Value?.Script.Dependencies;
        await _dispatcher.InvokeAsync(() => ScriptAssetLifecycle.Begin("undo")).ConfigureAwait(false);
        try
        {
            var result = await Client.UndoScriptAssetAsync(parameters, cancellationToken).ConfigureAwait(false);
            await ApplyScriptAssetLifecycleResultAsync(result, selectedScriptId, previousDependencies, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyScriptAssetLifecycleExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    private async Task ApplyScriptAssetLifecycleResultAsync(
        ScriptAssetMutationResult result,
        uint? selectedScriptId,
        IReadOnlyList<ProjectModelScriptDependency>? previousDependencies,
        CancellationToken cancellationToken)
    {
        uint? replacementScriptId = null;
        await _dispatcher.InvokeAsync(() =>
        {
            ScriptAssetLifecycle.Apply(result);
            ProjectSnapshot.Apply(result.ProjectSnapshot);
            HierarchySnapshot.Apply(result.HierarchySnapshot);
            AssetCatalogSnapshot.Apply(result.AssetCatalogSnapshot);

            if (result.SourceDocument is not null)
            {
                ScriptSource.ApplyLifecycleDocument(result.SourceDocument, result.PreviousRevision, result.Revision);
            }
            else if (selectedScriptId == result.Asset.ScriptId)
            {
                ScriptSource.ClearLifecycleDocument();
                ScriptDiagnostics.Reset(!Capabilities.CanAnalyzeScriptSource);
                replacementScriptId = SelectReplacementScriptId(previousDependencies, result.ProjectSnapshot.Script.Dependencies, result.Asset.ScriptId);
            }
            else
            {
                ScriptSource.ApplyLifecycleDocument(null, result.PreviousRevision, result.Revision);
            }
        }).ConfigureAwait(false);

        if (result.SourceDocument is not null)
        {
            ObserveScriptSourceBuffer(result.SourceDocument, result.SourceDocument.Source);
        }
        else if (replacementScriptId is { } scriptId)
        {
            try
            {
                var replacement = await ReadScriptSourceAsync(new ScriptSourceQueryParameters(result.ProjectName, scriptId), cancellationToken).ConfigureAwait(false);
                ObserveScriptSourceBuffer(replacement, replacement.Source);
            }
            catch { }
        }

        await RefreshBehaviorContractAfterOperationAsync(result.ProjectName, cancellationToken).ConfigureAwait(false);
        await RefreshPublicationAfterOperationAsync(result.ProjectName, Publication.Profile, cancellationToken).ConfigureAwait(false);
    }

    private static uint? SelectReplacementScriptId(
        IReadOnlyList<ProjectModelScriptDependency>? previousDependencies,
        IReadOnlyList<ProjectModelScriptDependency>? currentDependencies,
        uint removedScriptId)
    {
        if (currentDependencies is not { Count: > 0 }) return null;
        var previousIndex = previousDependencies is null
            ? 0
            : Enumerable.Range(0, previousDependencies.Count)
                .FirstOrDefault(index => previousDependencies[index].ScriptId == removedScriptId, -1);
        if (previousIndex < 0) previousIndex = 0;
        return currentDependencies[Math.Min(previousIndex, currentDependencies.Count - 1)].ScriptId;
    }

    public async Task<PublicationSnapshot> RefreshPublicationAsync(string? projectName = null, string profile = "debug", CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanReadPublicationSnapshot, "publication_snapshot");
        await _dispatcher.InvokeAsync(() => Publication.Begin(profile)).ConfigureAwait(false);
        try
        {
            var result = await Client.GetPublicationSnapshotAsync(new PublicationSnapshotQueryParameters(projectName, profile), cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Publication.Apply(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyPublicationExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<EditorBakeResult?> BakeChangesAsync(string profile = "debug", CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanBake, "bake_start");
        EnsureCommand(Capabilities.CanReadPublicationSnapshot, "publication_snapshot");
        EnsureManualBakeAllowed();
        var projectName = Project.Session?.ProjectName;
        await RefreshPublicationAsync(projectName, profile, cancellationToken).ConfigureAwait(false);
        var target = Publication.RecommendedBakeTarget;
        if (target is null) { return null; }
        return await BakeAsync(new BakeStartParameters(target, profile), cancellationToken).ConfigureAwait(false);
    }

    public async Task<AuthoringMutationResult> ApplyAuthoringAsync(AuthoringApplyParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanApplyAuthoring, "authoring_apply");
        await _dispatcher.InvokeAsync(() => Authoring.Begin("apply")).ConfigureAwait(false);
        try
        {
            var result = await Client.ApplyAuthoringAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => ApplyAuthoringResult(result)).ConfigureAwait(false);
            await RefreshBehaviorContractAfterOperationAsync(result.ProjectName, cancellationToken).ConfigureAwait(false);
            await RefreshPublicationAfterOperationAsync(result.ProjectName, Publication.Profile, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyAuthoringExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<TextureImportResult> ImportTextureAsync(TextureImportParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanImportTexture, "texture_import");
        await _dispatcher.InvokeAsync(TextureImport.Begin).ConfigureAwait(false);
        try
        {
            var result = await Client.ImportTextureAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() =>
            {
                TextureImport.ApplyCompleted(result);
                AssetCatalogSnapshot.Apply(result.AssetCatalog);
            }).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyTextureImportExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<AuthoringMutationResult> UndoAuthoringAsync(AuthoringUndoParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanUndoAuthoring, "authoring_undo");
        await _dispatcher.InvokeAsync(() => Authoring.Begin("undo")).ConfigureAwait(false);
        try
        {
            var result = await Client.UndoAuthoringAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => ApplyAuthoringResult(result)).ConfigureAwait(false);
            await RefreshBehaviorContractAfterOperationAsync(result.ProjectName, cancellationToken).ConfigureAwait(false);
            await RefreshPublicationAfterOperationAsync(result.ProjectName, Publication.Profile, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyAuthoringExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    private void ApplyAuthoringResult(AuthoringMutationResult result)
    {
        Authoring.Apply(result);
        ScriptSource.ApplyAuthoringRevision(result.PreviousRevision, result.Revision);
        ProjectSnapshot.Apply(result.ProjectSnapshot);
        HierarchySnapshot.Apply(result.HierarchySnapshot);
    }

    private void ApplyRefreshedProjectSnapshot(ProjectModelSnapshot result)
    {
        var revisionChanged = ProjectSnapshot.Value is { } previous
            && !string.Equals(previous.AuthoringRevision, result.AuthoringRevision, StringComparison.OrdinalIgnoreCase);
        Authoring.InvalidateHistory(result.AuthoringRevision);
        if (revisionChanged)
        {
            ScriptSource.InvalidateHistory();
        }
        ProjectSnapshot.Apply(result);
    }

    private void ApplyScriptSourceResult(ScriptSourceMutationResult result)
    {
        ScriptSource.ApplyMutation(result);
        Authoring.InvalidateHistory(result.Revision);
        ProjectSnapshot.Apply(result.ProjectSnapshot);
        HierarchySnapshot.Apply(result.HierarchySnapshot);
    }
    public async Task<EditorBakeResult> BakeAsync(BakeStartParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanBake, "bake_start");
        EnsureManualBakeAllowed();
        await _dispatcher.InvokeAsync(() => Bake.Begin(parameters.Target, parameters.Profile)).ConfigureAwait(false);
        try
        {
            var result = await Client.StartBakeAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Bake.ApplyCompleted(result)).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Publication.ApplyBakeResult(result)).ConfigureAwait(false);
            await RefreshPublicationAfterOperationAsync(Project.Session?.ProjectName, parameters.Profile, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyBakeExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<EditorWatchResult> StartWatchAsync(WatchStartParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanStartWatch, "watch_start");
        if (Preview.OwnsPublicationSync)
        {
            throw new EditorRpcException("publication_preview_owns_bake", "Preview live-bake/watch is already responsible for derived artifacts.");
        }
        await _dispatcher.InvokeAsync(() => Watch.BeginStart(parameters.Target, parameters.Profile)).ConfigureAwait(false);
        try
        {
            var result = await Client.StartWatchAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() =>
            {
                Watch.ApplyStarted(result);
                if (result.InitialBake is not null)
                {
                    Bake.ApplyCompleted(result.InitialBake);
                    Publication.ApplyBakeResult(result.InitialBake);
                }
            }).ConfigureAwait(false);
            await RefreshPublicationAfterOperationAsync(result.ProjectName, parameters.Profile, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyWatchExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<EditorWatchResult> StopWatchAsync(CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanStopWatch, "watch_stop");
        await _dispatcher.InvokeAsync(Watch.BeginStop).ConfigureAwait(false);
        try
        {
            var result = await Client.StopWatchAsync(cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(Watch.ApplyStopped).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyWatchExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<PreviewStartResult> StartPreviewAsync(PreviewStartParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanStartPreview, "preview_start");
        if (Preview.OwnsPublicationSync)
        {
            throw new EditorRpcException("publication_preview_owns_bake", "Confirm the previous Preview has stopped before starting another publication writer.");
        }
        if (parameters.LiveBake && parameters.WatchChanges && Watch.State is EditorWatchState.Starting or EditorWatchState.Watching or EditorWatchState.Stopping)
        {
            throw new EditorRpcException("publication_watch_owns_bake", "Stop the Service watch before starting Preview live-bake/watch.");
        }
        await _dispatcher.InvokeAsync(() => Preview.BeginStart(parameters)).ConfigureAwait(false);
        try
        {
            var result = await Client.StartPreviewAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Preview.ApplyStarted(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyPreviewExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<PreviewStopResult> StopPreviewAsync(CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanStopPreview, "preview_stop");
        await _dispatcher.InvokeAsync(Preview.BeginStop).ConfigureAwait(false);
        try
        {
            var result = await Client.StopPreviewAsync(cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Preview.ApplyStopped(null)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyPreviewExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task ShutdownAsync(CancellationToken cancellationToken = default)
    {
        if (!Capabilities.SupportsCommand("shutdown")) { throw new EditorRpcException("unsupported_command", "Editor Service does not support shutdown."); }
        await _dispatcher.InvokeAsync(() => ConnectionState = EditorConnectionState.Stopping).ConfigureAwait(false);
        try { await Client.ShutdownAsync(cancellationToken).ConfigureAwait(false); }
        catch (Exception exception)
        {
            await ApplyExceptionAsync(exception, "shutdown_failed").ConfigureAwait(false);
            throw;
        }
    }

    private async Task HandleConnectionClosedAsync(EditorRpcConnectionClosed notification)
    {
        await _dispatcher.InvokeAsync(() =>
        {
            ScriptDiagnostics.SetSupported(false);
            LastConnectionClosed = notification;
            LastEventName = "connection_closed";
            if (notification.Expected)
            {
                // Shutdown 请求阶段先显示 Stopping；底层真正关闭后进入稳定的 Disconnected。
                LastErrorCode = null;
                LastErrorMessage = null;
                ConnectionState = EditorConnectionState.Disconnected;
            }
            else
            {
                LastErrorCode = notification.ErrorCode ?? "connection_closed";
                LastErrorMessage = notification.Message;
                ConnectionState = EditorConnectionState.Faulted;
            }
        }).ConfigureAwait(false);
    }

    private async Task HandleEventAsync(EditorEvent notification)
    {
        await _dispatcher.InvokeAsync(() =>
        {
            LastEventName = notification.Event;
            LastEventSequence = notification.Sequence;
            ApplyEvent(notification);
        }).ConfigureAwait(false);
    }

    private void ApplyEvent(EditorEvent notification)
    {
        switch (notification.Event)
        {
            case "project_opened":
                if (TryRead(notification.Data, out ProjectSessionInfo? session) && session is not null) { ApplyOpenedSession(session); }
                break;
            case "project_created":
                if (TryRead(notification.Data, out ProjectSessionInfo? createdSession) && createdSession is not null) { ApplyCreatedSession(createdSession); }
                break;
            case "project_validated":
                if (TryRead(notification.Data, out ProjectValidateResult? validation) && validation is not null) { Project.ApplyValidation(validation); }
                break;
            case "project_snapshot_created":
                if (TryRead(notification.Data, out ProjectModelSnapshot? projectSnapshot) && projectSnapshot is not null) { ApplyRefreshedProjectSnapshot(projectSnapshot); }
                break;
            case "hierarchy_snapshot_created":
                if (TryRead(notification.Data, out HierarchySnapshot? hierarchySnapshot) && hierarchySnapshot is not null) { HierarchySnapshot.Apply(hierarchySnapshot); }
                break;
            case "asset_catalog_snapshot_created":
                if (TryRead(notification.Data, out AssetCatalogSnapshot? assetSnapshot) && assetSnapshot is not null) { AssetCatalogSnapshot.Apply(assetSnapshot); }
                break;
            case "script_source_read":
                if (TryRead(notification.Data, out ScriptSourceDocument? sourceDocument) && sourceDocument is not null) { ScriptSource.ApplyRead(sourceDocument); }
                break;
            case "script_source_read_failed":
                ScriptSource.ApplyFailure(
                    ReadString(notification.Data, "errorCode") ?? "script_source_read_failed",
                    ReadString(notification.Data, "message") ?? "Script source read failed.");
                break;
            case "script_source_edit_started":
                ScriptSource.BeginEdit();
                break;
            case "script_source_edit_completed":
                if (TryRead(notification.Data, out ScriptSourceMutationResult? editedSource) && editedSource is not null) { ApplyScriptSourceResult(editedSource); }
                break;
            case "script_source_edit_failed":
                ScriptSource.ApplyFailure(
                    ReadString(notification.Data, "errorCode") ?? "script_source_edit_failed",
                    ReadString(notification.Data, "message") ?? "Script source edit failed.");
                break;
            case "script_source_undo_started":
                ScriptSource.BeginUndo();
                break;
            case "script_source_undo_completed":
                if (TryRead(notification.Data, out ScriptSourceMutationResult? undoneSource) && undoneSource is not null) { ApplyScriptSourceResult(undoneSource); }
                break;
            case "script_source_undo_failed":
                ScriptSource.ApplyFailure(
                    ReadString(notification.Data, "errorCode") ?? "script_source_undo_failed",
                    ReadString(notification.Data, "message") ?? "Script source undo failed.");
                break;
            case "script_asset_create_started":
                ScriptAssetLifecycle.Begin("create");
                break;
            case "script_asset_rename_started":
                ScriptAssetLifecycle.Begin("rename");
                break;
            case "script_asset_delete_started":
                ScriptAssetLifecycle.Begin("delete");
                break;
            case "script_asset_undo_started":
                ScriptAssetLifecycle.Begin("undo");
                break;
            case "script_asset_create_failed":
            case "script_asset_rename_failed":
            case "script_asset_delete_failed":
            case "script_asset_undo_failed":
                ScriptAssetLifecycle.ApplyFailure(
                    ReadString(notification.Data, "errorCode") ?? "script_asset_failed",
                    ReadString(notification.Data, "message") ?? "脚本资产生命周期操作失败。");
                break;
            case "publication_snapshot_created":
                if (TryRead(notification.Data, out PublicationSnapshot? publicationSnapshot) && publicationSnapshot is not null) { Publication.Apply(publicationSnapshot); }
                break;
            case "authoring_apply_started":
                Authoring.Begin("apply");
                break;
            case "authoring_undo_started":
                Authoring.Begin("undo");
                break;
            case "authoring_apply_completed":
            case "authoring_undo_completed":
                if (TryRead(notification.Data, out AuthoringMutationResult? mutation) && mutation is not null) { ApplyAuthoringResult(mutation); }
                break;
            case "authoring_apply_failed":
            case "authoring_undo_failed":
                Authoring.ApplyFailure(
                    ReadString(notification.Data, "errorCode") ?? "authoring_failed",
                    ReadString(notification.Data, "message") ?? "Authoring operation failed.");
                break;            case "bake_started":
                Bake.Begin(
                    ReadString(notification.Data, "target") ?? "Both",
                    ReadString(notification.Data, "profile") ?? "debug",
                    ReadString(notification.Data, "revision"));
                break;
            case "bake_completed":
                if (TryRead(notification.Data, out EditorBakeResult? baked) && baked is not null) { Bake.ApplyCompleted(baked); Publication.ApplyBakeResult(baked); }
                break;
            case "bake_failed":
                Bake.ApplyFailed(
                    ReadString(notification.Data, "errorCode") ?? "bake_failed",
                    ReadString(notification.Data, "message") ?? "Bake failed.",
                    ReadBool(notification.Data, "retainedArtifact") ?? true);
                break;
            case "watch_started":
                if (TryRead(notification.Data, out EditorWatchResult? started) && started is not null) { Watch.ApplyStarted(started); }
                break;
            case "watch_stopped":
                Watch.ApplyStopped();
                break;
            case "source_change_detected":
                Watch.ApplySourceChange(ReadString(notification.Data, "target"), ReadString(notification.Data, "revision"));
                break;
            case "preview_surface_created":
                if (TryRead(notification.Data, out PreviewSurfaceDescriptor? surface) && surface is not null) { Preview.ApplySurface(surface); }
                break;
            case "preview_status":
                ApplyPreviewStatus(notification.Data);
                break;
            case "preview_initial_loaded":
                if (TryRead(notification.Data, out PreviewInitialLoadedNotification? initialLoaded) && initialLoaded is not null)
                {
                    Preview.ApplyInitial(initialLoaded);
                }
                break;
            case "preview_initial_load_failed":
                if (TryRead(notification.Data, out PreviewInitialLoadFailedNotification? initialFailed) && initialFailed is not null)
                {
                    Preview.ApplyInitialFailure(initialFailed);
                }
                break;
            case "preview_reload_requested":
            case "preview_reload_acknowledged":
            case "preview_reload_failed":
            case "preview_reload_stale":
                if (TryRead(notification.Data, out PreviewReloadNotification? reload) && reload is not null)
                {
                    Preview.ApplyReload(reload);
                }
                break;
            case "preview_stopped":
                Preview.ApplyStopped(ReadInt(notification.Data, "exitCode"));
                break;
            case "service_stopping":
                ConnectionState = EditorConnectionState.Stopping;
                break;
        }
    }

    private void ApplyPreviewStatus(JsonElement? data)
    {
        var name = ReadString(data, "name");
        var value = ReadValueAsString(data, "value");
        var processId = string.Equals(name, "runtime_pid", StringComparison.OrdinalIgnoreCase) && int.TryParse(value, out var parsed)
            ? parsed
            : (int?)null;
        Preview.ApplyStatus(name, value, processId);
    }

    private static bool TryRead<T>(JsonElement? data, out T? value)
    {
        if (data is { } element)
        {
            try
            {
                value = JsonSerializer.Deserialize<T>(element.GetRawText(), EditorProtocol.JsonOptions);
                return value is not null;
            }
            catch (JsonException) { }
        }
        value = default;
        return false;
    }

    private static string? ReadString(JsonElement? data, string property)
    {
        if (data is not { } element || !element.TryGetProperty(property, out var value)) { return null; }
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False => value.ToString(),
            _ => null
        };
    }

    private static string? ReadValueAsString(JsonElement? data, string property) => ReadString(data, property);

    private static int? ReadInt(JsonElement? data, string property)
    {
        if (data is not { } element || !element.TryGetProperty(property, out var value)) { return null; }
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)) { return number; }
        return int.TryParse(value.ToString(), out var parsed) ? parsed : null;
    }

    private static bool? ReadBool(JsonElement? data, string property)
    {
        if (data is not { } element || !element.TryGetProperty(property, out var value)) { return null; }
        if (value.ValueKind is JsonValueKind.True or JsonValueKind.False) { return value.GetBoolean(); }
        return bool.TryParse(value.ToString(), out var parsed) ? parsed : null;
    }

    private void ApplyCreatedSession(ProjectSessionInfo session)
    {
        var sameIdentity = EditorProjectIdentity.Matches(Project.Session, session);
        if (sameIdentity && Project.State is not (EditorProjectState.Creating or EditorProjectState.OutcomeUnknown))
        {
            // event/response 与规范化重放共用此落点；已确认 identity 不重复清空，也不降级 Valid 状态。
            return;
        }

        if (!sameIdentity)
        {
            // 先静默提交所有 backing state；任何后续通知观察到的都是新 Session + 全空 snapshot 组。
            StageCreatedSnapshotGroupInvalidation();
            Project.StageOpened(session);
            Authoring.Reset();
            ScriptAssetLifecycle.Reset();
            Publication.Reset();
            ScriptSource.Reset();
            ScriptDiagnostics.Reset(!Capabilities.CanAnalyzeScriptSource);
            Project.PublishStagedOpened();
            PublishCreatedSnapshotGroupInvalidation();
            return;
        }
        Project.ApplyOpened(session);
        ScriptSource.Reset();
        ScriptAssetLifecycle.Reset();
    }

    private void ApplyOpenedSession(ProjectSessionInfo session)
    {
        if (EditorProjectIdentity.Matches(Project.Session, session))
        {
            Project.ApplyOpened(session);
            ScriptSource.Reset();
            ScriptAssetLifecycle.Reset();
            ScriptDiagnostics.Reset(!Capabilities.CanAnalyzeScriptSource);
            return;
        }
        StageCreatedSnapshotGroupInvalidation();
        Project.StageOpened(session);
        Authoring.Reset();
        ScriptAssetLifecycle.Reset();
        Publication.Reset();
        ScriptSource.Reset();
        ScriptDiagnostics.Reset(!Capabilities.CanAnalyzeScriptSource);
        Project.PublishStagedOpened();
        PublishCreatedSnapshotGroupInvalidation();
    }

    private void StageCreatedSnapshotGroupInvalidation()
    {
        ProjectSnapshot.StageInvalidation();
        HierarchySnapshot.StageInvalidation();
        AssetCatalogSnapshot.StageInvalidation();
        BehaviorContract.StageInvalidation();
    }

    private void PublishCreatedSnapshotGroupInvalidation()
    {
        ProjectSnapshot.PublishStagedInvalidation();
        HierarchySnapshot.PublishStagedInvalidation();
        AssetCatalogSnapshot.PublishStagedInvalidation();
        BehaviorContract.PublishStagedInvalidation();
    }

    private async Task RefreshCreatedSnapshotGroupAsync(string projectName, CancellationToken cancellationToken)
    {
        if (!await TryRefreshCreatedSnapshotAsync(
            () => RefreshProjectSnapshotAsync(projectName, cancellationToken),
            (code, message) => ProjectSnapshot.InvalidateFailure(code, message)).ConfigureAwait(false)) { return; }
        if (!await TryRefreshCreatedSnapshotAsync(
            () => RefreshHierarchySnapshotAsync(projectName, cancellationToken),
            (code, message) => HierarchySnapshot.InvalidateFailure(code, message)).ConfigureAwait(false)) { return; }
        if (!await TryRefreshCreatedSnapshotAsync(
            () => RefreshAssetCatalogSnapshotAsync(projectName, cancellationToken),
            (code, message) => AssetCatalogSnapshot.InvalidateFailure(code, message)).ConfigureAwait(false)) { return; }

        if (Capabilities.CanReadBehaviorContract && !await TryRefreshCreatedSnapshotAsync(
            () => RefreshBehaviorContractAsync(projectName, cancellationToken),
            (code, message) => BehaviorContract.InvalidateFailure(code, message)).ConfigureAwait(false)) { return; }

        await RefreshPublicationAfterOperationAsync(projectName, Publication.Profile, cancellationToken).ConfigureAwait(false);
    }

    private async Task<bool> TryRefreshCreatedSnapshotAsync<TSnapshot>(
        Func<Task<TSnapshot>> refresh,
        Action<string, string> applyFailure)
    {
        try
        {
            _ = await refresh().ConfigureAwait(false);
            return true;
        }
        catch (Exception exception)
        {
            await ApplyCreatedSnapshotGroupFailureAsync(exception, applyFailure).ConfigureAwait(false);
            return false;
        }
    }

    private async Task ApplyCreatedSnapshotGroupFailureAsync(Exception exception, Action<string, string> applyFailure)
    {
        var (code, message) = ReadSnapshotFailure(exception);
        await _dispatcher.InvokeAsync(() =>
        {
            // 禁止保留“前两项是新项目、后一项失败”的部分快照集合。
            StageCreatedSnapshotGroupInvalidation();
            applyFailure(code, message);
            PublishCreatedSnapshotGroupInvalidation();
        }).ConfigureAwait(false);
    }

    private static (string Code, string Message) ReadSnapshotFailure(Exception exception) => exception switch
    {
        EditorRpcException rpc => (rpc.Code, rpc.Message),
        OperationCanceledException => ("cancelled", "The snapshot request was cancelled."),
        _ => ("snapshot_failed", exception.Message)
    };

    private void EnsureCommand(bool supported, string command)
    {
        if (!supported) { throw new EditorRpcException("unsupported_command", $"Editor Service capability is not available: {command}"); }
    }

    private void EnsureScriptAssetLifecycleReady()
    {
        EnsureCommand(Capabilities.CanManageScriptAssets, "script_asset_create/script_asset_rename/script_asset_delete/script_asset_undo");
        if (ScriptAssetLifecycle.IsBusy)
        {
            throw new EditorRpcException("script_asset_busy", "另一个脚本资产生命周期操作仍在进行中。");
        }
    }

    private sealed class BehaviorContractRefreshRequest
    {
        internal BehaviorContractRefreshRequest(
            string? projectName,
            ProjectSessionInfo? project,
            CancellationToken cancellationToken)
        {
            ProjectName = projectName;
            Project = project;
            CancellationToken = cancellationToken;
        }

        internal string? ProjectName { get; }
        internal ProjectSessionInfo? Project { get; }
        internal CancellationToken CancellationToken { get; }
        internal TaskCompletionSource<BehaviorContractSnapshotResult> Completion { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private void EnsureProjectCreateIdle()
    {
        // Create 会替换活动 Session；只有两类持续运行状态都明确停止后才能发出请求。
        if (Watch.State != EditorWatchState.Stopped || Preview.State != EditorPreviewState.Stopped)
        {
            throw new EditorRpcException(
                "project_create_busy",
                "Stop Watch and Preview before creating a project.");
        }
    }

    private async Task ApplyProjectExceptionAsync(Exception exception) =>
        await ApplyExceptionAsync(exception, "project_operation_failed", Project.ApplyFailure).ConfigureAwait(false);

    private async Task ApplyCreateExceptionAsync(Exception exception, ProjectCreateParameters parameters) =>
        await ApplyExceptionAsync(exception, "project_operation_failed", (code, message) =>
        {
            // BeginCreate 先进入 Creating；只有目标 identity 的 project_created 已落为 Opened 才能抑制伪回滚。
            if (Project.State == EditorProjectState.Opened
                && EditorProjectIdentity.Matches(Project.Session, parameters.PackageRoot, parameters.ProjectName))
            {
                return;
            }
            Project.ApplyFailure(code, message);
        }).ConfigureAwait(false);

    private async Task ApplySnapshotExceptionAsync<TSnapshot>(EditorSnapshotViewModel<TSnapshot> snapshot, Exception exception)
        where TSnapshot : class
    {
        var (code, message) = ReadSnapshotFailure(exception);
        await _dispatcher.InvokeAsync(() => snapshot.ApplyFailure(code, message)).ConfigureAwait(false);
    }
    private async Task ApplyAuthoringExceptionAsync(Exception exception)
    {
        var (code, message) = exception switch
        {
            EditorRpcException rpc => (rpc.Code, rpc.Message),
            OperationCanceledException => ("cancelled", "The authoring operation was cancelled."),
            _ => ("authoring_failed", exception.Message)
        };
        await _dispatcher.InvokeAsync(() =>
        {
            Authoring.ApplyFailure(code, message);
            if (code is "authoring_revision_conflict" or "authoring_history_diverged") { ScriptSource.InvalidateHistory(); }
        }).ConfigureAwait(false);
    }
    private async Task ApplyScriptSourceExceptionAsync(Exception exception)
    {
        var (code, message) = exception switch
        {
            EditorRpcException rpc => (rpc.Code, rpc.Message),
            OperationCanceledException => ("cancelled", "脚本源码操作已取消。"),
            _ => ("script_source_failed", exception.Message)
        };
        await _dispatcher.InvokeAsync(() =>
        {
            ScriptSource.ApplyFailure(code, message);
            if (code is "script_source_revision_conflict" or "script_source_history_diverged" or "authoring_revision_conflict") { Authoring.InvalidateHistory(); }
        }).ConfigureAwait(false);
    }
    private async Task ApplyScriptAssetLifecycleExceptionAsync(Exception exception)
    {
        var (code, message) = exception switch
        {
            EditorRpcException rpc => (rpc.Code, rpc.Message),
            OperationCanceledException => ("cancelled", "脚本资产生命周期操作已取消。"),
            _ => ("script_asset_failed", exception.Message)
        };
        await _dispatcher.InvokeAsync(() => ScriptAssetLifecycle.ApplyFailure(code, message)).ConfigureAwait(false);
    }
    private async Task ApplyBakeExceptionAsync(Exception exception) =>
        await ApplyExceptionAsync(exception, "bake_failed", (code, message) => Bake.ApplyFailed(code, message, true)).ConfigureAwait(false);

    private async Task ApplyWatchExceptionAsync(Exception exception) =>
        await ApplyExceptionAsync(exception, "watch_failed", Watch.ApplyFailure).ConfigureAwait(false);

    private async Task ApplyPreviewExceptionAsync(Exception exception) =>
        await ApplyExceptionAsync(exception, "preview_failed", Preview.ApplyFailure).ConfigureAwait(false);

    private async Task ApplyExceptionAsync(Exception exception, string fallbackCode)
    {
        await ApplyExceptionAsync(exception, fallbackCode, (code, message) =>
        {
            LastErrorCode = code;
            LastErrorMessage = message;
            ConnectionState = EditorConnectionState.Faulted;
        }).ConfigureAwait(false);
    }

    private async Task ApplyExceptionAsync(Exception exception, string fallbackCode, Action<string, string> apply)
    {
        var (code, message) = exception switch
        {
            EditorRpcException rpc => (rpc.Code, rpc.Message),
            OperationCanceledException => ("cancelled", "The editor operation was cancelled."),
            _ => (fallbackCode, exception.Message)
        };
        await _dispatcher.InvokeAsync(() => apply(code, message)).ConfigureAwait(false);
    }

    private async Task ApplyPublicationExceptionAsync(Exception exception) =>
        await ApplyExceptionAsync(exception, "publication_snapshot_failed", Publication.ApplyFailure).ConfigureAwait(false);

    private async Task ApplyTextureImportExceptionAsync(Exception exception) =>
        await ApplyExceptionAsync(exception, "texture_import_failed", TextureImport.ApplyFailed).ConfigureAwait(false);

    private async Task RefreshPublicationAfterOperationAsync(string? projectName, string profile, CancellationToken cancellationToken)
    {
        if (!Capabilities.CanReadPublicationSnapshot) { return; }
        try
        {
            await RefreshPublicationAsync(projectName, profile, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            // Authoring/Bake 已完成；发布快照失败只影响诊断，不伪装成源事务失败。
        }
    }

    private async Task RefreshBehaviorContractAfterOperationAsync(string? projectName, CancellationToken cancellationToken)
    {
        if (!Capabilities.CanReadBehaviorContract) return;
        try { await RefreshBehaviorContractAsync(projectName, cancellationToken).ConfigureAwait(false); }
        catch { }
    }

    private void EnsureManualBakeAllowed()
    {
        // 派生目录同一时刻只允许一个持续写入者，避免手动 bake 与 watcher 交错提交 manifest/artifact。
        if (Watch.State is EditorWatchState.Starting or EditorWatchState.Watching or EditorWatchState.Stopping)
        {
            throw new EditorRpcException("publication_watch_owns_bake", "Stop the Service watch before running a manual bake.");
        }
        if (Preview.OwnsPublicationSync)
        {
            throw new EditorRpcException("publication_preview_owns_bake", "Preview live-bake/watch already owns publication synchronization.");
        }
    }

    private void ClearError()
    {
        LastErrorCode = null;
        LastErrorMessage = null;
    }

    public async ValueTask DisposeAsync()
    {
        Client.EventReceived -= HandleEventAsync;
        await ScriptDiagnostics.DisposeAsync().ConfigureAwait(false);
        try { await Client.DisposeAsync().ConfigureAwait(false); }
        finally { Client.ConnectionClosed -= HandleConnectionClosedAsync; }
    }
}
