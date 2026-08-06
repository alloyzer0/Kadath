[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [ValidateSet('debug', 'release')]
    [string]$Profile = 'debug',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:SceneImporterVersion = 4
$script:SceneBakerVersion = 4
$script:SceneArtifactMagic = 'KSCN'
$script:SceneArtifactVersion = 4
$script:SceneSchemaVersion = 4
$script:SceneArtifactHeaderBytes = 16
$script:SceneSourceMaxBytes = 64 * 1024
$script:SceneObjectMinCount = 3
$script:SceneObjectMaxCount = 64

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
    if ($destination -match '(?i)[\/]bin[\/]assets([\/]|$)') { throw 'Scene artifact destination must not be package/bin/assets' }
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

function Get-JsonProperties(
    [System.Text.Json.JsonElement]$Object,
    [string[]]$Required,
    [string[]]$Optional,
    [string]$Owner
) {
    if ($Object.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw "$Owner must be a JSON object" }
    $allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Required) { [void]$allowed.Add($name) }
    foreach ($name in $Optional) { [void]$allowed.Add($name) }
    $properties = [System.Collections.Generic.Dictionary[string,System.Text.Json.JsonElement]]::new([StringComparer]::Ordinal)
    foreach ($property in $Object.EnumerateObject()) {
        if (-not $allowed.Contains($property.Name)) { throw "$Owner contains an unsupported property: $($property.Name)" }
        if (-not $properties.TryAdd($property.Name, $property.Value)) { throw "$Owner contains a duplicate property: $($property.Name)" }
    }
    foreach ($name in $Required) {
        if (-not $properties.ContainsKey($name)) { throw "$Owner is missing required property: $name" }
    }
    return $properties
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

function Get-JsonString([System.Text.Json.JsonElement]$Value, [string]$Name) {
    if ($Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw "$Name must be a string" }
    return $Value.GetString()
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

function Read-SceneTextures([System.Text.Json.JsonElement]$Value) {
    if ($Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw 'Scene.textures must be an array' }
    $elements = @($Value.EnumerateArray())
    if ($elements.Count -lt 1 -or $elements.Count -gt 4) { throw 'Scene.textures must contain 1 to 4 entries' }
    $ids = [System.Collections.Generic.HashSet[uint32]]::new()
    $textures = [System.Collections.Generic.List[object]]::new()
    foreach ($element in $elements) {
        $properties = Get-JsonProperties $element @('textureId', 'artifact') @() 'Scene.textures[]'
        $textureId = Get-JsonTextureId $properties['textureId'] 'Scene.textures[].textureId'
        if (-not $ids.Add($textureId)) { throw "Scene.textures contains duplicate textureId: $textureId" }
        $artifact = Get-JsonString $properties['artifact'] 'Scene.textures[].artifact'
        if (-not (Test-TextureArtifactPath $artifact)) { throw "Invalid Scene texture artifact: $artifact" }
        $textures.Add([pscustomobject]@{
            TextureId = $textureId
            Artifact = $artifact
            ArtifactBytes = [Text.Encoding]::UTF8.GetBytes($artifact)
        })
    }
    return [pscustomobject]@{ Entries = $textures.ToArray(); Ids = $ids }
}

function Read-SpriteValues(
    [System.Text.Json.JsonElement]$Transform,
    [System.Text.Json.JsonElement]$Sprite,
    [string]$Owner
) {
    $transformProperties = Get-JsonProperties $Transform @('position') @() "$Owner.transform"
    $spriteProperties = Get-JsonProperties $Sprite @('size', 'color', 'textureId') @() "$Owner.sprite"
    $position = Get-JsonVector $transformProperties['position'] 2 "$Owner.transform.position"
    $size = Get-JsonVector $spriteProperties['size'] 2 "$Owner.sprite.size"
    $color = Get-JsonVector $spriteProperties['color'] 4 "$Owner.sprite.color"
    foreach ($number in $size) { if ($number -le 0.0) { throw "$Owner.sprite.size values must be greater than zero" } }
    foreach ($number in $color) { if ($number -lt 0.0 -or $number -gt 1.0) { throw "$Owner.sprite.color values must be in the range [0, 1]" } }
    return [pscustomobject]@{
        Position = $position
        Size = $size
        Color = $color
        TextureId = Get-JsonTextureId $spriteProperties['textureId'] "$Owner.sprite.textureId"
    }
}

function New-NormalizedSceneObject(
    [string]$ObjectId,
    [string]$Kind,
    [single[]]$Position,
    [single[]]$Size,
    [single[]]$Color,
    [uint32]$TextureId,
    [Nullable[single]]$MoveSpeed,
    [Nullable[single]]$PatrolMinY,
    [Nullable[single]]$PatrolMaxY,
    [Nullable[single]]$PatrolSpeed
) {
    [byte[]]$objectIdBytes = [Text.Encoding]::UTF8.GetBytes($ObjectId)
    if ($objectIdBytes.Length -lt 1 -or $objectIdBytes.Length -gt 63 -or $ObjectId -cnotmatch '^[a-z][a-z0-9_-]{0,62}$') {
        throw "Invalid Scene ObjectId: $ObjectId"
    }
    $kindValue = switch ($Kind) {
        'sprite' { [uint32]1 }
        'player' { [uint32]2 }
        'goal' { [uint32]3 }
        'patrol_hazard' { [uint32]4 }
        default { throw "Unsupported Scene object kind: $Kind" }
    }
    $payloadBytes = switch ($Kind) {
        'player' { 4 }
        'patrol_hazard' { 12 }
        default { 0 }
    }
    return [pscustomobject]@{
        ObjectId = $ObjectId
        ObjectIdBytes = $objectIdBytes
        Kind = $Kind
        KindValue = $kindValue
        Position = $Position
        Size = $Size
        Color = $Color
        TextureId = $TextureId
        MoveSpeed = $MoveSpeed
        PatrolMinY = $PatrolMinY
        PatrolMaxY = $PatrolMaxY
        PatrolSpeed = $PatrolSpeed
        EntryBytes = 44 + $objectIdBytes.Length + $payloadBytes
    }
}

function Read-SceneV4Objects([System.Text.Json.JsonElement]$Value) {
    if ($Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw 'Scene.objects must be an array' }
    $elements = @($Value.EnumerateArray())
    if ($elements.Count -lt $script:SceneObjectMinCount -or $elements.Count -gt $script:SceneObjectMaxCount) {
        throw "Scene.objects must contain $($script:SceneObjectMinCount) to $($script:SceneObjectMaxCount) entries"
    }
    $objects = [System.Collections.Generic.List[object]]::new()
    foreach ($element in $elements) {
        $properties = Get-JsonProperties $element @('objectId', 'kind', 'transform', 'sprite') @('player', 'patrol') 'Scene.objects[]'
        $objectId = Get-JsonString $properties['objectId'] 'Scene.objects[].objectId'
        $kind = Get-JsonString $properties['kind'] 'Scene.objects[].kind'
        $sprite = Read-SpriteValues $properties['transform'] $properties['sprite'] "Scene.objects[$objectId]"
        [Nullable[single]]$moveSpeed = $null
        [Nullable[single]]$patrolMinY = $null
        [Nullable[single]]$patrolMaxY = $null
        [Nullable[single]]$patrolSpeed = $null
        switch ($kind) {
            'sprite' {
                if ($properties.ContainsKey('player') -or $properties.ContainsKey('patrol')) { throw "Scene.objects[$objectId] has an invalid kind payload" }
            }
            'goal' {
                if ($properties.ContainsKey('player') -or $properties.ContainsKey('patrol')) { throw "Scene.objects[$objectId] has an invalid kind payload" }
            }
            'player' {
                if (-not $properties.ContainsKey('player') -or $properties.ContainsKey('patrol')) { throw "Scene.objects[$objectId] must contain only player payload" }
                $payload = Get-JsonProperties $properties['player'] @('moveSpeed') @() "Scene.objects[$objectId].player"
                $moveSpeed = Get-JsonSingle $payload['moveSpeed'] "Scene.objects[$objectId].player.moveSpeed"
                if ($moveSpeed -lt 0.0) { throw "Scene.objects[$objectId].player.moveSpeed must be non-negative" }
            }
            'patrol_hazard' {
                if ($properties.ContainsKey('player') -or -not $properties.ContainsKey('patrol')) { throw "Scene.objects[$objectId] must contain only patrol payload" }
                $payload = Get-JsonProperties $properties['patrol'] @('minY', 'maxY', 'speed') @() "Scene.objects[$objectId].patrol"
                $patrolMinY = Get-JsonSingle $payload['minY'] "Scene.objects[$objectId].patrol.minY"
                $patrolMaxY = Get-JsonSingle $payload['maxY'] "Scene.objects[$objectId].patrol.maxY"
                $patrolSpeed = Get-JsonSingle $payload['speed'] "Scene.objects[$objectId].patrol.speed"
                if ($patrolMinY -ge $patrolMaxY) { throw "Scene.objects[$objectId].patrol.minY must be less than maxY" }
                if ($patrolSpeed -lt 0.0) { throw "Scene.objects[$objectId].patrol.speed must be non-negative" }
                if ($sprite.Position[1] -lt $patrolMinY -or $sprite.Position[1] -gt $patrolMaxY) { throw "Scene.objects[$objectId] position Y must be inside the patrol range" }
            }
            default { throw "Unsupported Scene object kind: $kind" }
        }
        $objects.Add((New-NormalizedSceneObject $objectId $kind $sprite.Position $sprite.Size $sprite.Color $sprite.TextureId $moveSpeed $patrolMinY $patrolMaxY $patrolSpeed))
    }
    return $objects.ToArray()
}

function Read-LegacySprite([System.Text.Json.JsonElement]$Value, [string]$Owner, [switch]$Player) {
    $required = if ($Player) { @('position', 'size', 'color', 'moveSpeed', 'textureId') } else { @('position', 'size', 'color', 'textureId') }
    $properties = Get-JsonProperties $Value $required @() $Owner
    $transform = [System.Text.Json.JsonDocument]::Parse("{`"position`":$($properties['position'].GetRawText())}")
    $spriteDocument = [System.Text.Json.JsonDocument]::Parse("{`"size`":$($properties['size'].GetRawText()),`"color`":$($properties['color'].GetRawText()),`"textureId`":$($properties['textureId'].GetRawText())}")
    try {
        $sprite = Read-SpriteValues $transform.RootElement $spriteDocument.RootElement $Owner
        [Nullable[single]]$moveSpeed = $null
        if ($Player) {
            $moveSpeed = Get-JsonSingle $properties['moveSpeed'] "$Owner.moveSpeed"
            if ($moveSpeed -lt 0.0) { throw "$Owner.moveSpeed must be non-negative" }
        }
        return [pscustomobject]@{ Sprite = $sprite; MoveSpeed = $moveSpeed }
    } finally {
        $transform.Dispose()
        $spriteDocument.Dispose()
    }
}

function Read-SceneV3Objects([System.Text.Json.JsonElement]$Root, [object]$Properties) {
    $player = Read-LegacySprite $Properties['player'] 'Scene.player' -Player
    $goal = Read-LegacySprite $Properties['goal'] 'Scene.goal'
    $hazardProperties = Get-JsonProperties $Properties['hazard'] @('position', 'size', 'color', 'patrolMinY', 'patrolMaxY', 'patrolSpeed', 'textureId') @() 'Scene.hazard'
    $transform = [System.Text.Json.JsonDocument]::Parse("{`"position`":$($hazardProperties['position'].GetRawText())}")
    $spriteDocument = [System.Text.Json.JsonDocument]::Parse("{`"size`":$($hazardProperties['size'].GetRawText()),`"color`":$($hazardProperties['color'].GetRawText()),`"textureId`":$($hazardProperties['textureId'].GetRawText())}")
    try {
        $hazard = Read-SpriteValues $transform.RootElement $spriteDocument.RootElement 'Scene.hazard'
    } finally {
        $transform.Dispose()
        $spriteDocument.Dispose()
    }
    [single]$minY = Get-JsonSingle $hazardProperties['patrolMinY'] 'Scene.hazard.patrolMinY'
    [single]$maxY = Get-JsonSingle $hazardProperties['patrolMaxY'] 'Scene.hazard.patrolMaxY'
    [single]$speed = Get-JsonSingle $hazardProperties['patrolSpeed'] 'Scene.hazard.patrolSpeed'
    if ($minY -ge $maxY -or $speed -lt 0.0 -or $hazard.Position[1] -lt $minY -or $hazard.Position[1] -gt $maxY) { throw 'Scene.hazard patrol values are invalid' }
    return @(
        (New-NormalizedSceneObject 'player' 'player' $player.Sprite.Position $player.Sprite.Size $player.Sprite.Color $player.Sprite.TextureId $player.MoveSpeed $null $null $null),
        (New-NormalizedSceneObject 'goal' 'goal' $goal.Sprite.Position $goal.Sprite.Size $goal.Sprite.Color $goal.Sprite.TextureId $null $null $null $null),
        (New-NormalizedSceneObject 'hazard' 'patrol_hazard' $hazard.Position $hazard.Size $hazard.Color $hazard.TextureId $null $minY $maxY $speed)
    )
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
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'Scene must be a JSON object' }
        [System.Text.Json.JsonElement]$schemaElement = [System.Text.Json.JsonElement]::new()
        if (-not $root.TryGetProperty('schemaVersion', [ref]$schemaElement) -or $schemaElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) { throw 'Scene.schemaVersion must be an integer' }
        [uint32]$sourceSchemaVersion = 0
        if (-not $schemaElement.TryGetUInt32([ref]$sourceSchemaVersion) -or ($sourceSchemaVersion -ne 3 -and $sourceSchemaVersion -ne 4)) {
            throw "Unsupported Scene schemaVersion: $($schemaElement.GetRawText())"
        }
        $rootProperties = if ($sourceSchemaVersion -eq 3) {
            Get-JsonProperties $root @('schemaVersion', 'textures', 'player', 'goal', 'hazard') @() 'Scene'
        } else {
            Get-JsonProperties $root @('schemaVersion', 'textures', 'objects') @() 'Scene'
        }
        $textures = Read-SceneTextures $rootProperties['textures']
        $objects = if ($sourceSchemaVersion -eq 3) {
            Read-SceneV3Objects $root $rootProperties
        } else {
            Read-SceneV4Objects $rootProperties['objects']
        }
        $objectIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $playerCount = 0
        $goalCount = 0
        $hazardCount = 0
        foreach ($object in $objects) {
            if (-not $objectIds.Add($object.ObjectId)) { throw "Scene.objects contains duplicate objectId: $($object.ObjectId)" }
            if (-not $textures.Ids.Contains([uint32]$object.TextureId)) { throw "Scene object references undeclared textureId: $($object.TextureId)" }
            switch ($object.Kind) {
                'player' { $playerCount++ }
                'goal' { $goalCount++ }
                'patrol_hazard' { $hazardCount++ }
            }
        }
        if ($playerCount -ne 1 -or $goalCount -ne 1 -or $hazardCount -lt 1) { throw 'Scene must contain exactly one player, exactly one goal, and at least one patrol_hazard' }
        $payloadBytes = 4
        foreach ($texture in $textures.Entries) { $payloadBytes += 8 + $texture.ArtifactBytes.Length }
        $payloadBytes += 4
        foreach ($object in $objects) { $payloadBytes += 4 + $object.EntryBytes }
        return [pscustomobject]@{
            SchemaVersion = $script:SceneSchemaVersion
            SourceSchemaVersion = $sourceSchemaVersion
            Textures = $textures.Entries
            Objects = $objects
            PayloadBytes = $payloadBytes
        }
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
        $writer.Write([Text.Encoding]::ASCII.GetBytes($script:SceneArtifactMagic))
        $writer.Write([uint32]$script:SceneArtifactVersion)
        $writer.Write([uint32]$Scene.SchemaVersion)
        $writer.Write([uint32]$Scene.PayloadBytes)
        $writer.Write([uint32]$Scene.Textures.Count)
        foreach ($texture in $Scene.Textures) {
            $writer.Write([uint32]$texture.TextureId)
            $writer.Write([uint32]$texture.ArtifactBytes.Length)
            $writer.Write([byte[]]$texture.ArtifactBytes)
        }
        $writer.Write([uint32]$Scene.Objects.Count)
        foreach ($object in $Scene.Objects) {
            $writer.Write([uint32]$object.EntryBytes)
            $writer.Write([uint32]$object.KindValue)
            $writer.Write([uint32]$object.ObjectIdBytes.Length)
            $writer.Write([byte[]]$object.ObjectIdBytes)
            foreach ($number in [single[]]$object.Position) { $writer.Write([single]$number) }
            foreach ($number in [single[]]$object.Size) { $writer.Write([single]$number) }
            foreach ($number in [single[]]$object.Color) { $writer.Write([single]$number) }
            $writer.Write([uint32]$object.TextureId)
            if ($object.Kind -eq 'player') {
                $writer.Write([single]$object.MoveSpeed)
            } elseif ($object.Kind -eq 'patrol_hazard') {
                $writer.Write([single]$object.PatrolMinY)
                $writer.Write([single]$object.PatrolMaxY)
                $writer.Write([single]$object.PatrolSpeed)
            }
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
$sourceFormat = "KADATH-SCENE-JSON-V$($scene.SourceSchemaVersion)"
$transform = "scene-json-v$($scene.SourceSchemaVersion)-to-kscn-v4"

if ($DryRun) {
    $plan = [ordered]@{
        ImporterVersion = $script:SceneImporterVersion
        BakerVersion = $script:SceneBakerVersion
        ToolVersion = 'kadath-scene-importer/4'
        Action = 'scene-import-bake'
        Profile = $Profile
        DryRun = $true
        SourceFormat = $sourceFormat
        ArtifactVersion = $script:SceneArtifactVersion
        ArtifactFormat = 'KSCN-SCENE-V4'
        SchemaVersion = $scene.SchemaVersion
        SourceSchemaVersion = $scene.SourceSchemaVersion
        TextureCount = $scene.Textures.Count
        ObjectCount = $scene.Objects.Count
        PayloadBytes = $scene.PayloadBytes
        ArtifactBytes = $artifactBytes
        Transform = $transform
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
Write-Output 'tool_version=kadath-scene-importer/4'
Write-Output "profile=$Profile"
Write-Output "source_format=$sourceFormat"
Write-Output "artifact_version=$($script:SceneArtifactVersion)"
Write-Output 'artifact_format=KSCN-SCENE-V4'
Write-Output "schema_version=$($scene.SchemaVersion)"
Write-Output "source_schema_version=$($scene.SourceSchemaVersion)"
Write-Output "texture_count=$($scene.Textures.Count)"
Write-Output "object_count=$($scene.Objects.Count)"
Write-Output "payload_bytes=$($scene.PayloadBytes)"
Write-Output "transform=$transform"
Write-Output "artifact_bytes=$artifactBytes"
Write-Output "sha256=$hash"
Write-Output "artifact=$destination"
Write-Output 'verification=ok'
