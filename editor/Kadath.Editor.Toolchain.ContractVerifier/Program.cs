namespace Kadath.Editor.Toolchain.ContractVerifier;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            if (!OperatingSystem.IsWindows())
                throw new PlatformNotSupportedException("Toolchain ContractVerifier requires native Windows/NTFS semantics.");
            if (args.Length != 1)
                throw new ArgumentException("Usage: <kadath-root>");

            var kadathRoot = Path.GetFullPath(args[0]);
            using var sandbox = new ContractSandbox();
            ImportPublicationContract.Verify(sandbox, kadathRoot);
            AudioImportContract.Verify(sandbox);
            PreflightContract.Verify(sandbox);
            SourceSnapshotContract.Verify(sandbox);
            BuildProfileContract.Verify(sandbox);
            await RuntimeArchiveContract.VerifyAsync(sandbox, kadathRoot);

            Console.WriteLine("import_publication_contract=ok");
            Console.WriteLine("audio_import_contract=ok");
            Console.WriteLine("preflight_contract=ok");
            Console.WriteLine("source_snapshot_contract=ok");
            Console.WriteLine("build_profile_contract=ok");
            Console.WriteLine("runtime_archive_contract=ok");
            Console.WriteLine("retained_handle_mutation=ok");
            Console.WriteLine("pwsh_dependency=none");
            Console.WriteLine("verification=ok");
            await Task.CompletedTask;
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"verification=failed: {exception}");
            return 1;
        }
    }
}
