[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$adapter = Join-Path $PSScriptRoot 'editor-live-bake.ps1'
if (-not (Test-Path -LiteralPath $adapter -PathType Leaf)) { throw "Live-bake adapter does not exist: $adapter" }
if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) { throw "Package root does not exist: $PackageRoot" }
$root = (Resolve-Path -LiteralPath $PackageRoot).Path
$projectName = "codex_live_bake_verify_$PID`_$([guid]::NewGuid().ToString('N'))"
$projectsRoot = Join-Path $root 'bin\projects'
$project = [IO.Path]::GetFullPath((Join-Path $projectsRoot $projectName))
$projectsPrefix = [IO.Path]::GetFullPath($projectsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $project.StartsWith($projectsPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe verifier project path' }

$sceneSource = Join-Path $project 'scene.json'
$scriptSource = Join-Path $project 'script.json'
$derived = Join-Path $project '.kadath\derived'
$sceneArtifact = Join-Path $derived 'scene.scene'
$scriptArtifact = Join-Path $derived 'script.script'
$manifest = Join-Path $derived '.live-bake.manifest.json'

function Invoke-Adapter([string]$Target, [switch]$ExpectFailure, [string]$SceneDestination = $sceneArtifact, [string]$ScriptDestination = $scriptArtifact, [string]$ManifestDestination = $manifest) {
    $lines = @(& pwsh -NoProfile -File $adapter -PackageRoot $root -SceneSourcePath $sceneSource -ScriptSourcePath $scriptSource -SceneArtifactPath $SceneDestination -ScriptArtifactPath $ScriptDestination -ManifestPath $ManifestDestination -Target $Target -Profile debug 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    $result = $null
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        try { $candidate = $lines[$index] | ConvertFrom-Json; if ([string]$candidate.event -eq 'live_bake_result') { $result = $candidate; break } } catch { }
    }
    if ($null -eq $result) { throw "Adapter emitted no live_bake_result: $($lines -join ' | ')" }
    if ($ExpectFailure -and $exitCode -eq 0) { throw "Adapter unexpectedly accepted target $Target" }
    if (-not $ExpectFailure -and ($exitCode -ne 0 -or [string]$result.result -ne 'succeeded')) { throw "Adapter failed target $Target`: $($result.message)" }
    return $result
}

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Json([object]$Value, [string]$Path) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

try {
    New-Item -ItemType Directory -Path $project -Force | Out-Null
    [IO.File]::Copy((Join-Path $root 'bin\assets\scenes\preview.scene.json'), $sceneSource)
    [IO.File]::Copy((Join-Path $root 'bin\assets\scripts\preview.script.json'), $scriptSource)

    $initial = Invoke-Adapter 'Both'
    if ([string]::IsNullOrWhiteSpace([string]$initial.sourceRevision.scene) -or [string]::IsNullOrWhiteSpace([string]$initial.artifactRevision.script) -or [int]$initial.artifactBytes.scene -ne 258) { throw 'Live-bake result revision/bytes contract mismatch' }
    if (@($initial.entries).Count -ne 2) { throw 'Initial bake did not report two entries' }
    if ((Get-Item -LiteralPath $sceneArtifact).Length -ne 258 -or (Get-Item -LiteralPath $scriptArtifact).Length -lt 16) { throw 'Initial artifact sizes are invalid' }
    $sceneInitialHash = Get-Hash $sceneArtifact
    $scriptInitialHash = Get-Hash $scriptArtifact

    $scene = Get-Content -LiteralPath $sceneSource -Raw -Encoding utf8 | ConvertFrom-Json
    $scene.goal.position = @(641.0, 241.0)
    Write-Json $scene $sceneSource
    [void](Invoke-Adapter 'Scene')
    $sceneChangedHash = Get-Hash $sceneArtifact
    if ($sceneChangedHash -eq $sceneInitialHash) { throw 'Scene-only bake did not change the Scene artifact' }
    if ((Get-Hash $scriptArtifact) -ne $scriptInitialHash) { throw 'Scene-only bake changed the Script artifact' }

    $script = Get-Content -LiteralPath $scriptSource -Raw -Encoding utf8 | ConvertFrom-Json
    $script.instructions[1].value = @(23.0, 0.0)
    Write-Json $script $scriptSource
    [void](Invoke-Adapter 'Script')
    if ((Get-Hash $sceneArtifact) -ne $sceneChangedHash) { throw 'Script-only bake changed the Scene artifact' }
    $scriptChangedHash = Get-Hash $scriptArtifact
    if ($scriptChangedHash -eq $scriptInitialHash) { throw 'Script-only bake did not change the Script artifact' }

    $manifestHashBeforeFailure = Get-Hash $manifest
    [IO.File]::WriteAllText($sceneSource, '{', [Text.UTF8Encoding]::new($false))
    $failure = Invoke-Adapter 'Scene' -ExpectFailure
    if ([string]$failure.errorCode -ne 'bake_validation_failed') { throw "Unexpected failure code: $($failure.errorCode)" }
    if ((Get-Hash $sceneArtifact) -ne $sceneChangedHash -or (Get-Hash $scriptArtifact) -ne $scriptChangedHash -or (Get-Hash $manifest) -ne $manifestHashBeforeFailure) { throw 'Failed bake changed the last successful transaction' }

    [IO.File]::Copy((Join-Path $root 'bin\assets\scenes\preview.scene.json'), $sceneSource, $true)
    [void](Invoke-Adapter 'Scene')

    $blockedScene = Join-Path $root 'bin\assets\scenes\live-bake-blocked.scene'
    [void](Invoke-Adapter 'Both' -ExpectFailure -SceneDestination $blockedScene)
    if (Test-Path -LiteralPath $blockedScene) { throw 'Package asset boundary test left an artifact' }

    $temporaryFiles = @(Get-ChildItem -LiteralPath $project -Recurse -File | Where-Object { $_.Name -match '\.live\.|\.source\.(scene|script)\.json$' })
    if ($temporaryFiles.Count -ne 0) { throw "Live-bake temporary files remain: $($temporaryFiles.FullName -join ', ')" }

    $manifestValue = Get-Content -LiteralPath $manifest -Raw -Encoding utf8 | ConvertFrom-Json
    if ([int]$manifestValue.schemaVersion -ne 1 -or [string]$manifestValue.profile -ne 'debug') { throw 'Manifest schema/profile mismatch' }
    if ([IO.Path]::IsPathRooted([string]$manifestValue.scene.sourcePath) -or [IO.Path]::IsPathRooted([string]$manifestValue.script.artifactPath)) { throw 'Manifest contains absolute paths' }

    Write-Output 'live_bake_adapter_version=1'
    Write-Output 'initial_bake=ok'
    Write-Output 'scene_incremental_bake=ok'
    Write-Output 'script_incremental_bake=ok'
    Write-Output 'failure_retains_last_success=ok'
    Write-Output 'package_assets_immutable=ok'
    Write-Output 'manifest=ok'
    Write-Output 'temporary_cleanup=ok'
    Write-Output 'verification=ok'
} finally {
    if (Test-Path -LiteralPath $project) {
        # 仅清理本 verifier 创建且已验证位于 bin/projects 下的隔离目录。
        Remove-Item -LiteralPath $project -Recurse -Force
    }
}
