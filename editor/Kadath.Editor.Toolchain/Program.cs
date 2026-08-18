namespace Kadath.Editor.Toolchain;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "archive") return RunArchive(args);

        try
        {
            return args.Length == 0
                ? throw new ArgumentException("A toolchain command is required.")
                : args[0] switch
                {
                    "import" => RunImport(ImportOptions.Parse(args)),
                    "preflight" => RunPreflight(PreflightOptions.Parse(args)),
                    "snapshot" => RunSnapshot(SnapshotOptions.Parse(args)),
                    "build-profile" => RunBuildProfile(BuildProfileOptions.Parse(args)),
                    _ => throw new ArgumentException($"Unsupported toolchain command: {args[0]}.")
                };
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"toolchain_error={exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static int RunImport(ImportOptions options)
    {
        var result = ToolchainImport.Execute(new ToolchainImportRequest(
            options.Kind,
            options.SourcePath,
            options.DestinationPath,
            options.Profile));
        Console.WriteLine($"kind={result.Kind}");
        Console.WriteLine($"profile={result.Profile}");
        Console.WriteLine($"artifact_bytes={result.ArtifactBytes}");
        Console.WriteLine($"sha256={result.Sha256}");
        Console.WriteLine("verification=ok");
        return 0;
    }

    private static int RunSnapshot(SnapshotOptions options)
    {
        var result = ToolchainSourceSnapshot.Execute(new ToolchainSourceSnapshotRequest(
            options.SourcePath,
            options.DestinationPath,
            options.VerificationBarrierDirectory,
            options.FaultMode));
        Console.WriteLine($"snapshot={result.DestinationPath}");
        Console.WriteLine($"bytes={result.Length}");
        Console.WriteLine($"sha256={result.Sha256}");
        Console.WriteLine("verification=ok");
        return 0;
    }

    private static int RunPreflight(PreflightOptions options)
    {
        var result = ToolchainPreflight.Execute(new ToolchainPreflightRequest(
            options.PackageRoot,
            options.TaskLocalCacheDirectory,
            options.GlobalCacheDirectory,
            options.DestinationPath));
        Console.WriteLine($"preflight={result.DestinationPath}");
        Console.WriteLine($"generated_at_utc={result.GeneratedAtUtc:O}");
        Console.WriteLine("verification=ok");
        return 0;
    }

    private static int RunBuildProfile(BuildProfileOptions options)
    {
        var result = ToolchainBuildProfile.Execute(new ToolchainBuildProfileRequest(
            options.RuntimeExecutablePath,
            options.TextureSourcePath,
            options.TextureArtifactPath,
            options.SecondaryTextureSourcePath,
            options.SecondaryTextureArtifactPath,
            options.VertexShaderSourcePath,
            options.FragmentShaderSourcePath,
            options.Optimize,
            options.PackageRoot,
            options.TaskLocalCacheDirectory,
            options.GlobalCacheDirectory,
            options.PreflightSidecarPath,
            options.DestinationPath));
        Console.WriteLine($"profile={result.DestinationPath}");
        Console.WriteLine($"sha256={result.Sha256}");
        Console.WriteLine($"preflight_sha256={result.PreflightSidecarSha256 ?? "-"}");
        Console.WriteLine("verification=ok");
        return 0;
    }

    private static int RunArchive(string[] args)
    {
        try
        {
            var options = ArchiveOptions.Parse(args);
            return ToolchainRuntimeArchive.Run(
                new ToolchainRuntimeArchiveRequest(
                    options.PackageRoot,
                    options.OutputDirectory,
                    options.ExtractDirectory,
                    options.KadathRoot,
                    options.Policy,
                    options.VerificationBarrierDirectory),
                Console.Out,
                Console.Error);
        }
        catch (Exception exception)
        {
            // 参数或路径解析发生在归档事务之前，仍需保持旧契约的首写入见证。
            Console.Error.WriteLine("archive_write_started=false");
            Console.Error.WriteLine($"archive_error={exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static string FullPathOrDash(string value) =>
        value == "-" ? value : Path.GetFullPath(value);

    private sealed record ImportOptions(string Kind, string SourcePath, string DestinationPath, string Profile)
    {
        internal static ImportOptions Parse(string[] args)
        {
            if (args.Length != 7 || args[0] != "import")
                throw new ArgumentException("Usage: import <texture|audio|scene|script> <source> <destination> --profile <debug|release> --no-overwrite.");
            if (args[4] != "--profile" || args[5] is not ("debug" or "release") || args[6] != "--no-overwrite")
                throw new ArgumentException("Toolchain profile or overwrite policy is invalid.");
            return new ImportOptions(args[1], Path.GetFullPath(args[2]), Path.GetFullPath(args[3]), args[5]);
        }
    }

    private sealed record SnapshotOptions(
        string SourcePath,
        string DestinationPath,
        string? VerificationBarrierDirectory,
        string FaultMode)
    {
        internal static SnapshotOptions Parse(string[] args)
        {
            if (args.Length != 8 || args[0] != "snapshot" || args[3] != "--barrier" ||
                args[5] != "--fault" || args[7] != "--no-overwrite")
                throw new ArgumentException("Usage: snapshot <source> <destination> --barrier <directory|-> --fault <mode|-> --no-overwrite.");
            return new SnapshotOptions(
                Path.GetFullPath(args[1]),
                Path.GetFullPath(args[2]),
                FullPathOrDash(args[4]),
                args[6]);
        }
    }

    private sealed record PreflightOptions(
        string PackageRoot,
        string TaskLocalCacheDirectory,
        string GlobalCacheDirectory,
        string DestinationPath)
    {
        internal static PreflightOptions Parse(string[] args)
        {
            if (args.Length != 6 || args[0] != "preflight" || args[5] != "--no-overwrite")
                throw new ArgumentException("Usage: preflight <package-root> <local-cache> <global-cache> <destination> --no-overwrite.");
            return new PreflightOptions(
                Path.GetFullPath(args[1]),
                Path.GetFullPath(args[2]),
                Path.GetFullPath(args[3]),
                Path.GetFullPath(args[4]));
        }
    }

    private sealed record BuildProfileOptions(
        string RuntimeExecutablePath,
        string TextureSourcePath,
        string TextureArtifactPath,
        string SecondaryTextureSourcePath,
        string SecondaryTextureArtifactPath,
        string VertexShaderSourcePath,
        string FragmentShaderSourcePath,
        string Optimize,
        string PackageRoot,
        string TaskLocalCacheDirectory,
        string GlobalCacheDirectory,
        string? PreflightSidecarPath,
        string DestinationPath)
    {
        internal static BuildProfileOptions Parse(string[] args)
        {
            if (args.Length != 15 || args[0] != "build-profile" || args[14] != "--no-overwrite")
                throw new ArgumentException("Usage: build-profile <runtime> <texture-source> <texture-artifact> <secondary-source> <secondary-artifact> <vertex-shader> <fragment-shader> <optimize> <package-root> <local-cache> <global-cache> <preflight|-> <destination> --no-overwrite.");
            return new BuildProfileOptions(
                Path.GetFullPath(args[1]),
                Path.GetFullPath(args[2]),
                Path.GetFullPath(args[3]),
                Path.GetFullPath(args[4]),
                Path.GetFullPath(args[5]),
                Path.GetFullPath(args[6]),
                Path.GetFullPath(args[7]),
                args[8],
                Path.GetFullPath(args[9]),
                Path.GetFullPath(args[10]),
                Path.GetFullPath(args[11]),
                FullPathOrDash(args[12]),
                Path.GetFullPath(args[13]));
        }
    }

    private sealed record ArchiveOptions(
        string PackageRoot,
        string OutputDirectory,
        string ExtractDirectory,
        string KadathRoot,
        ToolchainRuntimePackagePolicy Policy,
        string? VerificationBarrierDirectory)
    {
        internal static ArchiveOptions Parse(string[] args)
        {
            if (args.Length != 10 || args[0] != "archive" || args[5] != "--policy" ||
                args[7] != "--barrier" || args[9] != "--no-overwrite")
                throw new ArgumentException("Usage: archive <package-root> <output-dir> <extract-dir> <kadath-root> --policy <kscp-v1|kscp-v2> --barrier <directory|-> --no-overwrite.");
            var policy = args[6] switch
            {
                "kscp-v1" => ToolchainRuntimePackagePolicy.KscpV1,
                "kscp-v2" => ToolchainRuntimePackagePolicy.KscpV2,
                _ => throw new ArgumentException($"Unsupported Runtime package policy: {args[6]}.")
            };
            return new ArchiveOptions(
                Path.GetFullPath(args[1]),
                Path.GetFullPath(args[2]),
                Path.GetFullPath(args[3]),
                Path.GetFullPath(args[4]),
                policy,
                FullPathOrDash(args[8]));
        }
    }

}
