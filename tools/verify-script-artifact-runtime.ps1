[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$ConfigPath,

    [ValidateRange(250, 300000)]
    [int]$StopAfterMilliseconds = 1500,

    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-ExistingDirectory([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Name does not exist: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-PackagePath([string]$Root, [string]$RelativePath, [string]$Name, [ValidateSet('Leaf', 'Container')][string]$Kind) {
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "$Name must be relative to package root: $RelativePath" }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    # Runtime artifact verifier 与 Launcher 使用同一 package boundary，拒绝配置越界。
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "$Name escapes package root: $RelativePath" }
    $pathType = if ($Kind -eq 'Leaf') { 'Leaf' } else { 'Container' }
    if (-not (Test-Path -LiteralPath $fullPath -PathType $pathType)) { throw "$Name does not exist: $RelativePath" }
    return $fullPath
}

function Get-Argument([object]$Config, [string]$Option) {
    if ($null -eq $Config.runtime -or $null -eq $Config.runtime.arguments) { throw 'Preview config is missing runtime.arguments' }
    $arguments = @($Config.runtime.arguments)
    for ($index = 0; $index -lt $arguments.Count - 1; $index++) {
        if ([string]$arguments[$index] -eq $Option) {
            $value = [string]$arguments[$index + 1]
            if ([string]::IsNullOrWhiteSpace($value)) { throw "Preview config $Option argument is empty" }
            return $value
        }
    }
    throw "Preview config does not define $Option"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'editor-preview.example.json' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $env:TEMP ("kadath-m4-23-script-runtime-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
}
if (Test-Path -LiteralPath $OutputDirectory) { throw "Output directory already exists; refusing to overwrite: $OutputDirectory" }

$package = Resolve-ExistingDirectory $PackageRoot 'Package root'
$configFile = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$workingDirectoryRelative = [string]$config.runtime.workingDirectory
$workingDirectory = Resolve-PackagePath $package $workingDirectoryRelative 'Runtime working directory' 'Container'
$scriptRelativePath = Get-Argument $config '--script'
if (-not $scriptRelativePath.EndsWith('.script', [StringComparison]::OrdinalIgnoreCase)) { throw "Runtime script argument must point to .script artifact: $scriptRelativePath" }
if ([IO.Path]::IsPathRooted($scriptRelativePath)) { throw "Runtime script argument must be relative: $scriptRelativePath" }
$artifactRelativePath = [IO.Path]::GetRelativePath($package, [IO.Path]::GetFullPath((Join-Path $workingDirectory $scriptRelativePath))).Replace('\', '/')
$artifact = Resolve-PackagePath $package $artifactRelativePath 'Script artifact' 'Leaf'

$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$stdoutPath = Join-Path $output 'preview.stdout.jsonl'
$stderrPath = Join-Path $output 'preview.stderr.log'
$previewScript = Join-Path $PSScriptRoot 'editor-preview.ps1'
$process = $null
try {
    # StructuredStatus 将 Runtime stderr 中的 artifact 日志转成 JSONL，避免只验证 Launcher 自己的状态。
    $arguments = @('-NoProfile', '-File', $previewScript, '-ConfigPath', $configFile, '-PackageRoot', $package, '-StructuredStatus', '-StopAfterMilliseconds', [string]$StopAfterMilliseconds)
    $process = Start-Process -FilePath 'pwsh' -ArgumentList $arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    if (-not $process.WaitForExit([Math]::Max(10000, $StopAfterMilliseconds + 15000))) { throw 'Script artifact preview did not exit' }

    $events = @(Get-Content -LiteralPath $stdoutPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { throw "Invalid structured preview output: $_" }
    })
    $artifactLogs = @($events | Where-Object { $_.event -eq 'runtime_log' -and [string]$_.message -match 'Loaded script artifact: .*artifact_version=1, instructions=2' })
    if ($artifactLogs.Count -ne 1) { throw "Expected one KSCP artifact load log, got $($artifactLogs.Count)" }
    $exitEvents = @($events | Where-Object { $_.event -eq 'launcher_status' -and $_.name -eq 'runtime_exit_code' -and [string]$_.value -eq '0' })
    if ($exitEvents.Count -ne 1) { throw 'runtime_exit_code=0 evidence missing' }
    $previewEvents = @($events | Where-Object { $_.event -eq 'launcher_status' -and $_.name -eq 'preview' -and [string]$_.value -eq 'ok' })
    if ($previewEvents.Count -ne 1) { throw 'preview=ok evidence missing' }
    if ($process.ExitCode -ne 0) { throw "Preview launcher exited with code $($process.ExitCode)" }

    Write-Output "artifact=$scriptRelativePath"
    Write-Output "artifact_bytes=$((Get-Item -LiteralPath $artifact).Length)"
    Write-Output 'artifact_load_log=ok'
    Write-Output 'runtime_exit_code=0'
    Write-Output 'preview=ok'
    Write-Output 'verification=ok'
} finally {
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
}