[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [ValidateSet('debug', 'release')]
    [string]$Profile = 'debug',

    # DryRun 会完整解析并校验 Scene JSON，但不创建目录或 artifact。
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:SceneImporterVersion = 3
$script:SceneBakerVersion = 3
$script:SceneArtifactMagic = 'KSCN'
$script:SceneArtifactVersion = 3
$script:SceneSchemaVersion = 3
$script:SceneArtifactHeaderBytes = 16
$script:SceneArtifactFieldCount = 28
$script:SceneArtifactV2PayloadBytes = ($script:SceneArtifactFieldCount + 3) * 4
$script:SceneSourceMaxBytes = 64 * 1024

function Resolve-SceneSource([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Scene source does not exist: $Path" }
    $source = (Resolve-Path -LiteralPath $Path).Path
    $file = Get-Item -LiteralPath $source
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Scene source cannot be a reparse point' }
    if (-not $file.Name.EndsWith('.scene.json', [StringComparison]::OrdinalIgnoreCase)) { throw 'Scene importer expects a .scene.json source' }
    if ($file.Length -gt $script:SceneSourceMaxBytes) { throw "Scene source exceeds size limit: $($file.Length) > $script:SceneSourceMaxBytes" }
    return $source
}

function Resolve-SceneDestination([string]$Path) {
    $destination = [IO.Path]::GetFullPath($Path)
    if ([string]::IsNullOrWhiteSpace($destination) -or $destination -eq [IO.Path]::GetPathRoot($destination)) { throw "Invalid Scene artifact destination: $Path" }
    if ([IO.Path]::GetExtension($destination).ToLowerInvariant() -ne '.scene') { throw 'Scene artifact destination must use the .scene extension' }
    # 关键不可变性边界：Importer 只写生成目录，禁止直接覆盖已安装 package/bin/assets。
    if ($destination -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw 'Scene artifact destination must not be package/bin/assets' }
    if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite existing Scene artifact: $destination" }

    $existingParent = Split-Path -Parent $destination
    while (-not (Test-Path -LiteralPath $existingParent -PathType Container)) {
        $nextParent = Split-Path -Parent $existingParent
        if ([string]::IsNullOrWhiteSpace($nextParent) -or $nextParent -eq $existingParent) { throw "Cannot resolve Scene artifact parent: $destination" }
        $existingParent = $nextParent
    }
    $parentInfo = Get-Item -LiteralPath $existingParent
    if (($parentInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Scene artifact parent cannot be a reparse point' }
    return $destination
}

function Get-RequiredJsonProperty(
    [System.Text.Json.JsonElement]$Object,
    [string]$Name,
    [string[]]$ExpectedNames,
    [string]$Owner
) {
    if ($Object.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw "$Owner must be a JSON object" }
    $expected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($expectedName in $ExpectedNames) { [void]$expected.Add($expectedName) }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $found = $false
    $value = [System.Text.Json.JsonElement]::new()
    foreach ($property in $Object.EnumerateObject()) {
        if (-not $expected.Contains($property.Name)) { throw "$Owner contains an unsupported property: $($property.Name)" }
        if (-not $seen.Add($property.Name)) { throw "$Owner contains a duplicate property: $($property.Name)" }
        if ($property.Name -ceq $Name) {
            $value = $property.Value
            $found = $true
        }
    }
    foreach ($expectedName in $ExpectedNames) {
        if (-not $seen.Contains($expectedName)) { throw "$Owner is missing required property: $expectedName" }
    }
    if (-not $found) { throw "$Owner is missing required property: $Name" }
    return $value
}

function Get-JsonSingle([System.Text.Json.JsonElement]$Value, [string]$Name) {
    if ($Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) { throw "$Name must be numeric" }
    try { [double]$number = $Value.GetDouble() } catch { throw "$Name must be numeric" }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw "$Name must be finite" }
    [single]$single = $number
    if ([single]::IsNaN($single) -or [single]::IsInfinity($single)) { throw "$Name exceeds the finite f32 range" }
    return $single
}

function Get-JsonVector([System.Text.Json.JsonElement]$Value, [int]$Length, [string]$Name) {
    if ($Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw "$Name must be a JSON array" }
    $elements = @($Value.EnumerateArray())
    if ($elements.Count -ne $Length) { throw "$Name must contain exactly $Length numbers" }
    [single[]]$result = [single[]]::new($Length)
    for ($index = 0; $index -lt $Length; $index++) { $result[$index] = Get-JsonSingle $elements[$index] "$Name[$index]" }
    return ,$result
}

function Get-JsonTextureId([System.Text.Json.JsonElement]$Value, [string]$Name) {
    if ($Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) { throw "$Name must be an integer" }
    [uint32]$textureId = 0
    if (-not $Value.TryGetUInt32([ref]$textureId) -or $textureId -eq 0) { throw "$Name must be a non-zero u32" }
    return $textureId
}

function Test-TextureArtifactPath([string]$Artifact) {
    if ([string]::IsNullOrEmpty($Artifact) -or [Text.Encoding]::UTF8.GetByteCount($Artifact) -gt 255) { return $false }
    if (-not $Artifact.StartsWith('assets/renderer2d/', [StringComparison]::Ordinal) -or
        -not $Artifact.EndsWith('.texture', [StringComparison]::Ordinal) -or
        $Artifact.Contains('\')) { return $false }
    foreach ($segment in $Artifact.Split('/')) {
        if ($segment.Length -eq 0 -or $segment -eq '.' -or $segment -eq '..') { return $false }
    }
    return $true
}

function Get-SceneSpriteFields(
    [System.Text.Json.JsonElement]$Sprite,
    [string]$Owner,
    [switch]$HasMoveSpeed
) {
    $expected = if ($HasMoveSpeed) { @('position', 'size', 'color', 'moveSpeed', 'textureId') } else { @('position', 'size', 'color', 'textureId') }
    $position = Get-JsonVector (Get-RequiredJsonProperty $Sprite 'position' $expected $Owner) 2 "$Owner.position"
    $size = Get-JsonVector (Get-RequiredJsonProperty $Sprite 'size' $expected $Owner) 2 "$Owner.size"
    $color = Get-JsonVector (Get-RequiredJsonProperty $Sprite 'color' $expected $Owner) 4 "$Owner.color"

    foreach ($value in $size) {
        if ($value -le 0.0) { throw "$Owner.size values must be greater than zero" }
    }
    foreach ($value in $color) {
        if ($value -lt 0.0 -or $value -gt 1.0) { throw "$Owner.color values must be in the range [0, 1]" }
    }

    $fields = [System.Collections.Generic.List[single]]::new()
    foreach ($value in $position) { $fields.Add($value) }
    foreach ($value in $size) { $fields.Add($value) }
    foreach ($value in $color) { $fields.Add($value) }
    if ($HasMoveSpeed) {
        $moveSpeed = Get-JsonSingle (Get-RequiredJsonProperty $Sprite 'moveSpeed' $expected $Owner) "$Owner.moveSpeed"
        if ($moveSpeed -lt 0.0) { throw "$Owner.moveSpeed must be non-negative" }
        $fields.Add($moveSpeed)
    }
    return [pscustomobject]@{
        Fields = [single[]]$fields.ToArray()
        TextureId = Get-JsonTextureId (Get-RequiredJsonProperty $Sprite 'textureId' $expected $Owner) "$Owner.textureId"
    }
}

function Parse-SceneDocument([string]$Path) {
    $contents = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 32
    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($contents, $options)
        $root = $document.RootElement
        $rootExpected = @('schemaVersion', 'textures', 'player', 'goal', 'hazard')
        $schemaElement = Get-RequiredJsonProperty $root 'schemaVersion' $rootExpected 'Scene'
        if ($schemaElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) { throw 'Scene.schemaVersion must be an integer' }
        [uint32]$schemaVersion = 0
        if (-not $schemaElement.TryGetUInt32([ref]$schemaVersion) -or $schemaVersion -ne $script:SceneSchemaVersion) { throw "Unsupported Scene schemaVersion: $($schemaElement.GetRawText())" }

        $player = Get-RequiredJsonProperty $root 'player' $rootExpected 'Scene'
        $goal = Get-RequiredJsonProperty $root 'goal' $rootExpected 'Scene'
        $hazard = Get-RequiredJsonProperty $root 'hazard' $rootExpected 'Scene'
        $textureArray = Get-RequiredJsonProperty $root 'textures' $rootExpected 'Scene'
        if ($textureArray.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw 'Scene.textures must be an array' }
        $textureElements = @($textureArray.EnumerateArray())
        if ($textureElements.Count -lt 1 -or $textureElements.Count -gt 4) { throw 'Scene.textures must contain 1 to 4 entries' }
        $textureIdsSet = [System.Collections.Generic.HashSet[uint32]]::new()
        $textures = [System.Collections.Generic.List[object]]::new()
        foreach ($texture in $textureElements) {
            $expected = @('textureId', 'artifact')
            $textureId = Get-JsonTextureId (Get-RequiredJsonProperty $texture 'textureId' $expected 'Scene.textures[]') 'Scene.textures[].textureId'
            if (-not $textureIdsSet.Add($textureId)) { throw "Scene.textures contains duplicate textureId: $textureId" }
            $artifactElement = Get-RequiredJsonProperty $texture 'artifact' $expected 'Scene.textures[]'
            if ($artifactElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'Scene.textures[].artifact must be a string' }
            $artifact = $artifactElement.GetString()
            [byte[]]$artifactBytes = [Text.Encoding]::UTF8.GetBytes($artifact)
            if (-not (Test-TextureArtifactPath $artifact)) { throw "Invalid Scene texture artifact: $artifact" }
            $textures.Add([pscustomobject]@{ TextureId = $textureId; Artifact = $artifact; ArtifactBytes = $artifactBytes })
        }

        $fields = [System.Collections.Generic.List[single]]::new($script:SceneArtifactFieldCount)
        $playerData = Get-SceneSpriteFields $player 'Scene.player' -HasMoveSpeed
        $goalData = Get-SceneSpriteFields $goal 'Scene.goal'
        foreach ($value in $playerData.Fields) { $fields.Add($value) }
        foreach ($value in $goalData.Fields) { $fields.Add($value) }

        $hazardExpected = @('position', 'size', 'color', 'patrolMinY', 'patrolMaxY', 'patrolSpeed', 'textureId')
        $hazardPosition = Get-JsonVector (Get-RequiredJsonProperty $hazard 'position' $hazardExpected 'Scene.hazard') 2 'Scene.hazard.position'
        $hazardSize = Get-JsonVector (Get-RequiredJsonProperty $hazard 'size' $hazardExpected 'Scene.hazard') 2 'Scene.hazard.size'
        $hazardColor = Get-JsonVector (Get-RequiredJsonProperty $hazard 'color' $hazardExpected 'Scene.hazard') 4 'Scene.hazard.color'
        foreach ($value in $hazardSize) { if ($value -le 0.0) { throw 'Scene.hazard.size values must be greater than zero' } }
        foreach ($value in $hazardColor) { if ($value -lt 0.0 -or $value -gt 1.0) { throw 'Scene.hazard.color values must be in the range [0, 1]' } }
        $patrolMinY = Get-JsonSingle (Get-RequiredJsonProperty $hazard 'patrolMinY' $hazardExpected 'Scene.hazard') 'Scene.hazard.patrolMinY'
        $patrolMaxY = Get-JsonSingle (Get-RequiredJsonProperty $hazard 'patrolMaxY' $hazardExpected 'Scene.hazard') 'Scene.hazard.patrolMaxY'
        $patrolSpeed = Get-JsonSingle (Get-RequiredJsonProperty $hazard 'patrolSpeed' $hazardExpected 'Scene.hazard') 'Scene.hazard.patrolSpeed'
        if ($patrolMinY -ge $patrolMaxY) { throw 'Scene.hazard.patrolMinY must be less than patrolMaxY' }
        if ($patrolSpeed -lt 0.0) { throw 'Scene.hazard.patrolSpeed must be non-negative' }
        if ($hazardPosition[1] -lt $patrolMinY -or $hazardPosition[1] -gt $patrolMaxY) { throw 'Scene.hazard.position[1] must be inside the patrol range' }
        foreach ($value in $hazardPosition) { $fields.Add($value) }
        foreach ($value in $hazardSize) { $fields.Add($value) }
        foreach ($value in $hazardColor) { $fields.Add($value) }
        $fields.Add($patrolMinY)
        $fields.Add($patrolMaxY)
        $fields.Add($patrolSpeed)

        if ($fields.Count -ne $script:SceneArtifactFieldCount) { throw "Internal Scene field count mismatch: $($fields.Count)" }
        $textureIds = [uint32[]]@(
            $playerData.TextureId,
            $goalData.TextureId,
            (Get-JsonTextureId (Get-RequiredJsonProperty $hazard 'textureId' $hazardExpected 'Scene.hazard') 'Scene.hazard.textureId')
        )
        foreach ($textureId in $textureIds) { if (-not $textureIdsSet.Contains($textureId)) { throw "Scene object references undeclared textureId: $textureId" } }
        $payloadBytes = $script:SceneArtifactV2PayloadBytes + 4
        foreach ($texture in $textures) { $payloadBytes += 8 + $texture.ArtifactBytes.Length }
        return [pscustomobject]@{ SchemaVersion = $schemaVersion; Fields = [single[]]$fields.ToArray(); TextureIds = $textureIds; Textures = $textures.ToArray(); PayloadBytes = $payloadBytes }
    } catch [System.Text.Json.JsonException] {
        throw "Failed to parse Scene JSON: $($_.Exception.Message)"
    } finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}

function Write-SceneArtifactAtomic([object]$Scene, [string]$Path) {
    $temporary = "$Path.tmp.$PID"
    $stream = $null
    $writer = $null
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = [IO.BinaryWriter]::new($stream)
        # BinaryWriter 在支持的 Windows 目标上以 little-endian 写出 u32/f32，固定字段顺序保证 artifact 可复现。
        $writer.Write([Text.Encoding]::ASCII.GetBytes($script:SceneArtifactMagic))
        $writer.Write([uint32]$script:SceneArtifactVersion)
        $writer.Write([uint32]$Scene.SchemaVersion)
        $writer.Write([uint32]$Scene.PayloadBytes)
        foreach ($field in [single[]]$Scene.Fields) { $writer.Write([single]$field) }
        foreach ($textureId in [uint32[]]$Scene.TextureIds) { $writer.Write([uint32]$textureId) }
        $writer.Write([uint32]$Scene.Textures.Count)
        foreach ($texture in $Scene.Textures) {
            $writer.Write([uint32]$texture.TextureId)
            $writer.Write([uint32]$texture.ArtifactBytes.Length)
            $writer.Write([byte[]]$texture.ArtifactBytes)
        }
        $writer.Flush()
        $writer.Dispose(); $writer = $null
        $stream.Dispose(); $stream = $null
        Move-Item -LiteralPath $temporary -Destination $Path
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

$source = Resolve-SceneSource $SourcePath
$scene = Parse-SceneDocument $source
$destination = Resolve-SceneDestination $DestinationPath
$artifactBytes = $script:SceneArtifactHeaderBytes + $scene.PayloadBytes

if ($DryRun) {
    $plan = [ordered]@{
        ImporterVersion = $script:SceneImporterVersion
        BakerVersion = $script:SceneBakerVersion
        ToolVersion = 'kadath-scene-importer/3'
        Action = 'scene-import-bake'
        Profile = $Profile
        DryRun = $true
        SourceFormat = 'KADATH-SCENE-JSON-V3'
        ArtifactVersion = $script:SceneArtifactVersion
        ArtifactFormat = 'KSCN-SCENE-V3'
        SchemaVersion = $scene.SchemaVersion
        FieldCount = $script:SceneArtifactFieldCount
        PayloadBytes = $scene.PayloadBytes
        ArtifactBytes = $artifactBytes
        Transform = 'scene-json-to-kscn-v3'
        Destination = 'generated-assets/scenes/preview.scene'
    }
    Write-Output ($plan | ConvertTo-Json -Depth 8 -Compress)
    exit 0
}

New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
Write-SceneArtifactAtomic $scene $destination
$hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "scene_importer_version=$($script:SceneImporterVersion)"
Write-Output "scene_baker_version=$($script:SceneBakerVersion)"
Write-Output 'tool_version=kadath-scene-importer/3'
Write-Output "profile=$Profile"
Write-Output 'source_format=KADATH-SCENE-JSON-V3'
Write-Output "artifact_version=$($script:SceneArtifactVersion)"
Write-Output 'artifact_format=KSCN-SCENE-V3'
Write-Output "schema_version=$($scene.SchemaVersion)"
Write-Output "field_count=$($script:SceneArtifactFieldCount)"
Write-Output "payload_bytes=$($scene.PayloadBytes)"
Write-Output 'transform=scene-json-to-kscn-v3'
Write-Output "artifact_bytes=$artifactBytes"
Write-Output "sha256=$hash"
Write-Output "artifact=$destination"
Write-Output 'verification=ok'
