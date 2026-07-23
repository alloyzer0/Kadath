[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\renderer2d\test.ppm'),
    [string]$GeneratedArtifact = (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out') 'bin\assets\renderer2d\test.texture'),
    [string]$OutputDirectory = (Join-Path $env:TEMP ("kadath-texture-importer-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tool = Join-Path $PSScriptRoot 'editor-texture-importer.ps1'
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Texture importer does not exist: $tool" }
$source = (Resolve-Path -LiteralPath $SourcePath).Path
$generated = (Resolve-Path -LiteralPath $GeneratedArtifact).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Output directory already exists: $output" }

function Invoke-TextureTool([string[]]$Arguments, [switch]$ExpectFailure) {
    $result = @(& pwsh -NoProfile -File $tool @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if (-not $ExpectFailure -and $exitCode -ne 0) { throw "Texture importer failed with code $exitCode`: $($result -join ' | ')" }
    if ($ExpectFailure -and $exitCode -eq 0) { throw 'Texture importer unexpectedly accepted invalid input' }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $result }
}

function Get-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Assert-V1Artifact([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Texture artifact missing: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne 36 -or [Text.Encoding]::ASCII.GetString($bytes[0..3]) -cne 'KDAT') { throw 'Unexpected KDAT v1 artifact header/size' }
    if ([BitConverter]::ToUInt32($bytes, 4) -ne 1 -or [BitConverter]::ToUInt32($bytes, 8) -ne 2 -or [BitConverter]::ToUInt32($bytes, 12) -ne 2 -or [BitConverter]::ToUInt32($bytes, 16) -ne 16) { throw 'Unexpected KDAT v1 dimensions/payload size' }
    $expectedPixels = [byte[]](255,40,40,255,40,255,40,255,40,40,255,255,255,230,40,255)
    for ($index = 0; $index -lt $expectedPixels.Length; $index++) { if ($bytes[20 + $index] -ne $expectedPixels[$index]) { throw "Unexpected v1 RGBA8 pixel at index $index" } }
    return Get-Hash $Path
}

function Assert-V2MipmapArtifact([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Texture artifact missing: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne 44 -or [Text.Encoding]::ASCII.GetString($bytes[0..3]) -cne 'KDAT') { throw 'Unexpected KDAT v2 artifact header/size' }
    if ([BitConverter]::ToUInt32($bytes, 4) -ne 2 -or [BitConverter]::ToUInt32($bytes, 8) -ne 2 -or [BitConverter]::ToUInt32($bytes, 12) -ne 2 -or [BitConverter]::ToUInt32($bytes, 16) -ne 2 -or [BitConverter]::ToUInt32($bytes, 20) -ne 20) { throw 'Unexpected KDAT v2 dimensions/mip/payload size' }
    $expectedBase = [byte[]](255,40,40,255,40,255,40,255,40,40,255,255,255,230,40,255)
    for ($index = 0; $index -lt $expectedBase.Length; $index++) { if ($bytes[24 + $index] -ne $expectedBase[$index]) { throw "Unexpected v2 base RGBA8 pixel at index $index" } }
    $expectedMip = [byte[]](147,141,93,255)
    for ($index = 0; $index -lt $expectedMip.Length; $index++) { if ($bytes[40 + $index] -ne $expectedMip[$index]) { throw "Unexpected v2 mip pixel at index $index" } }
    return Get-Hash $Path
}

$sourceHashBefore = Get-Hash $source
$debugArtifact = Join-Path $output 'debug\test.texture'
$releaseArtifact = Join-Path $output 'release\test.texture'
$invalidSource = Join-Path $output 'invalid.ppm'
$invalidArtifact = Join-Path $output 'invalid\test.texture'
$invalidPackageArtifact = Join-Path (Split-Path -Parent $output) 'bin\assets\invalid.texture'
try {
    $dryDebug = Invoke-TextureTool @('-SourcePath', $source, '-DestinationPath', $debugArtifact, '-Profile', 'debug', '-DryRun')
    $debugPlan = $dryDebug.Output[-1] | ConvertFrom-Json
    if ([int]$debugPlan.ImporterVersion -ne 1 -or [int]$debugPlan.BakerVersion -ne 1 -or [int]$debugPlan.ArtifactVersion -ne 1 -or [string]$debugPlan.ArtifactFormat -cne 'KDAT-TEXTURE-V1' -or [string]$debugPlan.Transform -cne 'ppm-to-rgba8-artifact-v1' -or [int]$debugPlan.MipLevelCount -ne 1 -or [int]$debugPlan.ArtifactBytes -ne 36 -or (Test-Path $debugArtifact)) { throw 'Texture debug profile dry-run failed' }
    $dryRelease = Invoke-TextureTool @('-SourcePath', $source, '-DestinationPath', $releaseArtifact, '-Profile', 'release', '-DryRun')
    $releasePlan = $dryRelease.Output[-1] | ConvertFrom-Json
    if ([int]$releasePlan.ArtifactVersion -ne 2 -or [string]$releasePlan.ArtifactFormat -cne 'KDAT-TEXTURE-V2-MIPMAP' -or [string]$releasePlan.Transform -cne 'ppm-to-rgba8-mipmap-artifact-v2' -or [int]$releasePlan.MipLevelCount -ne 2 -or [int]$releasePlan.ArtifactBytes -ne 44 -or (Test-Path $releaseArtifact)) { throw 'Texture release profile dry-run failed' }

    [void](Invoke-TextureTool @('-SourcePath', $source, '-DestinationPath', $debugArtifact, '-Profile', 'debug'))
    [void](Invoke-TextureTool @('-SourcePath', $source, '-DestinationPath', $releaseArtifact, '-Profile', 'release'))
    $debugHash = Assert-V1Artifact $debugArtifact
    $releaseHash = Assert-V2MipmapArtifact $releaseArtifact
    if ($debugHash -ceq $releaseHash) { throw 'Debug/release texture profiles must produce distinct artifacts' }
    $generatedHash = Assert-V2MipmapArtifact $generated
    if ($generatedHash -cne $releaseHash) { throw 'Generated release texture artifact does not match importer output' }

    New-Item -ItemType Directory -Path (Split-Path -Parent $invalidSource) -Force | Out-Null
    [IO.File]::WriteAllText($invalidSource, "P3`n2 2`n255`n255 0 0`n", [Text.UTF8Encoding]::new($false))
    [void](Invoke-TextureTool @('-SourcePath', $invalidSource, '-DestinationPath', $invalidArtifact, '-DryRun') -ExpectFailure)
    if (Test-Path $invalidArtifact) { throw 'Invalid PPM created an artifact' }
    [void](Invoke-TextureTool @('-SourcePath', $source, '-DestinationPath', $invalidPackageArtifact, '-DryRun') -ExpectFailure)
    if (Test-Path $invalidPackageArtifact) { throw 'Package boundary violation created an artifact' }
    if ($sourceHashBefore -cne (Get-Hash $source)) { throw 'Source PPM changed during texture import verification' }

    Write-Output 'texture_importer_version=1'
    Write-Output 'texture_baker_version=1'
    Write-Output 'debug_artifact_format=KDAT-TEXTURE-V1'
    Write-Output 'release_artifact_format=KDAT-TEXTURE-V2-MIPMAP'
    Write-Output 'dry_run=ok'
    Write-Output 'debug_artifact=ok'
    Write-Output 'release_artifact=ok'
    Write-Output 'profile_transform=ok'
    Write-Output 'mipmap_pixels=ok'
    Write-Output 'artifact_reproducibility=ok'
    Write-Output 'invalid_ppm_rejected=ok'
    Write-Output 'package_boundary=ok'
    Write-Output 'generated_artifact=ok'
    Write-Output 'source_immutable=ok'
    Write-Output 'verification=ok'
} finally {
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
}