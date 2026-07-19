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

$package = Resolve-ExistingDirectory $PackageRoot "Package root"
$output = [IO.Path]::GetFullPath($OutputDirectory)
$extract = [IO.Path]::GetFullPath($ExtractDirectory)

if (Test-Path -LiteralPath $output) {
    throw "Output directory already exists; refusing to overwrite: $output"
}
if (Test-Path -LiteralPath $extract) {
    throw "Extract directory already exists; refusing to overwrite: $extract"
}

$requiredFiles = @(
    'bin/kadath.exe',
    'bin/assets/renderer2d/test.ppm',
    'bin/assets/audio/won.wav',
    'bin/assets/audio/lost.wav',
    'README.txt'
)
foreach ($relative in $requiredFiles) {
    $path = Join-Path $package ($relative.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Package is missing required file: $relative"
    }
}

New-Item -ItemType Directory -Path $output -Force | Out-Null
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
        $output = $entry.Open()
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
    }
} finally {
    $zip.Dispose()
    $archiveStream.Dispose()
}
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Archive was not created: $archivePath"
}

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

Write-Output "archive=$archivePath"
Write-Output "manifest=$manifestPath"
Write-Output "extract=$extract"
Write-Output "files=$($expectedMap.Count)"
Write-Output "archive_sha256=$((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Output "verification=ok"
