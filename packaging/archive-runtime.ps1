[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string]$ExtractDirectory
)

$ErrorActionPreference = "Stop"

function Resolve-ExistingDirectory([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Name does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Normalize-RelativePath([string]$Root, [string]$Path) {
    return [IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Assert-NoWin32DevicePath([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name cannot be empty" }
    $windowsSpelling = $Path.Replace('/', '\')
    if ($windowsSpelling.StartsWith('\\', [StringComparison]::Ordinal) -or
        $windowsSpelling.StartsWith('\??\', [StringComparison]::Ordinal)) {
        throw "$Name cannot use a UNC, Win32 device, or extended path: $Path"
    }
}

function Assert-NoReparsePointInExistingPath([string]$Path, [string]$Name) {
    Assert-NoWin32DevicePath $Path $Name
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $relative = [IO.Path]::GetRelativePath($root, $full)
    $current = $root
    if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Name root cannot be a reparse point: $current" }
    foreach ($segment in $relative.Split([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        $info = Get-Item -LiteralPath $current -Force
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Name cannot traverse a reparse point: $current" }
    }
}

function Test-DirectoryContains([string]$Parent, [string]$Candidate) {
    $normalizedParent = $Parent.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedCandidate = $Candidate.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($normalizedParent.Equals($normalizedCandidate, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $normalizedCandidate.StartsWith($normalizedParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DisjointDirectories([string]$Left, [string]$LeftName, [string]$Right, [string]$RightName) {
    if ((Test-DirectoryContains $Left $Right) -or (Test-DirectoryContains $Right $Left)) {
        throw "$LeftName and $RightName must be disjoint directories: $Left <> $Right"
    }
}

$archiveWriteStarted = $false
try {

Assert-NoWin32DevicePath $PackageRoot 'Package root'
Assert-NoWin32DevicePath $OutputDirectory 'Output directory'
Assert-NoWin32DevicePath $ExtractDirectory 'Extract directory'
if (-not [IO.Path]::IsPathFullyQualified($PackageRoot) -or
    -not [IO.Path]::IsPathFullyQualified($OutputDirectory) -or
    -not [IO.Path]::IsPathFullyQualified($ExtractDirectory)) {
    throw 'PackageRoot, OutputDirectory, and ExtractDirectory must be fully qualified local paths'
}
$packageInput = [IO.Path]::GetFullPath($PackageRoot)
$output = [IO.Path]::GetFullPath($OutputDirectory)
$extract = [IO.Path]::GetFullPath($ExtractDirectory)

# 关键事务前置：所有路径关系和现存 ancestor 在首次写入前完成校验。
Assert-NoReparsePointInExistingPath $packageInput 'Package root'
Assert-NoReparsePointInExistingPath $output 'Output directory'
Assert-NoReparsePointInExistingPath $extract 'Extract directory'
$package = Resolve-ExistingDirectory $packageInput "Package root"
Assert-DisjointDirectories $package 'Package root' $output 'Output directory'
Assert-DisjointDirectories $package 'Package root' $extract 'Extract directory'
Assert-DisjointDirectories $output 'Output directory' $extract 'Extract directory'

if (Test-Path -LiteralPath $output) {
    throw "Output directory already exists; refusing to overwrite: $output"
}
if (Test-Path -LiteralPath $extract) {
    throw "Extract directory already exists; refusing to overwrite: $extract"
}

$reparseEntries = @(Get-ChildItem -LiteralPath $package -Force -Recurse | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
if ($reparseEntries.Count -ne 0) { throw "Package tree cannot contain a reparse point: $($reparseEntries[0].FullName)" }

$requiredFiles = @(
    'bin/kadath.exe',
    'bin/kadath-runtime-build-profile.json',
    'bin/assets/renderer2d/test.png',
    'bin/assets/renderer2d/test.texture',
    'bin/assets/audio/won.wav',
    'bin/assets/audio/lost.wav',
    'bin/assets/audio/won.audio.wav',
    'bin/assets/audio/lost.audio.wav',
    'bin/assets/scenes/preview.scene',
    'bin/assets/scenes/preview.scene.json',
    'bin/assets/scripts/preview.script',
    'bin/assets/scripts/preview.script.json',
    'README.txt'
)
foreach ($relative in $requiredFiles) {
    $path = Join-Path $package ($relative.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Package is missing required file: $relative"
    }
}

$runtimePath = Join-Path $package 'bin\kadath.exe'
$textureSourcePath = Join-Path $package 'bin\assets\renderer2d\test.png'
$textureArtifactPath = Join-Path $package 'bin\assets\renderer2d\test.texture'
$profileMarkerPath = Join-Path $package 'bin\kadath-runtime-build-profile.json'
[byte[]]$profileMarkerBytes = [IO.File]::ReadAllBytes($profileMarkerPath)
if ($profileMarkerBytes.Length -eq 0 -or $profileMarkerBytes.Length -gt 65536) { throw 'Runtime build profile marker must contain 1..65536 bytes' }
try {
    $profileMarkerJson = [Text.UTF8Encoding]::new($false, $true).GetString($profileMarkerBytes)
    $profileMarkerJsonDocument = [System.Text.Json.JsonDocument]::Parse($profileMarkerJson)
    try {
        $rootElement = $profileMarkerJsonDocument.RootElement
        if ($rootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'root must be an object' }
        $expectedProfileFields = [string[]]@('Version', 'Optimize', 'TextureProfile', 'RuntimeExeSha256', 'TextureSourceSha256', 'TextureArtifactSha256', 'VertexShaderSourceSha256', 'FragmentShaderSourceSha256', 'BuildPreflightSidecarSha256')
        $actualProfileFields = @($rootElement.EnumerateObject() | ForEach-Object { $_.Name })
        $uniqueProfileFields = @($actualProfileFields | Sort-Object -Unique -CaseSensitive)
        if ($actualProfileFields.Count -ne 9 -or $uniqueProfileFields.Count -ne 9 -or
            @(Compare-Object -ReferenceObject ($expectedProfileFields | Sort-Object) -DifferenceObject ($actualProfileFields | Sort-Object) -CaseSensitive).Count -ne 0) {
            throw 'properties must be unique and exactly match the nine schema v1 names'
        }
        $versionElement = $rootElement.GetProperty('Version')
        if ($versionElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or $versionElement.GetInt32() -ne 1) { throw 'Version must be the JSON number 1' }
        $stringFields = $expectedProfileFields | Where-Object { $_ -cne 'Version' }
        foreach ($field in $stringFields) {
            if ($rootElement.GetProperty($field).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw "$field must be a JSON string" }
        }
        $profileMarker = [pscustomobject][ordered]@{
            Version = 1
            Optimize = $rootElement.GetProperty('Optimize').GetString()
            TextureProfile = $rootElement.GetProperty('TextureProfile').GetString()
            RuntimeExeSha256 = $rootElement.GetProperty('RuntimeExeSha256').GetString()
            TextureSourceSha256 = $rootElement.GetProperty('TextureSourceSha256').GetString()
            TextureArtifactSha256 = $rootElement.GetProperty('TextureArtifactSha256').GetString()
            VertexShaderSourceSha256 = $rootElement.GetProperty('VertexShaderSourceSha256').GetString()
            FragmentShaderSourceSha256 = $rootElement.GetProperty('FragmentShaderSourceSha256').GetString()
            BuildPreflightSidecarSha256 = $rootElement.GetProperty('BuildPreflightSidecarSha256').GetString()
        }
    } finally {
        $profileMarkerJsonDocument.Dispose()
    }
} catch {
    throw "Runtime build profile marker is not strict UTF-8 exact-nine JSON schema v1: $($_.Exception.Message)"
}
$runtimeSha256 = (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant()
$textureSourceSha256 = (Get-FileHash -LiteralPath $textureSourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
$textureArtifactSha256 = (Get-FileHash -LiteralPath $textureArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ([int]$profileMarker.Version -ne 1 -or
    [string]$profileMarker.Optimize -cne 'ReleaseSafe' -or
    [string]$profileMarker.TextureProfile -cne 'release' -or
    [string]$profileMarker.RuntimeExeSha256 -cne $runtimeSha256 -or
    [string]$profileMarker.TextureSourceSha256 -cne $textureSourceSha256 -or
    [string]$profileMarker.TextureArtifactSha256 -cne $textureArtifactSha256 -or
    [string]$profileMarker.VertexShaderSourceSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [string]$profileMarker.FragmentShaderSourceSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [string]$profileMarker.BuildPreflightSidecarSha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'Runtime archive requires a sidecar-bound ReleaseSafe marker matching the package executable, PNG, and KDAT identities'
}

$outputOwned = $false
$extractOwned = $false
$archiveCompleted = $false
try {
    $archiveWriteStarted = $true
    New-Item -ItemType Directory -Path $output | Out-Null
    $outputOwned = $true
    $archivePath = Join-Path $output 'kadath-runtime-win-x64.zip'
    $manifestPath = Join-Path $output 'manifest.sha256'

$files = @(Get-ChildItem -LiteralPath $package -File -Recurse | Sort-Object FullName)
if ($files.Count -eq 0) { throw "Package root contains no files: $package" }

$manifestLines = foreach ($file in $files) {
    $relative = Normalize-RelativePath $package $file.FullName
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "{0}  {1}" -f $hash, $relative
}

# 关键可复现性：manifest 按相对路径排序，归档传递后可逐项比较而不依赖绝对路径。
$manifestLines = @($manifestLines | Sort-Object { ($_ -split '  ', 2)[1] })
Set-Content -LiteralPath $manifestPath -Value $manifestLines -Encoding utf8NoBOM

# 固定条目顺序和时间戳，避免 Compress-Archive 的文件时间元数据造成归档哈希漂移。
Add-Type -AssemblyName System.IO.Compression
$archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$zip = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
try {
    foreach ($file in $files) {
        $relative = Normalize-RelativePath $package $file.FullName
        $entry = $zip.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $input = [IO.File]::OpenRead($file.FullName)
        $entryOutput = $entry.Open()
        try { $input.CopyTo($entryOutput) } finally { $entryOutput.Dispose(); $input.Dispose() }
    }
} finally {
    $zip.Dispose()
    $archiveStream.Dispose()
}
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Archive was not created: $archivePath"
}

New-Item -ItemType Directory -Path $extract | Out-Null
$extractOwned = $true
Expand-Archive -LiteralPath $archivePath -DestinationPath $extract -Force
$extractedFiles = @(Get-ChildItem -LiteralPath $extract -File -Recurse | Sort-Object FullName)
$extractedMap = @{}
foreach ($file in $extractedFiles) {
    $relative = Normalize-RelativePath $extract $file.FullName
    $extractedMap[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}

$expectedMap = @{}
foreach ($line in Get-Content -LiteralPath $manifestPath) {
    $parts = $line -split '  ', 2
    if ($parts.Count -ne 2 -or $parts[0].Length -ne 64) { throw "Invalid manifest line: $line" }
    $expectedMap[$parts[1]] = $parts[0].ToLowerInvariant()
}

if ($expectedMap.Count -ne $extractedMap.Count) {
    throw "Archive file count mismatch: expected=$($expectedMap.Count), extracted=$($extractedMap.Count)"
}
foreach ($relative in $expectedMap.Keys) {
    if (-not $extractedMap.ContainsKey($relative)) { throw "Archive is missing file: $relative" }
    if ($extractedMap[$relative] -ne $expectedMap[$relative]) { throw "Archive hash mismatch: $relative" }
}

$archiveCompleted = $true
Write-Output "archive=$archivePath"
Write-Output "manifest=$manifestPath"
Write-Output "extract=$extract"
Write-Output "files=$($expectedMap.Count)"
Write-Output "archive_sha256=$((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Output "verification=ok"
} finally {
    if (-not $archiveCompleted) {
        # 只回滚本调用确认创建的根；所有 pre-existing 根已在首次写入前拒绝。
        if ($extractOwned -and (Test-Path -LiteralPath $extract -PathType Container)) {
            $extractInfo = Get-Item -LiteralPath $extract -Force
            if (($extractInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { Remove-Item -LiteralPath $extract -Recurse -Force }
        }
        if ($outputOwned -and (Test-Path -LiteralPath $output -PathType Container)) {
            $outputInfo = Get-Item -LiteralPath $output -Force
            if (($outputInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { Remove-Item -LiteralPath $output -Recurse -Force }
        }
    }
}
} catch {
    if (-not $archiveWriteStarted) { [Console]::Error.WriteLine('archive_write_started=false') }
    throw
}
