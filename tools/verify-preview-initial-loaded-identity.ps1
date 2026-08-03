[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'editor-preview.example.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath $PackageRoot).Path
$config = (Resolve-Path -LiteralPath $ConfigPath).Path
$launcher = Join-Path $PSScriptRoot 'editor-preview.ps1'
$contractVerifier = Join-Path $PSScriptRoot '..\editor\Kadath.Editor.Client.ContractVerifier\Kadath.Editor.Client.ContractVerifier.csproj'
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$tempRoot = Join-Path $tempParent ("kadath-initial-loaded-$PID-" + [Guid]::NewGuid().ToString('N'))

function Invoke-Launcher([string]$CaseRoot) {
    $output = @(& pwsh -NoProfile -File $launcher -ConfigPath $config -PackageRoot $CaseRoot -StructuredStatus -StopAfterMilliseconds 800 2>&1)
    $exitCode = $LASTEXITCODE
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $output) {
        $line = $item.ToString().Trim()
        if (-not $line.StartsWith('{', [StringComparison]::Ordinal)) { continue }
        try {
            $event = $line | ConvertFrom-Json
            if ($null -ne $event.PSObject.Properties['event']) { $events.Add($event) }
        } catch {
            throw "Launcher emitted malformed structured output: $line"
        }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Events = $events }
}

function Assert-SingleEvent([object]$Run, [string]$Name) {
    $matches = @($Run.Events | Where-Object { [string]$_.event -eq $Name })
    if ($matches.Count -ne 1) { throw "Expected exactly one $Name event, got $($matches.Count)" }
    return $matches[0]
}

function Assert-FailedInitial([object]$Run, [string]$CaseName) {
    if ($Run.ExitCode -eq 0) { throw "$CaseName unexpectedly succeeded" }
    [void](Assert-SingleEvent $Run 'runtime_failed')
    $failed = Assert-SingleEvent $Run 'runtime_initial_load_failed'
    if ([int]$failed.loadVersion -ne 1 -or [string]$failed.state -ne 'failed' -or [string]::IsNullOrWhiteSpace([string]$failed.errorCode)) {
        throw "$CaseName initial failure payload mismatch"
    }
    if (@($Run.Events | Where-Object { [string]$_.event -eq 'runtime_initial_loaded' }).Count -ne 0) {
        throw "$CaseName published loaded identity after startup failure"
    }
}

try {
    $success = Invoke-Launcher $root
    if ($success.ExitCode -ne 0) { throw "Initial identity success case failed: $($success.Output -join ' | ')" }
    $ready = Assert-SingleEvent $success 'runtime_ready'
    $loaded = Assert-SingleEvent $success 'runtime_initial_loaded'
    $readyIndex = [array]::IndexOf([object[]]$success.Events.ToArray(), $ready)
    $loadedIndex = [array]::IndexOf([object[]]$success.Events.ToArray(), $loaded)
    if ($readyIndex -lt 0 -or $loadedIndex -le $readyIndex) { throw 'Launcher published initial identity before Runtime ready evidence' }
    if ($null -ne $loaded.PSObject.Properties['requestId']) { throw 'Initial identity must not be disguised as requestId=0 reload' }

    $targets = @(
        [pscustomobject]@{ Name = 'scene'; Path = Join-Path $root 'bin\assets\scenes\preview.scene'; Bytes = 140 },
        [pscustomobject]@{ Name = 'script'; Path = Join-Path $root 'bin\assets\scripts\preview.script'; Bytes = 48 }
    )
    foreach ($target in $targets) {
        $runtimeIdentity = $ready.initialLoaded.PSObject.Properties[$target.Name].Value
        $projected = $loaded.PSObject.Properties[$target.Name].Value
        $expectedHash = (Get-FileHash -LiteralPath $target.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedBytes = [uint64](Get-Item -LiteralPath $target.Path).Length
        if ([string]$runtimeIdentity.kind -ne 'artifact' -or [string]$runtimeIdentity.sha256 -cne $expectedHash -or [uint64]$runtimeIdentity.bytes -ne $expectedBytes) {
            throw "Runtime $($target.Name) identity does not match the parsed artifact"
        }
        if ([string]$projected.artifactRevision -cne $expectedHash -or [uint64]$projected.artifactBytes -ne $expectedBytes -or [string]$projected.correlation -ne 'runtime_only') {
            throw "Launcher $($target.Name) projection changed Runtime artifact facts"
        }
        if ($expectedBytes -ne [uint64]$target.Bytes -or $expectedHash -cnotmatch '^[0-9a-f]{64}$') {
            throw "Fixture $($target.Name) identity does not satisfy the fixed-width wire contract"
        }
    }

    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $missingRoot = Join-Path $tempRoot 'missing'
    Copy-Item -LiteralPath $root -Destination $missingRoot -Recurse
    Remove-Item -LiteralPath (Join-Path $missingRoot 'bin\assets\scenes\preview.scene') -Force
    Assert-FailedInitial (Invoke-Launcher $missingRoot) 'missing artifact'

    $corruptRoot = Join-Path $tempRoot 'corrupt'
    Copy-Item -LiteralPath $root -Destination $corruptRoot -Recurse
    [IO.File]::WriteAllBytes((Join-Path $corruptRoot 'bin\assets\scenes\preview.scene'), [byte[]](0..31))
    Assert-FailedInitial (Invoke-Launcher $corruptRoot) 'corrupt artifact'

    # stale/failed/restart retention 由协议层的确定性状态机测试覆盖，避免用竞态伪造 Runtime 事实。
    $contractOutput = @(& dotnet run --project $contractVerifier --no-build 2>&1)
    if ($LASTEXITCODE -ne 0 -or @($contractOutput | Where-Object { $_.ToString() -eq 'preview_initial_loaded_state=ok' }).Count -ne 1) {
        throw "Client initial/reload retention contract failed: $($contractOutput -join ' | ')"
    }

    Write-Output 'runtime_initial_identity=ok'
    Write-Output 'runtime_initial_missing_artifact=ok'
    Write-Output 'runtime_initial_corrupt_artifact=ok'
    Write-Output 'runtime_initial_stale_retention=ok'
    Write-Output 'verification=ok'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        if (-not $resolvedTemp.StartsWith($tempParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([IO.Path]::GetFileName($resolvedTemp)).StartsWith('kadath-initial-loaded-', [StringComparison]::Ordinal)) {
            throw "Refusing to clean unexpected verifier directory: $resolvedTemp"
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
