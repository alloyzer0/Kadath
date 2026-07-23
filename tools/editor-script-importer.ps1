[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [ValidateSet('debug', 'release')]
    [string]$Profile = 'debug',

    # DryRun 只解析和校验 Script source，不创建目录、临时文件或 artifact。
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ScriptImporterVersion = 1
$script:ScriptBakerVersion = 1
$script:ScriptArtifactMagic = 'KSCP'
$script:ScriptArtifactVersion = 1
$script:ScriptSchemaVersion = 1
$script:ScriptArtifactHeaderBytes = 16
$script:ScriptArtifactInstructionBytes = 16
$script:ScriptMaxInstructions = 16
$script:ScriptSourceMaxBytes = 64 * 1024
$script:ScriptMaxVelocity = [single]1000.0

function Resolve-ScriptSource([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Script source does not exist: $Path" }
    $source = (Resolve-Path -LiteralPath $Path).Path
    $file = Get-Item -LiteralPath $source
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Script source cannot be a reparse point' }
    if (-not $file.Name.EndsWith('.script.json', [StringComparison]::OrdinalIgnoreCase)) { throw 'Script importer expects a .script.json source' }
    if ($file.Length -gt $script:ScriptSourceMaxBytes) { throw "Script source exceeds size limit: $($file.Length) > $script:ScriptSourceMaxBytes" }
    return $source
}

function Resolve-ScriptDestination([string]$Path) {
    $destination = [IO.Path]::GetFullPath($Path)
    if ([string]::IsNullOrWhiteSpace($destination) -or $destination -eq [IO.Path]::GetPathRoot($destination)) { throw "Invalid Script artifact destination: $Path" }
    if ([IO.Path]::GetExtension($destination).ToLowerInvariant() -ne '.script') { throw 'Script artifact destination must use the .script extension' }
    # 关键不可变边界：Importer 只写新的派生目录，禁止直接覆盖 Runtime package/bin/assets。
    if ($destination -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw 'Script artifact destination must not be package/bin/assets' }
    if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite existing Script artifact: $destination" }

    $existingParent = Split-Path -Parent $destination
    while (-not (Test-Path -LiteralPath $existingParent -PathType Container)) {
        $nextParent = Split-Path -Parent $existingParent
        if ([string]::IsNullOrWhiteSpace($nextParent) -or $nextParent -eq $existingParent) { throw "Cannot resolve Script artifact parent: $destination" }
        $existingParent = $nextParent
    }
    $parentInfo = Get-Item -LiteralPath $existingParent
    if (($parentInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Script artifact parent cannot be a reparse point' }
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

function Get-JsonVector2([System.Text.Json.JsonElement]$Value, [string]$Name) {
    if ($Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw "$Name must be a JSON array" }
    $elements = @($Value.EnumerateArray())
    if ($elements.Count -ne 2) { throw "$Name must contain exactly two numbers" }
    [single[]]$result = [single[]]::new(2)
    for ($index = 0; $index -lt 2; $index++) { $result[$index] = Get-JsonSingle $elements[$index] "$Name[$index]" }
    return ,$result
}

function Parse-ScriptDocument([string]$Path) {
    $contents = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 32
    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($contents, $options)
        $root = $document.RootElement
        $rootExpected = @('schemaVersion', 'instructions')
        $schemaElement = Get-RequiredJsonProperty $root 'schemaVersion' $rootExpected 'Script'
        if ($schemaElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) { throw 'Script.schemaVersion must be an integer' }
        [uint32]$schemaVersion = 0
        if (-not $schemaElement.TryGetUInt32([ref]$schemaVersion) -or $schemaVersion -ne $script:ScriptSchemaVersion) { throw "Unsupported Script schemaVersion: $($schemaElement.GetRawText())" }

        $instructionsElement = Get-RequiredJsonProperty $root 'instructions' $rootExpected 'Script'
        if ($instructionsElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw 'Script.instructions must be an array' }
        $instructionElements = @($instructionsElement.EnumerateArray())
        if ($instructionElements.Count -gt $script:ScriptMaxInstructions) { throw "Script instruction count exceeds $script:ScriptMaxInstructions" }

        $instructions = [System.Collections.Generic.List[object]]::new($instructionElements.Count)
        foreach ($element in $instructionElements) {
            $expected = @('hook', 'op', 'value')
            $hookElement = Get-RequiredJsonProperty $element 'hook' $expected 'Script.instruction'
            $opElement = Get-RequiredJsonProperty $element 'op' $expected 'Script.instruction'
            $valueElement = Get-RequiredJsonProperty $element 'value' $expected 'Script.instruction'
            if ($hookElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'Script.instruction.hook must be a string' }
            if ($opElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'Script.instruction.op must be a string' }
            $hook = $hookElement.GetString()
            $op = $opElement.GetString()
            $value = Get-JsonVector2 $valueElement 'Script.instruction.value'

            switch ($hook) {
                'on_start' {
                    if ($op -cne 'set_goal_position') { throw 'on_start only supports set_goal_position' }
                    $hookCode = 0
                    $opCode = 0
                }
                'fixed_update' {
                    if ($op -cne 'move_goal_velocity') { throw 'fixed_update only supports move_goal_velocity' }
                    if ([single]([math]::Abs($value[0])) -gt $script:ScriptMaxVelocity -or [single]([math]::Abs($value[1])) -gt $script:ScriptMaxVelocity) {
                        throw "Script velocity exceeds $script:ScriptMaxVelocity"
                    }
                    $hookCode = 1
                    $opCode = 1
                }
                default { throw "Unsupported Script hook: $hook" }
            }
            $instructions.Add([pscustomobject]@{
                HookCode = [uint32]$hookCode
                OperationCode = [uint32]$opCode
                Value = $value
            })
        }
        return [pscustomobject]@{ SchemaVersion = $schemaVersion; Instructions = @($instructions) }
    } catch [System.Text.Json.JsonException] {
        throw "Failed to parse Script JSON: $($_.Exception.Message)"
    } finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}

function Write-ScriptArtifactAtomic([object]$Script, [string]$Path) {
    $temporary = "$Path.tmp.$PID"
    $stream = $null
    $writer = $null
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = [IO.BinaryWriter]::new($stream)
        # BinaryWriter 在 Windows little-endian 平台写出固定 u32/f32 ABI，字段顺序与 Runtime 完全一致。
        $writer.Write([Text.Encoding]::ASCII.GetBytes($script:ScriptArtifactMagic))
        $writer.Write([uint32]$script:ScriptArtifactVersion)
        $writer.Write([uint32]$Script.SchemaVersion)
        $writer.Write([uint32]$Script.Instructions.Count)
        foreach ($instruction in $Script.Instructions) {
            $writer.Write([uint32]$instruction.HookCode)
            $writer.Write([uint32]$instruction.OperationCode)
            $writer.Write([single]$instruction.Value[0])
            $writer.Write([single]$instruction.Value[1])
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

$source = Resolve-ScriptSource $SourcePath
$scriptDocument = Parse-ScriptDocument $source
$destination = Resolve-ScriptDestination $DestinationPath
$artifactBytes = $script:ScriptArtifactHeaderBytes + $scriptDocument.Instructions.Count * $script:ScriptArtifactInstructionBytes

if ($DryRun) {
    $plan = [ordered]@{
        ImporterVersion = $script:ScriptImporterVersion
        BakerVersion = $script:ScriptBakerVersion
        ToolVersion = 'kadath-script-importer/1'
        Action = 'script-import-bake'
        Profile = $Profile
        DryRun = $true
        SourceFormat = 'KADATH-SCRIPT-JSON-V1'
        ArtifactVersion = $script:ScriptArtifactVersion
        ArtifactFormat = 'KSCP-SCRIPT-V1'
        SchemaVersion = $scriptDocument.SchemaVersion
        InstructionCount = $scriptDocument.Instructions.Count
        InstructionBytes = $script:ScriptArtifactInstructionBytes
        ArtifactBytes = $artifactBytes
        Transform = 'script-json-to-kscp-v1'
        Destination = 'generated-assets/scripts/preview.script'
    }
    Write-Output ($plan | ConvertTo-Json -Depth 8 -Compress)
    exit 0
}

New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
Write-ScriptArtifactAtomic $scriptDocument $destination
$hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "script_importer_version=$($script:ScriptImporterVersion)"
Write-Output "script_baker_version=$($script:ScriptBakerVersion)"
Write-Output 'tool_version=kadath-script-importer/1'
Write-Output "profile=$Profile"
Write-Output 'source_format=KADATH-SCRIPT-JSON-V1'
Write-Output "artifact_version=$($script:ScriptArtifactVersion)"
Write-Output 'artifact_format=KSCP-SCRIPT-V1'
Write-Output "schema_version=$($scriptDocument.SchemaVersion)"
Write-Output "instruction_count=$($scriptDocument.Instructions.Count)"
Write-Output "instruction_bytes=$($script:ScriptArtifactInstructionBytes)"
Write-Output 'transform=script-json-to-kscp-v1'
Write-Output "artifact_bytes=$artifactBytes"
Write-Output "sha256=$hash"
Write-Output "artifact=$destination"
Write-Output 'verification=ok'