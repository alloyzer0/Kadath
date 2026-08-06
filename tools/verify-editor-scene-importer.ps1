[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\scenes\preview.scene.json'),
    [string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ("kadath-scene-importer-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
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
    [IO.File]::WriteAllText($Path, ($Document | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
}

function Read-U32Le([byte[]]$Bytes, [ref]$Offset) {
    if ($Offset.Value -gt $Bytes.Length - 4) { throw 'Scene artifact is truncated while reading u32' }
    [uint32]$value = [BitConverter]::ToUInt32($Bytes, $Offset.Value)
    $Offset.Value += 4
    return $value
}

function Read-F32Le([byte[]]$Bytes, [ref]$Offset) {
    if ($Offset.Value -gt $Bytes.Length - 4) { throw 'Scene artifact is truncated while reading f32' }
    [single]$value = [BitConverter]::ToSingle($Bytes, $Offset.Value)
    $Offset.Value += 4
    return $value
}

function Read-Utf8([byte[]]$Bytes, [ref]$Offset, [uint32]$Length) {
    if ($Length -gt [int]::MaxValue -or $Offset.Value -gt $Bytes.Length - [int]$Length) { throw 'Scene artifact is truncated while reading UTF-8' }
    $value = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes, $Offset.Value, [int]$Length)
    $Offset.Value += [int]$Length
    return $value
}

function Assert-F32([single]$Actual, [object]$Expected, [string]$Field) {
    [single]$expectedSingle = [single]$Expected
    if ([BitConverter]::SingleToInt32Bits($Actual) -ne [BitConverter]::SingleToInt32Bits($expectedSingle)) {
        throw "$Field mismatch: expected=$expectedSingle actual=$Actual"
    }
}

function Assert-Vector([byte[]]$Bytes, [ref]$Offset, [object[]]$Expected, [string]$Field) {
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-F32 (Read-F32Le $Bytes $Offset) $Expected[$index] "$Field[$index]"
    }
}

function Assert-SceneArtifact([string]$Path, [object]$ExpectedScene, [string[]]$ExpectedObjectIds) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Scene artifact does not exist: $Path" }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 16) { throw 'Scene artifact is smaller than the KSCN header' }
    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'KSCN') { throw 'Scene artifact magic mismatch' }
    if ([BitConverter]::ToUInt32($bytes, 4) -ne 4) { throw 'Scene artifact version mismatch' }
    if ([BitConverter]::ToUInt32($bytes, 8) -ne 4) { throw 'Scene artifact schema version mismatch' }
    if ([BitConverter]::ToUInt32($bytes, 12) -ne $bytes.Length - 16) { throw 'Scene artifact payload size mismatch' }

    [int]$offsetValue = 16
    $offset = [ref]$offsetValue
    [object[]]$textures = @($ExpectedScene.textures)
    if ((Read-U32Le $bytes $offset) -ne $textures.Count) { throw 'Scene artifact texture count mismatch' }
    foreach ($texture in $textures) {
        if ((Read-U32Le $bytes $offset) -ne [uint32]$texture.textureId) { throw 'Scene artifact textureId order mismatch' }
        [uint32]$pathBytes = Read-U32Le $bytes $offset
        if ((Read-Utf8 $bytes $offset $pathBytes) -cne [string]$texture.artifact) { throw 'Scene artifact texture path mismatch' }
    }

    [object[]]$objects = @($ExpectedScene.objects)
    if ((Read-U32Le $bytes $offset) -ne $objects.Count) { throw 'Scene artifact object count mismatch' }
    if ($ExpectedObjectIds.Count -ne $objects.Count) { throw 'Verifier object identity fixture mismatch' }
    $kindValues = @{ sprite = 1; player = 2; goal = 3; patrol_hazard = 4 }
    for ($index = 0; $index -lt $objects.Count; $index++) {
        $sceneObject = $objects[$index]
        [int]$entryBytes = [int](Read-U32Le $bytes $offset)
        [int]$entryEnd = $offset.Value + $entryBytes
        $kind = [string]$sceneObject.kind
        if ((Read-U32Le $bytes $offset) -ne [uint32]$kindValues[$kind]) { throw "Scene object kind mismatch at index $index" }
        [uint32]$objectIdBytes = Read-U32Le $bytes $offset
        $objectId = Read-Utf8 $bytes $offset $objectIdBytes
        if ($objectId -cne $ExpectedObjectIds[$index]) { throw "Scene object order/identity mismatch at index $index" }
        Assert-Vector $bytes $offset @($sceneObject.transform.position) "objects[$index].position"
        Assert-Vector $bytes $offset @($sceneObject.sprite.size) "objects[$index].size"
        Assert-Vector $bytes $offset @($sceneObject.sprite.color) "objects[$index].color"
        if ((Read-U32Le $bytes $offset) -ne [uint32]$sceneObject.sprite.textureId) { throw "objects[$index].textureId mismatch" }
        if ($kind -eq 'player') {
            Assert-F32 (Read-F32Le $bytes $offset) $sceneObject.player.moveSpeed "objects[$index].player.moveSpeed"
        } elseif ($kind -eq 'patrol_hazard') {
            Assert-F32 (Read-F32Le $bytes $offset) $sceneObject.patrol.minY "objects[$index].patrol.minY"
            Assert-F32 (Read-F32Le $bytes $offset) $sceneObject.patrol.maxY "objects[$index].patrol.maxY"
            Assert-F32 (Read-F32Le $bytes $offset) $sceneObject.patrol.speed "objects[$index].patrol.speed"
        }
        if ($offset.Value -ne $entryEnd) { throw "Scene object entryBytes mismatch at index $index" }
    }
    if ($offset.Value -ne $bytes.Length) { throw 'Scene artifact contains trailing bytes' }
    return [pscustomobject]@{
        Bytes = $bytes
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        PayloadBytes = $bytes.Length - 16
    }
}

