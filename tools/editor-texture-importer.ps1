[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [ValidateSet('debug', 'release')]
    [string]$Profile = 'debug',

    # DryRun 只解析/校验 PPM 并计算 profile 计划，不创建二进制文件。
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TextureArtifactMagic = 'KDAT'
$script:TextureArtifactVersionBase = 1
$script:TextureArtifactVersionMipmap = 2
$script:TextureArtifactHeaderBytesBase = 20
$script:TextureArtifactHeaderBytesMipmap = 24
$script:TextureArtifactMaxPixels = 1024 * 1024
$script:TextureArtifactMaxBytes = 8 * 1024 * 1024

function Resolve-TextureSource([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Texture source does not exist: $Path" }
    $source = (Resolve-Path -LiteralPath $Path).Path
    $file = Get-Item -LiteralPath $source
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Texture source cannot be a reparse point' }
    if ([IO.Path]::GetExtension($source).ToLowerInvariant() -ne '.ppm') { throw 'Texture importer expects a .ppm source' }
    return $source
}

function Resolve-TextureDestination([string]$Path) {
    $destination = [IO.Path]::GetFullPath($Path)
    if ([string]::IsNullOrWhiteSpace($destination) -or $destination -eq [IO.Path]::GetPathRoot($destination)) { throw "Invalid texture destination: $Path" }
    if ([IO.Path]::GetExtension($destination).ToLowerInvariant() -ne '.texture') { throw 'Texture artifact destination must use the .texture extension' }
    # 关键不可变性边界：Importer 生成源/派生目录，禁止直接覆盖已安装 package/bin/assets。
    if ($destination -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw 'Texture artifact destination must not be package/bin/assets' }
    if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite existing texture artifact: $destination" }
    $existingParent = Split-Path -Parent $destination
    while (-not (Test-Path -LiteralPath $existingParent -PathType Container)) {
        $nextParent = Split-Path -Parent $existingParent
        if ([string]::IsNullOrWhiteSpace($nextParent) -or $nextParent -eq $existingParent) { throw "Cannot resolve texture artifact parent: $destination" }
        $existingParent = $nextParent
    }
    $parentInfo = Get-Item -LiteralPath $existingParent
    if (($parentInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Texture artifact parent cannot be a reparse point' }
    return $destination
}

function Parse-Ppm3([string]$Path) {
    $contents = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    # P3 允许行尾注释；删除注释后只按 ASCII 数字/空白解析，避免文化区域影响。
    $withoutComments = [regex]::Replace($contents, '(?m)#.*$', '')
    $tokens = @($withoutComments -split '\s+' | Where-Object { $_.Length -gt 0 })
    if ($tokens.Count -lt 4 -or [string]$tokens[0] -cne 'P3') { throw 'Texture source must use P3 PPM format' }
    $values = [int[]]::new(3)
    for ($index = 0; $index -lt 3; $index++) {
        $number = 0
        if (-not [int]::TryParse([string]$tokens[$index + 1], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { throw 'PPM dimensions/range must be integers' }
        $values[$index] = $number
    }
    $width = $values[0]
    $height = $values[1]
    $maxValue = $values[2]
    if ($width -le 0 -or $height -le 0 -or $maxValue -le 0 -or $maxValue -gt 255) { throw 'PPM dimensions must be positive and max value must be in [1, 255]' }
    $pixelCount = [long]$width * [long]$height
    if ($pixelCount -gt $script:TextureArtifactMaxPixels) { throw "PPM exceeds pixel limit: $pixelCount > $script:TextureArtifactMaxPixels" }
    $expectedTokens = 4 + ($pixelCount * 3)
    if ($tokens.Count -ne $expectedTokens) { throw "PPM pixel token count mismatch: expected=$($expectedTokens - 4) actual=$($tokens.Count - 4)" }
    [byte[]]$pixels = New-Object byte[] ([int]($pixelCount * 4))
    for ($pixel = 0; $pixel -lt $pixelCount; $pixel++) {
        for ($channel = 0; $channel -lt 3; $channel++) {
            $sample = 0
            $tokenIndex = 4 + ($pixel * 3) + $channel
            if (-not [int]::TryParse([string]$tokens[$tokenIndex], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$sample)) { throw 'PPM samples must be integers' }
            if ($sample -lt 0 -or $sample -gt $maxValue) { throw 'PPM sample is outside max value range' }
            $pixels[($pixel * 4) + $channel] = [byte][math]::Floor(($sample * 255.0) / $maxValue)
        }
        $pixels[($pixel * 4) + 3] = 255
    }
    return [pscustomobject]@{ Width = $width; Height = $height; Pixels = $pixels }
}

function Get-TextureLevels([object]$BaseTexture, [string]$Profile) {
    $levels = [System.Collections.Generic.List[object]]::new()
    $levels.Add([pscustomobject]@{ Width = $BaseTexture.Width; Height = $BaseTexture.Height; Pixels = [byte[]]$BaseTexture.Pixels }) | Out-Null
    if ($Profile -eq 'debug') { return @($levels.ToArray()) }

    # Release profile 的确定性变换：2x2 box filter，边缘 sample clamp，整数 floor 平均。
    $source = $levels[0]
    while ($source.Width -gt 1 -or $source.Height -gt 1) {
        $nextWidth = [math]::Max(1, [int][math]::Floor($source.Width / 2.0))
        $nextHeight = [math]::Max(1, [int][math]::Floor($source.Height / 2.0))
        [byte[]]$nextPixels = New-Object byte[] ($nextWidth * $nextHeight * 4)
        for ($nextY = 0; $nextY -lt $nextHeight; $nextY++) {
            for ($nextX = 0; $nextX -lt $nextWidth; $nextX++) {
                [int]$sumR = 0; [int]$sumG = 0; [int]$sumB = 0; [int]$sumA = 0
                for ($dy = 0; $dy -lt 2; $dy++) {
                    $sampleY = [math]::Min($source.Height - 1, ($nextY * 2) + $dy)
                    for ($dx = 0; $dx -lt 2; $dx++) {
                        $sampleX = [math]::Min($source.Width - 1, ($nextX * 2) + $dx)
                        $sampleOffset = (($sampleY * $source.Width) + $sampleX) * 4
                        $sumR += $source.Pixels[$sampleOffset + 0]
                        $sumG += $source.Pixels[$sampleOffset + 1]
                        $sumB += $source.Pixels[$sampleOffset + 2]
                        $sumA += $source.Pixels[$sampleOffset + 3]
                    }
                }
                $nextOffset = (($nextY * $nextWidth) + $nextX) * 4
                $nextPixels[$nextOffset + 0] = [byte][math]::Floor($sumR / 4.0)
                $nextPixels[$nextOffset + 1] = [byte][math]::Floor($sumG / 4.0)
                $nextPixels[$nextOffset + 2] = [byte][math]::Floor($sumB / 4.0)
                $nextPixels[$nextOffset + 3] = [byte][math]::Floor($sumA / 4.0)
            }
        }
        $next = [pscustomobject]@{ Width = $nextWidth; Height = $nextHeight; Pixels = $nextPixels }
        $levels.Add($next) | Out-Null
        $source = $next
    }
    return @($levels.ToArray())
}

function Write-TextureArtifactAtomic([object]$Texture, [object[]]$Levels, [string]$Profile, [string]$Path) {
    $temporary = "$Path.tmp.$PID"
    $stream = $null
    $writer = $null
    $release = $Profile -eq 'release'
    $version = if ($release) { $script:TextureArtifactVersionMipmap } else { $script:TextureArtifactVersionBase }
    $headerBytes = if ($release) { $script:TextureArtifactHeaderBytesMipmap } else { $script:TextureArtifactHeaderBytesBase }
    [long]$pixelBytes = 0
    foreach ($level in @($Levels)) { $pixelBytes += $level.Pixels.Length }
    if ($headerBytes + $pixelBytes -gt $script:TextureArtifactMaxBytes) { throw "Texture artifact exceeds size limit: $($headerBytes + $pixelBytes) > $script:TextureArtifactMaxBytes" }
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = [IO.BinaryWriter]::new($stream)
        $writer.Write([Text.Encoding]::ASCII.GetBytes($script:TextureArtifactMagic))
        $writer.Write([uint32]$version)
        $writer.Write([uint32]$Texture.Width)
        $writer.Write([uint32]$Texture.Height)
        if ($release) { $writer.Write([uint32]$Levels.Count) }
        $writer.Write([uint32]$pixelBytes)
        foreach ($level in @($Levels)) { $writer.Write([byte[]]$level.Pixels) }
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

$source = Resolve-TextureSource $SourcePath
$texture = Parse-Ppm3 $source
$levels = @(Get-TextureLevels $texture $Profile)
$destination = Resolve-TextureDestination $DestinationPath
$release = $Profile -eq 'release'
$artifactVersion = if ($release) { $script:TextureArtifactVersionMipmap } else { $script:TextureArtifactVersionBase }
$artifactFormat = if ($release) { 'KDAT-TEXTURE-V2-MIPMAP' } else { 'KDAT-TEXTURE-V1' }
$transform = if ($release) { 'ppm-to-rgba8-mipmap-artifact-v2' } else { 'ppm-to-rgba8-artifact-v1' }
$headerBytes = if ($release) { $script:TextureArtifactHeaderBytesMipmap } else { $script:TextureArtifactHeaderBytesBase }
[long]$pixelBytes = 0
foreach ($level in @($levels)) { $pixelBytes += $level.Pixels.Length }
$artifactBytes = $headerBytes + $pixelBytes
if ($DryRun) {
    $plan = [ordered]@{
        ImporterVersion = 1
        BakerVersion = 1
        ToolVersion = 'kadath-texture-importer/2'
        Action = 'texture-import-bake'
        Profile = $Profile
        DryRun = $true
        SourceFormat = 'P3-PPM'
        ArtifactVersion = $artifactVersion
        ArtifactFormat = $artifactFormat
        Width = $texture.Width
        Height = $texture.Height
        PixelFormat = 'RGBA8'
        MipLevelCount = $levels.Count
        MipDimensions = @($levels | ForEach-Object { "$($_.Width)x$($_.Height)" })
        Transform = $transform
        ArtifactBytes = $artifactBytes
        Destination = 'generated-assets/renderer2d/test.texture'
    }
    Write-Output ($plan | ConvertTo-Json -Depth 8 -Compress)
    exit 0
}

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Write-TextureArtifactAtomic $texture $levels $Profile $destination
    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output 'texture_importer_version=1'
    Write-Output 'texture_baker_version=1'
    Write-Output 'tool_version=kadath-texture-importer/2'
    Write-Output "profile=$Profile"
    Write-Output 'source_format=P3-PPM'
    Write-Output "artifact_version=$artifactVersion"
    Write-Output "artifact_format=$artifactFormat"
    Write-Output "width=$($texture.Width)"
    Write-Output "height=$($texture.Height)"
    Write-Output 'pixel_format=RGBA8'
    Write-Output "mip_level_count=$($levels.Count)"
    Write-Output "transform=$transform"
    Write-Output "artifact_bytes=$artifactBytes"
    Write-Output "sha256=$hash"
    Write-Output "artifact=$destination"
    Write-Output 'verification=ok'
} catch {
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
    throw
}