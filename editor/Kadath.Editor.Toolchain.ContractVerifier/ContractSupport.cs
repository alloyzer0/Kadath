using System.Security.Cryptography;

namespace Kadath.Editor.Toolchain.ContractVerifier;

internal sealed class ContractSandbox : IDisposable
{
    private readonly string _temporaryRoot;

    internal ContractSandbox()
    {
        _temporaryRoot = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        Root = Path.GetFullPath(Path.Combine(_temporaryRoot, $"kadath-toolchain-contract-{Guid.NewGuid():N}"));
        if (!Root.StartsWith(_temporaryRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("ContractVerifier sandbox escaped the system temporary root.");
        Directory.CreateDirectory(Root);
    }

    internal string Root { get; }

    internal string NewCase(string name)
    {
        var path = Path.GetFullPath(Path.Combine(Root, $"{name}-{Guid.NewGuid():N}"));
        ContractAssert.Require(path.StartsWith(Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase), "case path escaped sandbox");
        Directory.CreateDirectory(path);
        return path;
    }

    public void Dispose()
    {
        if (!Directory.Exists(Root)) return;
        var resolved = Path.GetFullPath(Root);
        if (!resolved.StartsWith(_temporaryRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
            resolved.Equals(_temporaryRoot, StringComparison.OrdinalIgnoreCase))
            throw new IOException($"Refusing unsafe ContractVerifier cleanup: {resolved}");
        Directory.Delete(resolved, recursive: true);
    }
}

internal static class ContractAssert
{
    internal static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    internal static TException Throws<TException>(Action action, string? messageContains = null)
        where TException : Exception
    {
        try { action(); }
        catch (TException exception)
        {
            if (messageContains is not null)
                Require(exception.ToString().Contains(messageContains, StringComparison.Ordinal),
                    $"exception does not contain expected text '{messageContains}': {exception}");
            return exception;
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException($"expected {typeof(TException).Name}, got {exception.GetType().Name}: {exception}", exception);
        }
        throw new InvalidOperationException($"expected {typeof(TException).Name}, but operation succeeded");
    }

    internal static string Sha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    internal static byte[] ReadAll(string path) => File.ReadAllBytes(path);
}
