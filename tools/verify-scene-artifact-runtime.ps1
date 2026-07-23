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
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Name does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-PackageFile([string]$Root, [string]$RelativePath, [string]$Name) {
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Name must be relative to the package root: $RelativePath"
    }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    # 关键安全边界：配置中的 Scene 路径只能解析到待验证的 Runtime package 内。
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes the package root: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Name does not exist in the package: $RelativePath"
    }
    return $fullPath
}

function Resolve-PackageDirectory([string]$Root, [string]$RelativePath, [string]$Name) {
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Name must be relative to the package root: $RelativePath"
    }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    # workingDirectory 也必须受同一 package 边界约束，避免配置将 Runtime 引向外部目录。
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes the package root: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "$Name does not exist in the package: $RelativePath"
    }
    return $fullPath
}

function Get-SceneArgument([object]$Config) {
    if ($null -eq $Config.runtime) { throw 'Preview config is missing runtime' }
    if ($null -eq $Config.runtime.arguments) { throw 'Preview config is missing runtime.arguments' }
    $arguments = @($Config.runtime.arguments)
    for ($index = 0; $index -lt $arguments.Count - 1; $index++) {
        if ([string]$arguments[$index] -eq '--scene') {
            $scene = [string]$arguments[$index + 1]
            if ([string]::IsNullOrWhiteSpace($scene)) { throw 'Preview config --scene argument is empty' }
            return $scene
        }
    }
    throw 'Preview config does not define --scene'
}

function Get-WorkingDirectoryArgument([object]$Config) {
    if ($null -eq $Config.runtime) { throw 'Preview config is missing runtime' }
    if ($null -eq $Config.runtime.workingDirectory) { throw 'Preview config is missing runtime.workingDirectory' }
    $workingDirectory = [string]$Config.runtime.workingDirectory
    if ([string]::IsNullOrWhiteSpace($workingDirectory)) { throw 'Preview config runtime.workingDirectory is empty' }
    return $workingDirectory
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'editor-preview.example.json'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $env:TEMP ("kadath-m4-22-scene-runtime-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
}
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Output directory already exists; refusing to overwrite: $OutputDirectory"
}

$package = Resolve-ExistingDirectory $PackageRoot 'Package root'
$configFile = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$workingDirectoryRelative = Get-WorkingDirectoryArgument $config
$workingDirectory = Resolve-PackageDirectory $package $workingDirectoryRelative 'Runtime working directory'
$sceneRelativePath = Get-SceneArgument $config
if (-not $sceneRelativePath.EndsWith('.scene', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Runtime scene argument must point to a .scene artifact: $sceneRelativePath"
}

# editor-preview 将 runtime.arguments 相对 workingDirectory 解析；这里复现同一规则，
# 因而示例中的 `workingDirectory=bin` + `--scene assets/...` 会落到 package/bin/assets/...
if ([IO.Path]::IsPathRooted($sceneRelativePath)) {
    throw "Scene argument must be relative to runtime.workingDirectory: $sceneRelativePath"
}
$scenePackagePath = [IO.Path]::GetRelativePath(
    $package,
    [IO.Path]::GetFullPath((Join-Path $workingDirectory $sceneRelativePath))
).Replace('\', '/')
$artifact = Resolve-PackageFile $package $scenePackagePath 'Scene artifact'

$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$stdoutPath = Join-Path $output 'preview.stdout.jsonl'
$stderrPath = Join-Path $output 'preview.stderr.log'
$previewScript = Join-Path $PSScriptRoot 'editor-preview.ps1'
$process = $null

try {
    # 结构化模式把 Runtime stderr（含 artifact 加载日志）转成可断言的 JSONL 事件。
    $arguments = @(
        '-NoProfile', '-File', $previewScript,
        '-ConfigPath', $configFile,
        '-PackageRoot', $package,
        '-StructuredStatus',
        '-StopAfterMilliseconds', [string]$StopAfterMilliseconds
    )
    $process = Start-Process -FilePath 'pwsh' -ArgumentList $arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    if (-not $process.WaitForExit([Math]::Max(10000, $StopAfterMilliseconds + 15000))) {
        throw 'Scene artifact preview did not exit after StopAfterMilliseconds'
    }

    $lines = @(Get-Content -LiteralPath $stdoutPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $events = @($lines | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { throw "Invalid structured preview output: $_" }
    })
    $artifactLogs = @($events | Where-Object {
        $_.event -eq 'runtime_log' -and
        [string]$_.message -match 'Loaded preview scene artifact: .*artifact_version=1'
    })
    if ($artifactLogs.Count -ne 1) {
        throw "Expected one KSCN artifact load log with artifact_version=1, got $($artifactLogs.Count)"
    }

    $exitEvents = @($events | Where-Object {
        $_.event -eq 'launcher_status' -and $_.name -eq 'runtime_exit_code' -and [string]$_.value -eq '0'
    })
    if ($exitEvents.Count -ne 1) { throw 'runtime_exit_code=0 evidence missing' }
    $previewEvents = @($events | Where-Object {
        $_.event -eq 'launcher_status' -and $_.name -eq 'preview' -and [string]$_.value -eq 'ok'
    })
    if ($previewEvents.Count -ne 1) { throw 'preview=ok evidence missing' }
    if ($process.ExitCode -ne 0) { throw "Preview launcher exited with code $($process.ExitCode)" }

    Write-Output "artifact=$scenePackagePath"
    Write-Output "artifact_bytes=$((Get-Item -LiteralPath $artifact).Length)"
    Write-Output 'artifact_load_log=ok'
    Write-Output 'runtime_exit_code=0'
    Write-Output 'preview=ok'
    Write-Output 'verification=ok'
} finally {
    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
}
