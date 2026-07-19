[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [ValidateRange(0, 300000)]
    [int]$StopAfterMilliseconds = 0
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-ExistingDirectory([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Name does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Owner) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "$Owner is missing required property: $Name"
    }
    return $property.Value
}

function Resolve-PackagePath(
    [string]$Root,
    [string]$RelativePath,
    [string]$Name,
    [bool]$RequireDirectory
) {
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Name must be relative to the package root: $RelativePath"
    }

    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    # 关键边界：Editor 配置不能借由绝对路径或 .. 跳出已验证的 Runtime package。
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes the package root: $RelativePath"
    }

    $pathType = if ($RequireDirectory) { 'Container' } else { 'Leaf' }
    if (-not (Test-Path -LiteralPath $fullPath -PathType $pathType)) {
        throw "$Name does not exist in the package: $RelativePath"
    }
    return $fullPath
}

function Request-RuntimeClose([Diagnostics.Process]$Process) {
    if ($Process.HasExited) { return }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class KadathPreviewNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
"@

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $windowHandle = [IntPtr]::Zero
    while ([DateTime]::UtcNow -lt $deadline -and -not $Process.HasExited) {
        $Process.Refresh()
        $windowHandle = $Process.MainWindowHandle
        if ($windowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 100
    }

    if ($Process.HasExited) { return }
    if ($windowHandle -eq [IntPtr]::Zero) {
        throw "Runtime window was not ready before the close timeout"
    }

    # 关键生命周期约束：优先请求宿主正常关闭，让 Runtime 自己完成 GPU/音频资源清理。
    if (-not [KadathPreviewNative]::PostMessage($windowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
        throw "Failed to post WM_CLOSE to Runtime process"
    }
}

$configFile = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    (Resolve-Path -LiteralPath $ConfigPath).Path
} else {
    throw "Config file does not exist: $ConfigPath"
}
$package = Resolve-ExistingDirectory $PackageRoot "Package root"
$config = Get-Content -LiteralPath $configFile -Raw -Encoding utf8 | ConvertFrom-Json

$schemaVersion = Get-RequiredProperty $config "schemaVersion" "Preview config"
if ($schemaVersion -isnot [long] -and $schemaVersion -isnot [int]) {
    throw "Preview config schemaVersion must be an integer"
}
if ([int]$schemaVersion -ne 1) {
    throw "Unsupported preview config schemaVersion: $schemaVersion"
}

$runtime = Get-RequiredProperty $config "runtime" "Preview config"
$executableRelative = [string](Get-RequiredProperty $runtime "executable" "runtime")
$workingDirectoryRelative = [string](Get-RequiredProperty $runtime "workingDirectory" "runtime")
$executable = Resolve-PackagePath $package $executableRelative "Runtime executable" $false
$workingDirectory = Resolve-PackagePath $package $workingDirectoryRelative "Runtime working directory" $true

$arguments = @()
$argumentsProperty = $runtime.PSObject.Properties["arguments"]
if ($null -ne $argumentsProperty -and $null -ne $argumentsProperty.Value) {
    foreach ($argument in @($argumentsProperty.Value)) {
        if ($argument -isnot [string]) { throw "runtime.arguments must contain only strings" }
        $arguments += $argument
    }
}

Write-Output "preview_contract=1"
Write-Output "runtime_executable=$executable"
Write-Output "runtime_working_directory=$workingDirectory"

$process = $null
try {
    $process = Start-Process -FilePath $executable -WorkingDirectory $workingDirectory -ArgumentList $arguments -PassThru
    Write-Output "runtime_pid=$($process.Id)"

    if ($StopAfterMilliseconds -gt 0) {
        if (-not $process.WaitForExit($StopAfterMilliseconds)) {
            Request-RuntimeClose $process
        }
        if (-not $process.WaitForExit(10000)) {
            throw "Runtime did not exit within 10 seconds after the close request"
        }
    } else {
        # 正常预览由用户关闭窗口；启动器保持进程所有权并等待 Runtime 自行结束。
        $process.WaitForExit()
    }
    if ($process.ExitCode -ne 0) {
        throw "Runtime exited with code $($process.ExitCode)"
    }

    Write-Output "runtime_exit_code=$($process.ExitCode)"
    Write-Output "preview=ok"
} finally {
    # 自动 smoke 失败时避免遗留孤儿进程；正常关闭路径不会进入强制终止。
    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
}