function New-LegacyScene([object]$Scene) {
    $player = @($Scene.objects | Where-Object kind -eq 'player')[0]
    $goal = @($Scene.objects | Where-Object kind -eq 'goal')[0]
    $hazard = @($Scene.objects | Where-Object kind -eq 'patrol_hazard')[0]
    return [ordered]@{
        schemaVersion = 3
        textures = $Scene.textures
        player = [ordered]@{ position = $player.transform.position; size = $player.sprite.size; color = $player.sprite.color; moveSpeed = $player.player.moveSpeed; textureId = $player.sprite.textureId }
        goal = [ordered]@{ position = $goal.transform.position; size = $goal.sprite.size; color = $goal.sprite.color; textureId = $goal.sprite.textureId }
        hazard = [ordered]@{ position = $hazard.transform.position; size = $hazard.sprite.size; color = $hazard.sprite.color; patrolMinY = $hazard.patrol.minY; patrolMaxY = $hazard.patrol.maxY; patrolSpeed = $hazard.patrol.speed; textureId = $hazard.sprite.textureId }
    }
}

function New-LegacyExpectedScene([object]$Legacy) {
    return [pscustomobject]@{
        textures = $Legacy.textures
        objects = @(
            [pscustomobject]@{ objectId = 'player'; kind = 'player'; transform = [pscustomobject]@{ position = $Legacy.player.position }; sprite = [pscustomobject]@{ size = $Legacy.player.size; color = $Legacy.player.color; textureId = $Legacy.player.textureId }; player = [pscustomobject]@{ moveSpeed = $Legacy.player.moveSpeed } },
            [pscustomobject]@{ objectId = 'goal'; kind = 'goal'; transform = [pscustomobject]@{ position = $Legacy.goal.position }; sprite = [pscustomobject]@{ size = $Legacy.goal.size; color = $Legacy.goal.color; textureId = $Legacy.goal.textureId } },
            [pscustomobject]@{ objectId = 'hazard'; kind = 'patrol_hazard'; transform = [pscustomobject]@{ position = $Legacy.hazard.position }; sprite = [pscustomobject]@{ size = $Legacy.hazard.size; color = $Legacy.hazard.color; textureId = $Legacy.hazard.textureId }; patrol = [pscustomobject]@{ minY = $Legacy.hazard.patrolMinY; maxY = $Legacy.hazard.patrolMaxY; speed = $Legacy.hazard.patrolSpeed } }
        )
    }
}

