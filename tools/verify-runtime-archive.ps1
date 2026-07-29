[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [Parameter(Mandatory = $true)]
    [string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-NoReparsePointInExistingPath([string]$Path, [string]$Name) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $relative = [IO.Path]::GetRelativePath($root, $full)
    $current = $root
    foreach ($segment in $relative.Split([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name cannot traverse a reparse point: $current"
        }
    }
}

function Test-DirectoryContains([string]$Parent, [string]$Candidate) {
    $normalizedParent = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedCandidate = [IO.Path]::GetFullPath($Candidate).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return $normalizedParent.Equals($normalizedCandidate, [StringComparison]::OrdinalIgnoreCase) -or
        $normalizedCandidate.StartsWith($normalizedParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

$archiveScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'packaging\archive-runtime.ps1'
if (-not (Test-Path -LiteralPath $archiveScript -PathType Leaf)) { throw "Runtime archive script does not exist: $archiveScript" }
$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
if (Test-Path -LiteralPath $evidence) { throw "Evidence directory already exists: $evidence" }
$evidenceParent = Split-Path -Parent $evidence
if (-not (Test-Path -LiteralPath $evidenceParent -PathType Container)) { throw "Evidence parent does not exist: $evidenceParent" }
Assert-NoReparsePointInExistingPath $package 'Package root'
Assert-NoReparsePointInExistingPath $evidenceParent 'Evidence parent'
if ((Test-DirectoryContains $package $evidence) -or (Test-DirectoryContains $evidence $package)) {
    throw 'PackageRoot and EvidenceDirectory must be disjoint'
}
New-Item -ItemType Directory -Path $evidence | Out-Null

$requiredFiles = [string[]]@(
    'bin/assets/audio/lost.audio.wav',
    'bin/assets/audio/lost.wav',
    'bin/assets/audio/won.audio.wav',
    'bin/assets/audio/won.wav',
    'bin/assets/renderer2d/goal.png',
    'bin/assets/renderer2d/goal.texture',
    'bin/assets/renderer2d/test.png',
    'bin/assets/renderer2d/test.texture',
    'bin/assets/scenes/preview.scene',
    'bin/assets/scenes/preview.scene.json',
    'bin/assets/scripts/preview.script',
    'bin/assets/scripts/preview.script.json',
    'bin/kadath-runtime-build-profile.json',
    'bin/kadath.exe',
    'README.txt'
)

function New-ArchiveProcess([string]$Package, [string]$Output, [string]$Extract, [string]$Stdout, [string]$Stderr, [string]$Barrier = '') {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'pwsh'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $archiveScript, '-PackageRoot', $Package, '-OutputDirectory', $Output, '-ExtractDirectory', $Extract)) {
        [void]$start.ArgumentList.Add($argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($Barrier)) {
        [void]$start.ArgumentList.Add('-VerificationBarrierDirectory')
        [void]$start.ArgumentList.Add($Barrier)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Failed to start archive child process' }
    return [pscustomobject]@{ Process = $process; Stdout = $Stdout; Stderr = $Stderr }
}

function Complete-ArchiveProcess([object]$Child, [int]$TimeoutMilliseconds = 120000) {
    $stdoutTask = $Child.Process.StandardOutput.ReadToEndAsync()
    $stderrTask = $Child.Process.StandardError.ReadToEndAsync()
    if (-not $Child.Process.WaitForExit($TimeoutMilliseconds)) {
        $Child.Process.Kill($true)
        $Child.Process.WaitForExit()
        throw 'Archive child process timed out'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText($Child.Stdout, $stdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($Child.Stderr, $stderr, [Text.UTF8Encoding]::new($false))
    $exitCode = $Child.Process.ExitCode
    $Child.Process.Dispose()
    return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $stdout; Stderr = $stderr }
}

function Invoke-Archive([string]$Name, [string]$Package, [string]$Output, [string]$Extract, [switch]$ExpectFailure) {
    $stdout = Join-Path $evidence "$Name.stdout.log"
    $stderr = Join-Path $evidence "$Name.stderr.log"
    $result = Complete-ArchiveProcess (New-ArchiveProcess $Package $Output $Extract $stdout $stderr)
    if (-not $ExpectFailure -and $result.ExitCode -ne 0) { throw "Archive '$Name' failed: $($result.Stderr)" }
    if ($ExpectFailure -and $result.ExitCode -eq 0) { throw "Archive '$Name' unexpectedly succeeded" }
    return $result
}

function Copy-Package([string]$Destination) {
    New-Item -ItemType Directory -Path $Destination | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $package -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Assert-ArchiveEvidence([string]$Output, [string]$Extract) {
    $archive = Join-Path $Output 'kadath-runtime-win-x64.zip'
    $manifest = Join-Path $Output 'manifest.sha256'
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or -not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'Archive output is incomplete' }
    $manifestLines = @(Get-Content -LiteralPath $manifest)
    $extractFiles = @(Get-ChildItem -LiteralPath $Extract -File -Recurse)
    if ($manifestLines.Count -ne 15 -or $extractFiles.Count -ne 15) { throw "Archive evidence must contain exactly 15 files: manifest=$($manifestLines.Count), extract=$($extractFiles.Count)" }

    $manifestMap = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $manifestLines.Count; $index++) {
        $match = [regex]::Match($manifestLines[$index], '^(?<hash>[0-9a-f]{64})  (?<path>.+)$')
        if (-not $match.Success) { throw "Archive manifest line $index is invalid" }
        $relative = $match.Groups['path'].Value
        if ($relative -cne $requiredFiles[$index]) { throw "Archive manifest path order mismatch at index $index" }
        if (-not $manifestMap.TryAdd($relative, $match.Groups['hash'].Value)) { throw "Archive manifest contains a duplicate path: $relative" }
    }

    $extractMap = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($file in $extractFiles) {
        $relative = [IO.Path]::GetRelativePath($Extract, $file.FullName).Replace('\', '/')
        if (-not $extractMap.TryAdd($relative, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())) {
            throw "Archive extract contains a duplicate path: $relative"
        }
    }

    $zipMap = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { throw "Archive contains a directory entry: $($entry.FullName)" }
            $stream = $entry.Open()
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try {
                $hash = [Convert]::ToHexString($algorithm.ComputeHash($stream)).ToLowerInvariant()
            } finally {
                $algorithm.Dispose()
                $stream.Dispose()
            }
            if (-not $zipMap.TryAdd($entry.FullName, $hash)) { throw "Archive contains a duplicate ZIP entry: $($entry.FullName)" }
        }
    } finally {
        $zip.Dispose()
    }

    if ($zipMap.Count -ne 15 -or $extractMap.Count -ne 15) { throw 'Archive ZIP/extract file counts must both be 15' }
    foreach ($relative in $requiredFiles) {
        if (-not $manifestMap.ContainsKey($relative) -or -not $extractMap.ContainsKey($relative) -or -not $zipMap.ContainsKey($relative) -or
            $manifestMap[$relative] -cne $extractMap[$relative] -or $manifestMap[$relative] -cne $zipMap[$relative]) {
            throw "Archive manifest, ZIP, and extract identities differ: $relative"
        }
    }
    return (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-FailedWithoutOutput([string]$Output, [string]$Extract, [object]$Result) {
    if (Test-Path -LiteralPath $Output) { throw "Failed archive left an output directory: $Output" }
    if (Test-Path -LiteralPath $Extract) { throw "Failed archive left an extract directory: $Extract" }
    $prewriteMarkers = @([regex]::Matches($Result.Stderr, '(?m)^archive_write_started=false\r?$'))
    if ($prewriteMarkers.Count -ne 1) { throw "Pre-write rejection must report exactly one archive_write_started=false line, got $($prewriteMarkers.Count)" }
}

$outputA = Join-Path $evidence 'repro-output-a'
$extractA = Join-Path $evidence 'repro-extract-a'
$outputB = Join-Path $evidence 'repro-output-b'
$extractB = Join-Path $evidence 'repro-extract-b'
[void](Invoke-Archive 'repro-a' $package $outputA $extractA)
[void](Invoke-Archive 'repro-b' $package $outputB $extractB)
$archiveHashA = Assert-ArchiveEvidence $outputA $extractA
$archiveHashB = Assert-ArchiveEvidence $outputB $extractB
if ($archiveHashA -cne $archiveHashB) { throw "Deterministic archive hashes differ: $archiveHashA <> $archiveHashB" }

$mutationPackage = Join-Path $evidence 'mutation-package'
Copy-Package $mutationPackage
$mutationOutput = Join-Path $evidence 'mutation-output'
$mutationExtract = Join-Path $evidence 'mutation-extract'
$barrier = Join-Path $evidence 'mutation-barrier'
New-Item -ItemType Directory -Path $barrier | Out-Null
$mutationChild = New-ArchiveProcess $mutationPackage $mutationOutput $mutationExtract (Join-Path $evidence 'mutation.stdout.log') (Join-Path $evidence 'mutation.stderr.log') $barrier
$readyPath = Join-Path $barrier 'snapshot-ready'
$wait = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
    if ($mutationChild.Process.HasExited) { throw 'Archive exited before publishing the mutation barrier' }
    if ($wait.ElapsedMilliseconds -ge 10000) { $mutationChild.Process.Kill($true); throw 'Timed out waiting for archive mutation barrier' }
    Start-Sleep -Milliseconds 25
}

$goalTexture = Join-Path $mutationPackage 'bin\assets\renderer2d\goal.texture'
$originalGoalTextureBytes = [IO.File]::ReadAllBytes($goalTexture)
$originalGoalTextureSha256 = (Get-FileHash -LiteralPath $goalTexture -Algorithm SHA256).Hash.ToLowerInvariant()
$mutationSucceeded = $false
$mutationResults = [ordered]@{}
$replacement = $null
try {
    $stream = [IO.File]::Open($goalTexture, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $first = $stream.ReadByte()
        $stream.Position = 0
        $stream.WriteByte([byte](($first + 1) -band 0xff))
        $stream.Flush($true)
        $mutationSucceeded = $true
        $mutationResults.Write = 'succeeded'
    } finally { $stream.Dispose() }
} catch { $mutationResults.Write = "denied:$($_.Exception.GetType().Name)" }
try {
    $renamed = "$goalTexture.renamed"
    Move-Item -LiteralPath $goalTexture -Destination $renamed
    $mutationSucceeded = $true
    $mutationResults.Rename = 'succeeded'
} catch { $mutationResults.Rename = "denied:$($_.Exception.GetType().Name)" }
try {
    $replacement = Join-Path $evidence 'goal.texture.replacement'
    [IO.File]::WriteAllBytes($replacement, [byte[]](1,2,3,4))
    [IO.File]::Replace($replacement, $goalTexture, $null)
    $mutationSucceeded = $true
    $mutationResults.Replace = 'succeeded'
} catch { $mutationResults.Replace = "denied:$($_.Exception.GetType().Name)" }
$mutationResult = $null
$mutationChildCompleted = $false
try {
    [IO.File]::WriteAllText((Join-Path $barrier 'continue'), '', [Text.UTF8Encoding]::new($false))
    $mutationResult = Complete-ArchiveProcess $mutationChild
    $mutationChildCompleted = $true
} finally {
    if (-not $mutationChildCompleted -and -not $mutationChild.Process.HasExited) {
        $mutationChild.Process.Kill($true)
        $mutationChild.Process.WaitForExit()
    }
    foreach ($ownedMutationPath in @($goalTexture, "$goalTexture.renamed")) {
        if (Test-Path -LiteralPath $ownedMutationPath) { Remove-Item -LiteralPath $ownedMutationPath -Force }
    }
    [IO.File]::WriteAllBytes($goalTexture, $originalGoalTextureBytes)
    if ((Get-FileHash -LiteralPath $goalTexture -Algorithm SHA256).Hash.ToLowerInvariant() -cne $originalGoalTextureSha256) {
        throw 'Verifier failed to restore its owned mutation package goal.texture identity'
    }
    if ($null -ne $replacement -and (Test-Path -LiteralPath $replacement)) { Remove-Item -LiteralPath $replacement -Force }
}
[IO.File]::WriteAllText((Join-Path $evidence 'mutation-results.json'), ($mutationResults | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
if ($mutationSucceeded) {
    if ($mutationResult.ExitCode -eq 0) { throw 'Archive accepted a package mutation that succeeded behind retained handles' }
    Assert-FailedWithoutOutput $mutationOutput $mutationExtract $mutationResult
} else {
    if ($mutationResult.ExitCode -ne 0) { throw "Archive failed after all mutation operations were sharing-denied: $($mutationResult.Stderr)" }
    [void](Assert-ArchiveEvidence $mutationOutput $mutationExtract)
}

$missingSourcePackage = Join-Path $evidence 'missing-secondary-source-package'
Copy-Package $missingSourcePackage
Remove-Item -LiteralPath (Join-Path $missingSourcePackage 'bin\assets\renderer2d\goal.png') -Force
$missingSourceOutput = Join-Path $evidence 'missing-secondary-source-output'
$missingSourceExtract = Join-Path $evidence 'missing-secondary-source-extract'
$missingSourceResult = Invoke-Archive 'missing-secondary-source' $missingSourcePackage $missingSourceOutput $missingSourceExtract -ExpectFailure
Assert-FailedWithoutOutput $missingSourceOutput $missingSourceExtract $missingSourceResult

$missingArtifactPackage = Join-Path $evidence 'missing-secondary-artifact-package'
Copy-Package $missingArtifactPackage
Remove-Item -LiteralPath (Join-Path $missingArtifactPackage 'bin\assets\renderer2d\goal.texture') -Force
$missingArtifactOutput = Join-Path $evidence 'missing-secondary-artifact-output'
$missingArtifactExtract = Join-Path $evidence 'missing-secondary-artifact-extract'
$missingArtifactResult = Invoke-Archive 'missing-secondary-artifact' $missingArtifactPackage $missingArtifactOutput $missingArtifactExtract -ExpectFailure
Assert-FailedWithoutOutput $missingArtifactOutput $missingArtifactExtract $missingArtifactResult

$markerSourcePackage = Join-Path $evidence 'marker-secondary-source-package'
Copy-Package $markerSourcePackage
$markerSourcePath = Join-Path $markerSourcePackage 'bin\kadath-runtime-build-profile.json'
$markerSource = Get-Content -LiteralPath $markerSourcePath -Raw -Encoding utf8 | ConvertFrom-Json
$markerSource.SecondaryTextureSourceSha256 = '0' * 64
[IO.File]::WriteAllText($markerSourcePath, (($markerSource | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
$markerSourceOutput = Join-Path $evidence 'marker-secondary-source-output'
$markerSourceExtract = Join-Path $evidence 'marker-secondary-source-extract'
$markerSourceResult = Invoke-Archive 'marker-secondary-source' $markerSourcePackage $markerSourceOutput $markerSourceExtract -ExpectFailure
Assert-FailedWithoutOutput $markerSourceOutput $markerSourceExtract $markerSourceResult

$markerArtifactPackage = Join-Path $evidence 'marker-secondary-artifact-package'
Copy-Package $markerArtifactPackage
$markerArtifactPath = Join-Path $markerArtifactPackage 'bin\kadath-runtime-build-profile.json'
$markerArtifact = Get-Content -LiteralPath $markerArtifactPath -Raw -Encoding utf8 | ConvertFrom-Json
$markerArtifact.SecondaryTextureArtifactSha256 = '0' * 64
[IO.File]::WriteAllText($markerArtifactPath, (($markerArtifact | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
$markerArtifactOutput = Join-Path $evidence 'marker-secondary-artifact-output'
$markerArtifactExtract = Join-Path $evidence 'marker-secondary-artifact-extract'
$markerArtifactResult = Invoke-Archive 'marker-secondary-artifact' $markerArtifactPackage $markerArtifactOutput $markerArtifactExtract -ExpectFailure
Assert-FailedWithoutOutput $markerArtifactOutput $markerArtifactExtract $markerArtifactResult

$reparsePackage = Join-Path $evidence 'reparse-package'
Copy-Package $reparsePackage
$rendererDirectory = Join-Path $reparsePackage 'bin\assets\renderer2d'
$rendererTarget = Join-Path $evidence 'reparse-renderer-target'
Move-Item -LiteralPath $rendererDirectory -Destination $rendererTarget
[void](New-Item -ItemType Junction -Path $rendererDirectory -Target $rendererTarget)
$reparseOutput = Join-Path $evidence 'reparse-output'
$reparseExtract = Join-Path $evidence 'reparse-extract'
$reparseResult = Invoke-Archive 'reparse' $reparsePackage $reparseOutput $reparseExtract -ExpectFailure
Assert-FailedWithoutOutput $reparseOutput $reparseExtract $reparseResult

$retainedOutput = Join-Path $evidence 'preexisting-output'
New-Item -ItemType Directory -Path $retainedOutput | Out-Null
$sentinel = Join-Path $retainedOutput 'sentinel.txt'
[IO.File]::WriteAllText($sentinel, 'retain', [Text.UTF8Encoding]::new($false))
$retainedExtract = Join-Path $evidence 'preexisting-extract'
$retainedResult = Invoke-Archive 'preexisting-output' $package $retainedOutput $retainedExtract -ExpectFailure
if ((Get-Content -LiteralPath $sentinel -Raw) -cne 'retain' -or (Test-Path -LiteralPath $retainedExtract)) { throw 'Pre-existing output retention failed' }
$preexistingMarkers = @([regex]::Matches($retainedResult.Stderr, '(?m)^archive_write_started=false\r?$'))
if ($preexistingMarkers.Count -ne 1) { throw 'Pre-existing output rejection must report exactly one archive_write_started=false line' }

$summary = [ordered]@{
    Version = 2
    ArchiveSha256 = $archiveHashA
    Files = 15
    Reproducible = $true
    MutationSucceeded = $mutationSucceeded
    MutationPackageRestored = $true
    MissingSecondarySourceRejected = $true
    MissingSecondaryArtifactRejected = $true
    SecondarySourceMarkerRejected = $true
    SecondaryArtifactMarkerRejected = $true
    ReparseRejected = $true
    ExistingOutputRetained = $true
}
[IO.File]::WriteAllText((Join-Path $evidence 'verification.json'), (($summary | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output "archive_sha256=$archiveHashA"
Write-Output "archive_manifest=$(Join-Path $outputA 'manifest.sha256')"
Write-Output "archive_extract=$extractA"
Write-Output 'archive_files=15'
Write-Output 'archive_reproducibility=ok'
Write-Output 'held_stream_mutation=ok'
Write-Output 'secondary_identity_rejection=ok'
Write-Output 'reparse_rejection=ok'
Write-Output 'rollback_retention=ok'
Write-Output 'verification=ok'
