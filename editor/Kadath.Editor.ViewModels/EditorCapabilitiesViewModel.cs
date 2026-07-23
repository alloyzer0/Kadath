using Kadath.Editor.Protocol;

namespace Kadath.Editor.ViewModels;

public sealed class EditorCapabilitiesViewModel : ObservableObject
{
    private HashSet<string> _commands = new(StringComparer.Ordinal);
    private Dictionary<string, PreviewSurfaceCapability> _previewSurfaces = new(StringComparer.Ordinal);
    private bool _isLoaded;

    public bool IsLoaded
    {
        get => _isLoaded;
        private set => SetProperty(ref _isLoaded, value);
    }

    public IReadOnlyCollection<string> Commands => _commands;
    public bool CanOpenProject => SupportsCommand("project_open");
    public bool CanValidateProject => SupportsCommand("project_validate");
    public bool CanReadProjectSnapshot => SupportsCommand("project_snapshot");
    public bool CanReadHierarchySnapshot => SupportsCommand("hierarchy_snapshot");
    public bool CanReadAssetCatalogSnapshot => SupportsCommand("asset_catalog_snapshot");
    public bool CanReadPublicationSnapshot => SupportsCommand("publication_snapshot");
    public bool CanApplyAuthoring => SupportsCommand("authoring_apply");
    public bool CanUndoAuthoring => SupportsCommand("authoring_undo");
    public bool CanBake => SupportsCommand("bake_start");
    public bool CanStartWatch => SupportsCommand("watch_start");
    public bool CanStopWatch => SupportsCommand("watch_stop");
    public bool CanStartPreview => SupportsCommand("preview_start") && IsPreviewSurfaceImplemented(PreviewSurfaceModes.ExternalWindow);
    public bool CanStopPreview => SupportsCommand("preview_stop");
    public bool CanUseExternalWindow => IsPreviewSurfaceImplemented(PreviewSurfaceModes.ExternalWindow);
    public bool CanUseSharedTexture => IsPreviewSurfaceImplemented(PreviewSurfaceModes.SharedTexture);
    public bool CanUseFrameStream => IsPreviewSurfaceImplemented(PreviewSurfaceModes.FrameStream);

    public bool SupportsCommand(string command) => IsLoaded && _commands.Contains(command);

    public bool IsPreviewSurfaceImplemented(string mode) =>
        IsLoaded && _previewSurfaces.TryGetValue(mode, out var capability) && capability.Implemented;

    internal void Apply(EditorCapabilities capabilities)
    {
        _commands = new HashSet<string>(capabilities.Commands, StringComparer.Ordinal);
        _previewSurfaces = capabilities.PreviewSurfaces.ToDictionary(surface => surface.Mode, StringComparer.Ordinal);
        IsLoaded = true;
        RaisePropertyChanged(nameof(Commands));
        RaisePropertyChanged(nameof(CanOpenProject));
        RaisePropertyChanged(nameof(CanValidateProject));
        RaisePropertyChanged(nameof(CanReadProjectSnapshot));
        RaisePropertyChanged(nameof(CanReadHierarchySnapshot));
        RaisePropertyChanged(nameof(CanReadAssetCatalogSnapshot));
        RaisePropertyChanged(nameof(CanReadPublicationSnapshot));
        RaisePropertyChanged(nameof(CanBake));
        RaisePropertyChanged(nameof(CanStartWatch));
        RaisePropertyChanged(nameof(CanStopWatch));
        RaisePropertyChanged(nameof(CanStartPreview));
        RaisePropertyChanged(nameof(CanStopPreview));
        RaisePropertyChanged(nameof(CanUseExternalWindow));
        RaisePropertyChanged(nameof(CanUseSharedTexture));
        RaisePropertyChanged(nameof(CanUseFrameStream));
    }
}

