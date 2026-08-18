namespace Kadath.Runtime.Windows.ContractVerifier;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Length is not (2 or 4)
                || args.Length == 4 && !args[2].Equals("--timeout-seconds", StringComparison.Ordinal))
            {
                throw new ArgumentException(
                    "Usage: <packageRoot> <evidenceDirectory> [--timeout-seconds <10..120>]");
            }

            var timeoutSeconds = args.Length == 4 && int.TryParse(args[3], out var parsedTimeout)
                ? parsedTimeout
                : args.Length == 2
                    ? 45
                    : throw new ArgumentException("--timeout-seconds must be an integer.");
            if (timeoutSeconds is < 10 or > 120)
                throw new ArgumentOutOfRangeException(nameof(args), "--timeout-seconds must be in 10..120.");

            var request = new VerificationRequest(
                Path.GetFullPath(args[0]),
                Path.GetFullPath(args[1]),
                TimeSpan.FromSeconds(timeoutSeconds));
            var outcome = await new WindowsRuntimeProductVerifier().VerifyAsync(request).ConfigureAwait(false);

            Console.WriteLine($"status={outcome.Status.ToWireName()}");
            Console.WriteLine($"classification={outcome.Classification.ToWireName()}");
            Console.WriteLine($"evidence_directory={outcome.EvidenceDirectory}");
            Console.WriteLine($"status_path={outcome.StatusPath}");
            Console.WriteLine($"manifest_path={outcome.ManifestPath}");
            if (!string.IsNullOrWhiteSpace(outcome.FirstError))
                Console.Error.WriteLine($"first_error={outcome.FirstError}");
            Console.WriteLine(outcome.Status == VerificationStatus.Pass
                ? "verification=ok"
                : outcome.Status == VerificationStatus.BlockedEnvironment
                    ? "verification=blocked_env"
                    : "verification=failed");

            return outcome.Status switch
            {
                VerificationStatus.Pass => 0,
                VerificationStatus.Fail => 1,
                VerificationStatus.BlockedEnvironment => 2,
                _ => 1
            };
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"verification=failed: {exception}");
            return 1;
        }
    }
}