function Invoke-InvalidScene([object]$Document, [string]$Name) {
    $inputPath = Join-Path $output "invalid-inputs\$Name.scene.json"
    $artifactPath = Join-Path $output "invalid-artifacts\$Name.scene"
    Write-JsonFile $Document $inputPath
    [void](Invoke-SceneImporter @('-SourcePath', $inputPath, '-DestinationPath', $artifactPath, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath $artifactPath) { throw "Invalid Scene left an artifact: $Name" }
}

$sourceHashBefore = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
$scene = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
$expectedObjectIds = @($scene.objects | ForEach-Object { [string]$_.objectId })
$dryArtifact = Join-Path $output 'dry-run\preview.scene'
$debugArtifact = Join-Path $output 'debug\preview.scene'
$releaseArtifact = Join-Path $output 'release\preview.scene'

try {
    $dry = Invoke-SceneImporter @('-SourcePath', $source, '-DestinationPath', $dryArtifact, '-Profile', 'debug', '-DryRun')
    if ($dry.Output.Count -eq 0) { throw 'Scene importer dry-run produced no plan' }
    $plan = $dry.Output[-1] | ConvertFrom-Json
    if ([int]$plan.ImporterVersion -ne 4 -or [int]$plan.BakerVersion -ne 4 -or [string]$plan.ToolVersion -cne 'kadath-scene-importer/4') { throw 'Scene importer dry-run version/tool mismatch' }
    if ([string]$plan.Action -cne 'scene-import-bake' -or [string]$plan.Profile -cne 'debug' -or -not [bool]$plan.DryRun) { throw 'Scene importer dry-run action/profile mismatch' }
    if ([string]$plan.ArtifactFormat -cne 'KSCN-SCENE-V4' -or [int]$plan.ArtifactVersion -ne 4 -or [int]$plan.SchemaVersion -ne 4 -or [int]$plan.SourceSchemaVersion -ne 4 -or [int]$plan.TextureCount -ne @($scene.textures).Count -or [int]$plan.ObjectCount -ne @($scene.objects).Count -or [int]$plan.ArtifactBytes -ne [int]$plan.PayloadBytes + 16) { throw 'Scene importer dry-run artifact contract mismatch' }
    if ([string]$plan.Transform -cne 'scene-json-v4-to-kscn-v4') { throw 'Scene importer dry-run transform mismatch' }
    if (Test-Path -LiteralPath $output) { throw 'Scene importer dry-run created an output directory or artifact' }

    [void](Invoke-SceneImporter @('-SourcePath', $source, '-DestinationPath', $debugArtifact, '-Profile', 'debug'))
    [void](Invoke-SceneImporter @('-SourcePath', $source, '-DestinationPath', $releaseArtifact, '-Profile', 'release'))
    $debug = Assert-SceneArtifact $debugArtifact $scene $expectedObjectIds
    $release = Assert-SceneArtifact $releaseArtifact $scene $expectedObjectIds
    if ($debug.Sha256 -cne $release.Sha256) { throw 'Debug and release Scene artifacts are not byte-equivalent' }
    if ($source.EndsWith('assets/scenes/preview.scene.json', [StringComparison]::OrdinalIgnoreCase) -and $debug.Sha256 -cne '988183e0a3b3d7f06f1f0fef3ab67634cdcc185aee7cd0cf92a4978a114058af') {
        throw 'PowerShell KSCN output differs from the native Workspace codec oracle'
    }

    $legacy = New-LegacyScene $scene
    $legacyPath = Join-Path $output 'legacy\preview.scene.json'
    $legacyArtifact = Join-Path $output 'legacy\preview.scene'
    Write-JsonFile $legacy $legacyPath
    [void](Invoke-SceneImporter @('-SourcePath', $legacyPath, '-DestinationPath', $legacyArtifact, '-Profile', 'debug'))
    [void](Assert-SceneArtifact $legacyArtifact (New-LegacyExpectedScene $legacy) @('player', 'goal', 'hazard'))

    $twoObjects = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    $twoObjects.objects = @($twoObjects.objects | Where-Object kind -in @('player', 'goal'))
    Invoke-InvalidScene $twoObjects 'two-objects'

    $sixtyFourObjects = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    $baseObjects = @($sixtyFourObjects.objects)
    $expanded = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $baseObjects) { $expanded.Add($item) }
    for ($index = $baseObjects.Count; $index -lt 64; $index++) {
        $expanded.Add([pscustomobject]@{
            objectId = "sprite-$index"
            kind = 'sprite'
            transform = [pscustomobject]@{ position = @([double]$index, [double]$index) }
            sprite = [pscustomobject]@{ size = @(1.0, 1.0); color = @(1.0, 1.0, 1.0, 1.0); textureId = [uint32]$scene.textures[0].textureId }
        })
    }
    $sixtyFourObjects.objects = $expanded.ToArray()
    $sixtyFourPath = Join-Path $output 'bounds\sixty-four.scene.json'
    $sixtyFourArtifact = Join-Path $output 'bounds\sixty-four.scene'
    Write-JsonFile $sixtyFourObjects $sixtyFourPath
    [void](Invoke-SceneImporter @('-SourcePath', $sixtyFourPath, '-DestinationPath', $sixtyFourArtifact, '-Profile', 'debug'))
    [void](Assert-SceneArtifact $sixtyFourArtifact $sixtyFourObjects @($sixtyFourObjects.objects | ForEach-Object objectId))
    $sixtyFiveObjects = Get-Content -LiteralPath $sixtyFourPath -Raw -Encoding utf8 | ConvertFrom-Json
    $sixtyFiveObjects.objects += [pscustomobject]@{ objectId = 'sprite-64'; kind = 'sprite'; transform = [pscustomobject]@{ position = @(64.0, 64.0) }; sprite = [pscustomobject]@{ size = @(1.0, 1.0); color = @(1.0, 1.0, 1.0, 1.0); textureId = [uint32]$scene.textures[0].textureId } }
    Invoke-InvalidScene $sixtyFiveObjects 'sixty-five-objects'

    $duplicateId = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    $duplicateId.objects[1].objectId = $duplicateId.objects[0].objectId
    Invoke-InvalidScene $duplicateId 'duplicate-object-id'
    $unknownKind = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    $unknownKind.objects[0].kind = 'unknown'
    Invoke-InvalidScene $unknownKind 'unknown-kind'
    $invalidRange = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    $hazard = @($invalidRange.objects | Where-Object kind -eq 'patrol_hazard')[0]
    $hazard.patrol.minY = $hazard.patrol.maxY
    Invoke-InvalidScene $invalidRange 'invalid-range'
    $invalidTexture = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    @($invalidTexture.objects | Where-Object kind -eq 'goal')[0].sprite.textureId = 0
    Invoke-InvalidScene $invalidTexture 'invalid-texture'
    $invalidTexturePath = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    $invalidTexturePath.textures[0].artifact = 'assets/renderer2d/nested/../test.texture'
    Invoke-InvalidScene $invalidTexturePath 'invalid-texture-path'
    $invalidSchema = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    $invalidSchema.schemaVersion = 5
    Invoke-InvalidScene $invalidSchema 'invalid-schema'

    $debugHashBeforeOverwrite = (Get-FileHash -LiteralPath $debugArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    [void](Invoke-SceneImporter @('-SourcePath', $source, '-DestinationPath', $debugArtifact, '-Profile', 'debug') -ExpectFailure)
    if ($debugHashBeforeOverwrite -cne (Get-FileHash -LiteralPath $debugArtifact -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Overwrite rejection changed the existing Scene artifact' }

    $packageArtifact = Join-Path $output 'bin\assets\scenes\preview.scene'
    [void](Invoke-SceneImporter @('-SourcePath', $source, '-DestinationPath', $packageArtifact, '-Profile', 'release') -ExpectFailure)
    if (Test-Path -LiteralPath $packageArtifact) { throw 'Package boundary rejection left a Scene artifact' }

    $temporaryFiles = @(Get-ChildItem -LiteralPath $output -File -Recurse -Force | Where-Object { $_.Name -like '*.tmp.*' })
    if ($temporaryFiles.Count -ne 0) { throw "Atomic Scene artifact write left temporary files: $($temporaryFiles.FullName -join ', ')" }
    if ($sourceHashBefore -cne (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Scene importer changed the source document' }

    Write-Output 'scene_importer_version=4'
    Write-Output 'scene_baker_version=4'
    Write-Output 'artifact_format=KSCN-SCENE-V4'
    Write-Output 'artifact_version=4'
    Write-Output 'schema_version=4'
    Write-Output "texture_count=$(@($scene.textures).Count)"
    Write-Output "object_count=$(@($scene.objects).Count)"
    Write-Output "payload_bytes=$($debug.PayloadBytes)"
    Write-Output "artifact_bytes=$($debug.Bytes.Length)"
    Write-Output 'source_order=ok'
    Write-Output 'legacy_v3_normalization=ok'
    Write-Output 'object_bounds=ok'
    Write-Output 'invalid_objects_rejected=ok'
    Write-Output 'artifact_reproducibility=ok'
    Write-Output 'payload_layout=ok'
    Write-Output 'native_byte_oracle=ok'
    Write-Output 'overwrite_rejected=ok'
    Write-Output 'package_boundary=ok'
    Write-Output 'atomic_write=ok'
    Write-Output 'source_immutable=ok'
    Write-Output 'verification=ok'
} finally {
    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Recurse -Force
    }
}
