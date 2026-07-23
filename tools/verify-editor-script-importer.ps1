[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\scripts\preview.script.json'),
    [string]$OutputDirectory = (Join-Path $env:TEMP ("kadath-script-importer-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (Test-Path -LiteralPath $OutputDirectory) { throw "Output directory already exists; refusing to overwrite: $OutputDirectory" }
$source = (Resolve-Path -LiteralPath $SourcePath).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$importer = Join-Path $PSScriptRoot 'editor-script-importer.ps1'
$sourceHashBefore = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()

function Invoke-Importer([string[]]$Arguments, [switch]$ExpectFailure) {
    $lines = @(& pwsh -NoProfile -File $importer @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if (-not $ExpectFailure -and $exitCode -ne 0) { throw "Script importer failed with code $exitCode; $($lines -join ' | ')" }
    if ($ExpectFailure -and $exitCode -eq 0) { throw 'Script importer unexpectedly accepted invalid input' }
    return $lines
}

function Read-LittleU32([byte[]]$Bytes, [int]$Offset) {
    return [uint32]$Bytes[$Offset] -bor ([uint32]$Bytes[$Offset + 1] -shl 8) -bor ([uint32]$Bytes[$Offset + 2] -shl 16) -bor ([uint32]$Bytes[$Offset + 3] -shl 24)
}

function Assert-Artifact([string]$Path, [int]$ExpectedCount) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Script artifact missing: $Path" }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    $expectedBytes = 16 + $ExpectedCount * 16
    if ($bytes.Length -ne $expectedBytes) { throw "Unexpected Script artifact bytes: $($bytes.Length) != $expectedBytes" }
    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'KSCP') { throw 'Script artifact magic mismatch' }
    if ((Read-LittleU32 $bytes 4) -ne 1 -or (Read-LittleU32 $bytes 8) -ne 1) { throw 'Script artifact version/schema mismatch' }
    if ((Read-LittleU32 $bytes 12) -ne $ExpectedCount) { throw 'Script artifact instruction count mismatch' }
    if ((Read-LittleU32 $bytes 16) -ne 0 -or (Read-LittleU32 $bytes 20) -ne 0) { throw 'First Script instruction layout mismatch' }
    if ((Read-LittleU32 $bytes 32) -ne 1 -or (Read-LittleU32 $bytes 36) -ne 1) { throw 'Second Script instruction layout mismatch' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Text([string]$Path, [string]$Contents) {
    [IO.File]::WriteAllText($Path, $Contents, [Text.UTF8Encoding]::new($false))
}

try {
    $dryPath = Join-Path $output 'dry-run\preview.script'
    $dry = Invoke-Importer @('-SourcePath', $source, '-DestinationPath', $dryPath, '-Profile', 'debug', '-DryRun')
    $dryPlan = ($dry | Out-String).Trim() | ConvertFrom-Json
    if (-not [bool]$dryPlan.DryRun -or [int]$dryPlan.InstructionCount -ne 2 -or [int]$dryPlan.ArtifactBytes -ne 48 -or [string]$dryPlan.ArtifactFormat -cne 'KSCP-SCRIPT-V1') { throw 'Invalid Script importer dry-run plan' }
    if (Test-Path -LiteralPath $dryPath) { throw 'Script importer dry-run created an artifact' }

    $debugPath = Join-Path $output 'debug\preview.script'
    $releasePath = Join-Path $output 'release\preview.script'
    [void](Invoke-Importer @('-SourcePath', $source, '-DestinationPath', $debugPath, '-Profile', 'debug'))
    $debugHash = Assert-Artifact $debugPath 2
    [void](Invoke-Importer @('-SourcePath', $source, '-DestinationPath', $releasePath, '-Profile', 'release'))
    $releaseHash = Assert-Artifact $releasePath 2
    if ($debugHash -cne $releaseHash) { throw 'Debug and release Script artifacts are not byte-equivalent' }

    [void](Invoke-Importer @('-SourcePath', $source, '-DestinationPath', $debugPath, '-Profile', 'debug') -ExpectFailure)
    if (@(Get-ChildItem -LiteralPath $output -File -Recurse | Where-Object { $_.Name -like '*.tmp.*' }).Count -ne 0) { throw 'Temporary Script artifact files remain after overwrite rejection' }

    $invalidSchema = Join-Path $output 'invalid-schema.script.json'
    Write-Text $invalidSchema '{"schemaVersion":2,"instructions":[]}'
    [void](Invoke-Importer @('-SourcePath', $invalidSchema, '-DestinationPath', (Join-Path $output 'invalid-schema.script')) -ExpectFailure)

    $invalidHook = Join-Path $output 'invalid-hook.script.json'
    Write-Text $invalidHook '{"schemaVersion":1,"instructions":[{"hook":"on_start","op":"move_goal_velocity","value":[1,0]}]}'
    [void](Invoke-Importer @('-SourcePath', $invalidHook, '-DestinationPath', (Join-Path $output 'invalid-hook.script')) -ExpectFailure)

    $tooMany = Join-Path $output 'too-many.script.json'
    $instructions = @()
    for ($index = 0; $index -lt 17; $index++) { $instructions += '{"hook":"fixed_update","op":"move_goal_velocity","value":[0,0]}' }
    Write-Text $tooMany ('{"schemaVersion":1,"instructions":[' + ($instructions -join ',') + ']}')
    [void](Invoke-Importer @('-SourcePath', $tooMany, '-DestinationPath', (Join-Path $output 'too-many.script')) -ExpectFailure)

    $unknownProperty = Join-Path $output 'unknown-property.script.json'
    Write-Text $unknownProperty '{"schemaVersion":1,"instructions":[{"hook":"on_start","op":"set_goal_position","value":[1,2],"extra":true}]}'
    [void](Invoke-Importer @('-SourcePath', $unknownProperty, '-DestinationPath', (Join-Path $output 'unknown-property.script')) -ExpectFailure)

    $packagePath = Join-Path $output 'bin\assets\scripts\package-boundary.script'
    New-Item -ItemType Directory -Path (Split-Path -Parent $packagePath) -Force | Out-Null
    [void](Invoke-Importer @('-SourcePath', $source, '-DestinationPath', $packagePath) -ExpectFailure)

    $sourceHashAfter = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHashBefore -cne $sourceHashAfter) { throw 'Script source changed during importer verification' }

    Write-Output 'script_importer_version=1'
    Write-Output 'script_baker_version=1'
    Write-Output 'artifact_format=KSCP-SCRIPT-V1'
    Write-Output 'instruction_count=2'
    Write-Output 'artifact_bytes=48'
    Write-Output 'dry_run=ok'
    Write-Output 'debug_artifact=ok'
    Write-Output 'release_artifact=ok'
    Write-Output 'artifact_reproducibility=ok'
    Write-Output 'payload_layout=ok'
    Write-Output 'invalid_schema_rejected=ok'
    Write-Output 'invalid_instruction_rejected=ok'
    Write-Output 'instruction_budget_rejected=ok'
    Write-Output 'unknown_property_rejected=ok'
    Write-Output 'overwrite_rejected=ok'
    Write-Output 'package_boundary=ok'
    Write-Output 'source_immutable=ok'
    Write-Output 'atomic_write=ok'
    Write-Output 'verification=ok'
} finally {
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
}