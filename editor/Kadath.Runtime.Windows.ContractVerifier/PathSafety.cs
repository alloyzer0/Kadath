namespace Kadath.Runtime.Windows.ContractVerifier;

internal static class PathSafety
{
    private static readonly StringComparison Comparison = OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;

    public static string RequireExistingDirectory(string path, string name)
    {
        var fullPath = RequireLocalAbsolute(path, name);
        if (!Directory.Exists(fullPath))
            throw new VerifierFailure(FailureClassification.ProductContract, "preflight", $"{name} does not exist: {fullPath}");
        RejectReparsePointsInExistingChain(fullPath, name);
        return fullPath;
    }

    public static string RequireLocalAbsolute(string path, string name)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new VerifierFailure(FailureClassification.ProductContract, "preflight", $"{name} cannot be empty.");
        var windowsSpelling = path.Replace('/', '\\');
        if (windowsSpelling.StartsWith("\\\\", StringComparison.Ordinal)
            || windowsSpelling.StartsWith("\\??\\", StringComparison.Ordinal)
            || windowsSpelling.StartsWith("\\\\?\\", StringComparison.Ordinal)
            || !Path.IsPathFullyQualified(path))
        {
            throw new VerifierFailure(
                FailureClassification.ProductContract,
                "preflight",
                $"{name} must be a fully qualified local path: {path}");
        }
        return Path.GetFullPath(path);
    }

    public static void RejectReparsePointsInExistingChain(string path, string name)
    {
        var fullPath = Path.GetFullPath(path);
        var root = Path.GetPathRoot(fullPath)
            ?? throw new VerifierFailure(FailureClassification.ProductContract, "preflight", $"{name} has no path root: {fullPath}");
        var current = root;
        RejectIfReparsePoint(current, name);
        var relative = Path.GetRelativePath(root, fullPath);
        foreach (var segment in relative.Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (!Directory.Exists(current) && !File.Exists(current)) break;
            RejectIfReparsePoint(current, name);
        }
    }

    public static string ResolveRequiredFile(string root, string relativePath, string name)
    {
        if (Path.IsPathRooted(relativePath))
            throw new VerifierFailure(FailureClassification.ProductContract, "package_preflight", $"{name} path must be relative.");
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var candidate = Path.GetFullPath(Path.Combine(fullRoot, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        if (!candidate.StartsWith(fullRoot + Path.DirectorySeparatorChar, Comparison))
            throw new VerifierFailure(FailureClassification.ProductContract, "package_preflight", $"{name} escapes PackageRoot.");
        if (!File.Exists(candidate))
            throw new VerifierFailure(FailureClassification.ProductContract, "package_preflight", $"{name} does not exist: {candidate}");
        RejectReparsePointsInExistingChain(candidate, name);
        return candidate;
    }

    public static void RequireDisjoint(string left, string leftName, string right, string rightName)
    {
        if (Contains(left, right) || Contains(right, left))
        {
            throw new VerifierFailure(
                FailureClassification.ProductContract,
                "preflight",
                $"{leftName} and {rightName} must be disjoint: {left} <> {right}");
        }
    }

    public static bool PathsEqual(string left, string right) =>
        Path.GetFullPath(left).Equals(Path.GetFullPath(right), Comparison);

    private static bool Contains(string parent, string candidate)
    {
        var normalizedParent = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var normalizedCandidate = Path.GetFullPath(candidate).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return normalizedCandidate.Equals(normalizedParent, Comparison)
            || normalizedCandidate.StartsWith(normalizedParent + Path.DirectorySeparatorChar, Comparison);
    }

    private static void RejectIfReparsePoint(string path, string name)
    {
        var information = Directory.Exists(path) ? (FileSystemInfo)new DirectoryInfo(path) : new FileInfo(path);
        information.Refresh();
        if ((information.Attributes & FileAttributes.ReparsePoint) != 0 || information.LinkTarget is not null)
        {
            throw new VerifierFailure(
                FailureClassification.ProductContract,
                "preflight",
                $"{name} cannot traverse a reparse point: {path}");
        }
    }
}
