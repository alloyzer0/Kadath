[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\scenes\preview.scene.json'),
    [string]$OutputDirectory = (Join-Path $env:TEMP ("kadath-scene-importer-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$importer = Join-Path $PSScriptRoot 'editor-scene-importer.ps1'
if (-not (Test-Path -LiteralPath $importer -PathType Leaf)) { throw "Scene importer does not exist: $importer" }
if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "Scene source does not exist: $SourcePath" }
$source = (Resolve-Path -LiteralPath $SourcePath).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Output directory already exists: $output" }
if (-not [BitConverter]::IsLittleEndian) { throw 'Scene importer verifier currently requires a little-endian host' }

function Invoke-SceneImporter([string[]]$Arguments, [switch]$ExpectFailure) {
    $lines = @(& pwsh -NoProfile -File $importer @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if (-not $ExpectFailure -and $exitCode -ne 0) { throw "Scene importer failed with code $exitCode`: $($lines -join ' | ')" }
    if ($ExpectFailure -and $exitCode -eq 0) { throw 'Scene importer unexpectedly accepted an invalid request' }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $lines }
}

function Write-JsonFile([object]$Document, [string]$Path) {
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [IO.File]::WriteAllText($Path, ($Document | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function Read-U32Le([byte[]]$Bytes, [int]$Offset) {
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Get-ExpectedSceneFields([string]$Path) {
    $scene = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    $values = [System.Collections.Generic.List[single]]::new(28)
    foreach ($value in @($scene.player.position)) { $values.Add([single]$value) }
    foreach ($value in @($scene.player.size)) { $values.Add([single]$value) }
    foreach ($value in @($scene.player.color)) { $values.Add([single]$value) }
    $values.Add([single]$scene.player.moveSpeed)
    foreach ($value in @($scene.goal.position)) { $values.Add([single]$value) }
    foreach ($value in @($scene.goal.size)) { $values.Add([single]$value) }
    foreach ($value in @($scene.goal.color)) { $values.Add([single]$value) }
    foreach ($value in @($scene.hazard.position)) { $values.Add([single]$value) }
    foreach ($value in @($scene.hazard.size)) { $values.Add([single]$value) }
    foreach ($value in @($scene.hazard.color)) { $values.Add([single]$value) }
    $values.Add([single]$scene.hazard.patrolMinY)
    $values.Add([single]$scene.hazard.patrolMaxY)
    $values.Add([single]$scene.hazard.patrolSpeed)
    if ($values.Count -ne 28) { throw "Expected Scene field count is not 28: $($values.Count)" }
    return ,$values.ToArray()
}

function Get-ExpectedTextureIds([string]$Path) {
    $scene = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    return [uint32[]]@($scene.player.textureId, $scene.goal.textureId, $scene.hazard.textureId)
}

function Assert-SceneArtifact([string]$Path, [single[]]$ExpectedFields, [uint32[]]$ExpectedTextureIds) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Scene artifact does not exist: $Path" }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne 140) { throw "Scene artifact size mismatch: expected=140 actual=$($bytes.Length)" }
    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'KSCN') { throw 'Scene artifact magic mismatch' }
    if ((Read-U32Le $bytes 4) -ne 2) { throw 'Scene artifact version mismatch' }
    if ((Read-U32Le $bytes 8) -ne 2) { throw 'Scene artifact schema version mismatch' }
    if ((Read-U32Le $bytes 12) -ne 124) { throw 'Scene artifact payload size mismatch' }
    if ($ExpectedFields.Count -ne 28) { throw 'Verifier expected field layout is invalid' }
    for ($index = 0; $index -lt $ExpectedFields.Count; $index++) {
        [single]$actual = [BitConverter]::ToSingle($bytes, 16 + ($index * 4))
        # 关键布局验证：按 Scene struct 的固定顺序逐个比较 f32，不只检查头部或文件哈希。
        if ([BitConverter]::SingleToInt32Bits($actual) -ne [BitConverter]::SingleToInt32Bits($ExpectedFields[$index])) {
            throw "Scene artifact field mismatch at index $index`: expected=$($ExpectedFields[$index]) actual=$actual"
        }
    }
    if ($ExpectedTextureIds.Count -ne 3) { throw 'Verifier expected texture binding layout is invalid' }
    for ($index = 0; $index -lt $ExpectedTextureIds.Count; $index++) {
        [uint32]$actual = Read-U32Le $bytes (128 + ($index * 4))
        if ($actual -ne $ExpectedTextureIds[$index]) {
            throw "Scene artifact texture binding mismatch at index $index`: expected=$($ExpectedTextureIds[$index]) actual=$actual"
        }
    }
    return [pscustomobject]@{
        Bytes = $bytes
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$sourceHashBefore = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedFields = Get-ExpectedSceneFields $source
$expectedTextureIds = Get-ExpectedTextureIds $source
$dryArtifact = Join-Path $output 'dry-run\preview.scene'
$debugArtifact = Join-Path $output 'debug\preview.scene'
$releaseArtifact = Join-Path $output 'release\preview.scene'

try {
    $dry = Invoke-SceneImporter @('-SourcePath', $source, '-DestinationPath', $dryArtifact, '-Profile', 'debug', '-DryRun')
    if ($dry.Output.Count -eq 0) { throw 'Scene importer dry-run produced no plan' }
    $plan = $dry.Output[-1] | ConvertFrom-Json
    if ([int]$plan.ImporterVersion -ne 2 -or [int]$plan.BakerVersion -ne 2 -or [string]$plan.ToolVersion -cne 'kadath-scene-importer/2') { throw 'Scene importer dry-run version/tool mismatch' }
    if ([string]$plan.Action -cne 'scene-import-bake' -or [string]$plan.Profile -cne 'debug' -or -not [bool]$plan.DryRun) { throw 'Scene importer dry-run action/profile mismatch' }
    if ([string]$plan.ArtifactFormat -cne 'KSCN-SCENE-V2' -or [int]$plan.SchemaVersion -ne 2 -or [int]$plan.FieldCount -ne 28 -or [int]$plan.PayloadBytes -ne 124 -or [int]$plan.ArtifactBytes -ne 140) { throw 'Scene importer dry-run artifact contract mismatch' }
    if ([string]$plan.Transform -cne 'scene-json-to-kscn-v2') { throw 'Scene importer dry-run transform mismatch' }
    if (Test-Path -LiteralPath $output) { throw 'Scene importer dry-run created an output directory or artifact' }

    [void](Invoke-SceneImporter @('-SourcePath', $source, '-DestinationPath', $debugArtifact, '-Profile', 'debug'))
    [void](Invoke-SceneImporter @('-SourcePath', $source, '-DestinationPath', $releaseArtifact, '-Profile', 'release'))
    $debug = Assert-SceneArtifact $debugArtifact $expectedFields $expectedTextureIds
    $release = Assert-SceneArtifact $releaseArtifact $expectedFields $expectedTextureIds
    if ($debug.Sha256 -cne $release.Sha256) { throw 'Debug and release Scene artifacts are not byte-equivalent' }

    $inputDirectory = Join-Path $output 'invalid-inputs'
    $invalidSchemaPath = Join-Path $inputDirectory 'invalid-schema.scene.json'
    $invalidSchema = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    $invalidSchema.schemaVersion = 3
    Write-JsonFile $invalidSchema $invalidSchemaPath
    $invalidSchemaArtifact = Join-Path $output 'invalid-artifacts\invalid-schema.scene'
    [void](Invoke-SceneImporter @('-SourcePath', $invalidSchemaPath, '-DestinationPath', $invalidSchemaArtifact, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath $invalidSchemaArtifact) { throw 'Invalid schema left a Scene artifact' }

    $invalidRangePath = Join-Path $inputDirectory 'invalid-range.scene.json'
    $invalidRange = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    $invalidRange.hazard.patrolMinY = $invalidRange.hazard.patrolMaxY
    Write-JsonFile $invalidRange $invalidRangePath
    $invalidRangeArtifact = Join-Path $output 'invalid-artifacts\invalid-range.scene'
    [void](Invoke-SceneImporter @('-SourcePath', $invalidRangePath, '-DestinationPath', $invalidRangeArtifact, '-Profile', 'release') -ExpectFailure)
    if (Test-Path -LiteralPath $invalidRangeArtifact) { throw 'Invalid range left a Scene artifact' }

    $invalidTexturePath = Join-Path $inputDirectory 'invalid-texture.scene.json'
    $invalidTexture = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    $invalidTexture.goal.textureId = 0
    Write-JsonFile $invalidTexture $invalidTexturePath
    $invalidTextureArtifact = Join-Path $output 'invalid-artifacts\invalid-texture.scene'
    [void](Invoke-SceneImporter @('-SourcePath', $invalidTexturePath, '-DestinationPath', $invalidTextureArtifact, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath $invalidTextureArtifact) { throw 'Invalid texture binding left a Scene artifact' }

    $debugHashBeforeOverwrite = (Get-FileHash -LiteralPath $debugArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    [void](Invoke-SceneImporter @('-SourcePath', $source, '-DestinationPath', $debugArtifact, '-Profile', 'debug') -ExpectFailure)
    $debugHashAfterOverwrite = (Get-FileHash -LiteralPath $debugArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($debugHashBeforeOverwrite -cne $debugHashAfterOverwrite) { throw 'Overwrite rejection changed the existing Scene artifact' }

    $packageArtifact = Join-Path $output 'bin\assets\scenes\preview.scene'
    [void](Invoke-SceneImporter @('-SourcePath', $source, '-DestinationPath', $packageArtifact, '-Profile', 'release') -ExpectFailure)
    if (Test-Path -LiteralPath $packageArtifact) { throw 'Package boundary rejection left a Scene artifact' }

    $temporaryFiles = @(Get-ChildItem -LiteralPath $output -File -Recurse -Force | Where-Object { $_.Name -like '*.tmp.*' })
    if ($temporaryFiles.Count -ne 0) { throw "Atomic Scene artifact write left temporary files: $($temporaryFiles.FullName -join ', ')" }
    $sourceHashAfter = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHashBefore -cne $sourceHashAfter) { throw 'Scene importer changed the source document' }

    Write-Output 'scene_importer_version=2'
    Write-Output 'scene_baker_version=2'
    Write-Output 'artifact_format=KSCN-SCENE-V2'
    Write-Output 'artifact_version=2'
    Write-Output 'schema_version=2'
    Write-Output 'field_count=28'
    Write-Output 'texture_binding_count=3'
    Write-Output 'payload_bytes=124'
    Write-Output 'artifact_bytes=140'
    Write-Output 'dry_run=ok'
    Write-Output 'debug_artifact=ok'
    Write-Output 'release_artifact=ok'
    Write-Output 'artifact_reproducibility=ok'
    Write-Output 'payload_layout=ok'
    Write-Output 'invalid_schema_rejected=ok'
    Write-Output 'invalid_range_rejected=ok'
    Write-Output 'invalid_texture_binding_rejected=ok'
    Write-Output 'overwrite_rejected=ok'
    Write-Output 'package_boundary=ok'
    Write-Output 'atomic_write=ok'
    Write-Output 'source_immutable=ok'
    Write-Output 'verification=ok'
} finally {
    if (Test-Path -LiteralPath $output) {
        # Verifier 只清理自己创建的隔离输出根，不触碰源 Scene 或 Runtime package。
        Remove-Item -LiteralPath $output -Recurse -Force
    }
}
