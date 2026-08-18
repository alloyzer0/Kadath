namespace Kadath.Editor.Workspace.ContractVerifier;

internal static class VerifierPlatform
{
    // Preview JSON 与磁盘 fixture 必须共享同一相对 identity，避免平台后缀分别演进。
    internal static string RuntimeRelativePath => OperatingSystem.IsWindows() ? "bin/kadath.exe" : "bin/kadath";
}
