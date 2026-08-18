using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Kadath.Runtime.Windows.ContractVerifier;

internal sealed class EvidenceStore
{
    private static readonly UTF8Encoding Utf8NoBom = new(false);
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private EvidenceStore(string root)
    {
        Root = root;
        StatusPath = Path.Combine(root, "status.json");
        ManifestPath = Path.Combine(root, "manifest.json");
        StdoutPath = Path.Combine(root, "runtime.stdout.log");
        StderrPath = Path.Combine(root, "runtime.stderr.log");
        ScreenshotPath = Path.Combine(root, "runtime-client.png");
        MovementScreenshotPath = Path.Combine(root, "runtime-player-after-up.png");
        PixelEvidencePath = Path.Combine(root, "pixel-evidence.json");
    }

    public string Root { get; }
    public string StatusPath { get; }
    public string ManifestPath { get; }
    public string StdoutPath { get; }
    public string StderrPath { get; }
    public string ScreenshotPath { get; }
    public string MovementScreenshotPath { get; }
    public string PixelEvidencePath { get; }

    public static EvidenceStore Create(string packageRoot, string requestedRoot)
    {
        var root = PathSafety.RequireLocalAbsolute(requestedRoot, "EvidenceDirectory");
        if (Directory.Exists(root) || File.Exists(root))
            throw new VerifierFailure(FailureClassification.EvidenceIo, "evidence_create", $"EvidenceDirectory already exists: {root}");
        if (root.Equals(Path.GetPathRoot(root), StringComparison.OrdinalIgnoreCase))
            throw new VerifierFailure(FailureClassification.EvidenceIo, "evidence_create", "EvidenceDirectory cannot be a filesystem root.");
        var parent = Path.GetDirectoryName(root)
            ?? throw new VerifierFailure(FailureClassification.EvidenceIo, "evidence_create", "EvidenceDirectory has no parent.");
        if (!Directory.Exists(parent))
            throw new VerifierFailure(FailureClassification.EvidenceIo, "evidence_create", $"EvidenceDirectory parent does not exist: {parent}");
        PathSafety.RejectReparsePointsInExistingChain(parent, "EvidenceDirectory parent");
        PathSafety.RequireDisjoint(packageRoot, "PackageRoot", root, "EvidenceDirectory");

        try
        {
            Directory.CreateDirectory(root);
            PathSafety.RejectReparsePointsInExistingChain(root, "EvidenceDirectory");
        }
        catch (VerifierFailure) { throw; }
        catch (Exception exception)
        {
            throw new VerifierFailure(FailureClassification.EvidenceIo, "evidence_create", $"Cannot create EvidenceDirectory: {root}", exception);
        }
        return new EvidenceStore(root);
    }

    public void WriteLogs(string stdout, string stderr)
    {
        File.WriteAllText(StdoutPath, NormalizeLog(stdout), Utf8NoBom);
        File.WriteAllText(StderrPath, NormalizeLog(stderr), Utf8NoBom);
    }

    public void WriteManifest(RuntimeVerificationManifest manifest) => WriteJson(ManifestPath, manifest);

    public void WriteStatus(VerificationStatusDocument status) => WriteJson(StatusPath, status);

    public void WritePixels(PixelEvidence pixels) => WriteJson(PixelEvidencePath, pixels);

    public static string HashFile(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static void WriteJson<T>(string path, T document)
    {
        var json = JsonSerializer.Serialize(document, JsonOptions);
        File.WriteAllText(path, json + Environment.NewLine, Utf8NoBom);
    }

    private static string NormalizeLog(string value) =>
        value.Length == 0 ? string.Empty : value.TrimEnd('\r', '\n') + Environment.NewLine;
}
