using System.Text.Json.Serialization;

namespace Kadath.Runtime.Windows.ContractVerifier;

internal sealed record VerificationRequest(
    string PackageRoot,
    string EvidenceDirectory,
    TimeSpan OverallTimeout);

internal enum VerificationStatus
{
    Pass,
    Fail,
    BlockedEnvironment
}

internal enum FailureClassification
{
    None,
    ProductContract,
    PackageIdentity,
    GpuEnvironment,
    AudioEnvironment,
    WindowEnvironment,
    UnsupportedPlatform,
    Timeout,
    EvidenceIo,
    Internal
}

internal static class VerificationNames
{
    public static string ToWireName(this VerificationStatus status) => status switch
    {
        VerificationStatus.Pass => "PASS",
        VerificationStatus.Fail => "FAIL",
        VerificationStatus.BlockedEnvironment => "BLOCKED_ENV",
        _ => "FAIL"
    };

    public static string ToWireName(this FailureClassification classification) => classification switch
    {
        FailureClassification.None => "none",
        FailureClassification.ProductContract => "product_contract",
        FailureClassification.PackageIdentity => "package_identity",
        FailureClassification.GpuEnvironment => "gpu_environment",
        FailureClassification.AudioEnvironment => "audio_environment",
        FailureClassification.WindowEnvironment => "window_environment",
        FailureClassification.UnsupportedPlatform => "unsupported_platform",
        FailureClassification.Timeout => "timeout",
        FailureClassification.EvidenceIo => "evidence_io",
        _ => "internal"
    };

    public static bool IsEnvironmentBlock(this FailureClassification classification) => classification is
        FailureClassification.GpuEnvironment
        or FailureClassification.AudioEnvironment
        or FailureClassification.WindowEnvironment
        or FailureClassification.UnsupportedPlatform;
}

internal sealed class VerifierFailure : Exception
{
    public VerifierFailure(FailureClassification classification, string stage, string message, Exception? inner = null)
        : base(message, inner)
    {
        Classification = classification;
        Stage = stage;
    }

    public FailureClassification Classification { get; }
    public string Stage { get; }
}

internal sealed record VerificationOutcome(
    VerificationStatus Status,
    FailureClassification Classification,
    string? FirstError,
    string EvidenceDirectory,
    string StatusPath,
    string ManifestPath);

internal sealed record FileIdentity(
    long Length,
    string Sha256,
    uint VolumeSerialNumber,
    ulong FileIndex);

internal sealed record RuntimeTargetIdentity(string Kind, string Sha256, ulong Bytes);

internal sealed record RuntimeInitialLoadedEvidence(
    ulong Sequence,
    RuntimeTargetIdentity Scene,
    RuntimeTargetIdentity Script);

internal sealed record Rgb(int R, int G, int B)
{
    public int MaximumChannelDifference(Rgb other) =>
        Math.Max(Math.Abs(R - other.R), Math.Max(Math.Abs(G - other.G), Math.Abs(B - other.B)));
}

internal sealed record PixelPointEvidence(
    int LogicalX,
    int LogicalY,
    int PhysicalX,
    int PhysicalY,
    Rgb Actual,
    Rgb Expected,
    int MaximumChannelError);

internal sealed class PixelEvidence
{
    public bool Passed { get; set; }
    public bool NonEmpty { get; set; }
    public int DistinctColorCount { get; set; }
    public long NonBlackPixelCount { get; set; }
    public int CompositeTolerance { get; set; }
    public int GoalTolerance { get; set; }
    public int MaximumChannelError { get; set; }
    public int GoalMaximumChannelError { get; set; }
    public double ScaleX { get; set; }
    public double ScaleY { get; set; }
    public Dictionary<string, PixelPointEvidence> Samples { get; set; } = new(StringComparer.Ordinal);
    public string[] ConsecutivePassTimesUtc { get; set; } = [];
}

internal sealed record InputEventEvidence(string Key, string Action, string AtUtc);

internal sealed record PlayerMovementEvidence(
    int LogicalX,
    int LogicalY,
    int PhysicalX,
    int PhysicalY,
    Rgb Before,
    Rgb After,
    Rgb ExpectedBackground,
    int BeforeAfterDifference,
    int AfterBackgroundError,
    bool Passed);

internal sealed class RuntimeVerificationManifest
{
    public int VerificationVersion { get; set; } = 1;
    public string Status { get; set; } = "FAIL";
    public string Classification { get; set; } = "internal";
    public string Stage { get; set; } = "preflight";
    public string? FirstError { get; set; }
    public string? CleanupError { get; set; }
    public string StartedAtUtc { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public string? EndedAtUtc { get; set; }
    public string PackageRoot { get; set; } = string.Empty;
    public string EvidenceDirectory { get; set; } = string.Empty;
    public string RuntimeExecutable { get; set; } = string.Empty;
    public string Optimize { get; set; } = string.Empty;
    public string? BuildPreflightSidecarSha256 { get; set; }
    public string[] RuntimeArguments { get; set; } = [];
    public int RuntimePid { get; set; }
    public int? RuntimeExitCode { get; set; }
    public bool ForcedProcessTreeKill { get; set; }
    public bool ProcessTreeStopped { get; set; }
    public string WindowHandle { get; set; } = "0x0";
    public uint WindowOwnerPid { get; set; }
    public string WindowClass { get; set; } = string.Empty;
    public uint WindowDpi { get; set; }
    public bool WindowVisible { get; set; }
    public bool WindowUnobscured { get; set; }
    public bool ForegroundAcquired { get; set; }
    public int ClientWidth { get; set; }
    public int ClientHeight { get; set; }
    public int RenderWidth { get; set; }
    public int RenderHeight { get; set; }
    public uint SwapchainFormat { get; set; }
    public RuntimeInitialLoadedEvidence? InitialLoaded { get; set; }
    public PixelEvidence? Pixels { get; set; }
    public PlayerMovementEvidence? PlayerMovementSample { get; set; }
    public List<InputEventEvidence> InputEvents { get; set; } = [];
    public bool RestartObserved { get; set; }
    public bool PlayerMovementObserved { get; set; }
    public bool WonObserved { get; set; }
    public bool LostAudioCueObserved { get; set; }
    public bool WonAudioCueObserved { get; set; }
    public bool WmClosePosted { get; set; }
    public bool RuntimeStoppingWindowCloseObserved { get; set; }
    public Dictionary<string, FileIdentity> PackageIdentityBefore { get; set; } = new(StringComparer.Ordinal);
    public Dictionary<string, FileIdentity> PackageIdentityAfter { get; set; } = new(StringComparer.Ordinal);
    public string? StdoutSha256 { get; set; }
    public string? StderrSha256 { get; set; }
    public string? ScreenshotSha256 { get; set; }
    public string? MovementScreenshotSha256 { get; set; }
    public string[] RequiredLogMarkers { get; set; } = [];

    [JsonIgnore]
    public string? RawStdout { get; set; }

    [JsonIgnore]
    public string? RawStderr { get; set; }
}

internal sealed record VerificationStatusDocument(
    int VerificationVersion,
    string Status,
    string Classification,
    string Stage,
    string? FirstError,
    string? CleanupError,
    string StartedAtUtc,
    string EndedAtUtc,
    string ManifestPath,
    string StdoutPath,
    string StderrPath,
    string? ScreenshotPath,
    string? MovementScreenshotPath);
