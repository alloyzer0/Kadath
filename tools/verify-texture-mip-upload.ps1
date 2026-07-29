[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$OutputDirectory = (Join-Path $env:TEMP ("kadath-texture-mip-upload-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$workflowVerifier = Join-Path $PSScriptRoot 'verify-editor-workflow.ps1'
if (-not (Test-Path -LiteralPath $workflowVerifier -PathType Leaf)) { throw "Workflow verifier does not exist: $workflowVerifier" }
$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Output directory already exists: $output" }
$workflowOutput = Join-Path $output 'workflow'
$texturePaths = @(
    (Join-Path $package 'bin\assets\renderer2d\test.texture'),
    (Join-Path $package 'bin\assets\renderer2d\goal.texture')
)
foreach ($texturePath in $texturePaths) {
    if (-not (Test-Path -LiteralPath $texturePath -PathType Leaf)) { throw "Texture artifact does not exist: $texturePath" }
}

try {
    foreach ($texturePath in $texturePaths) {
        [byte[]]$artifact = [IO.File]::ReadAllBytes($texturePath)
        if ($artifact.Length -lt 24 -or [Text.Encoding]::ASCII.GetString($artifact, 0, 4) -cne 'KDAT') { throw "Runtime texture artifact has an invalid KDAT header: $texturePath" }
        $version = [BitConverter]::ToUInt32($artifact, 4)
        $mipLevelCount = [BitConverter]::ToUInt32($artifact, 16)
        $pixelBytes = [BitConverter]::ToUInt32($artifact, 20)
        if ($version -ne 2 -or $mipLevelCount -ne 2 -or $pixelBytes -ne 20 -or $artifact.Length -ne 44) { throw "Runtime texture artifact is not the expected KDAT v2 mip chain: $texturePath" }
    }
    $goalHash = (Get-FileHash -LiteralPath $texturePaths[1] -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($goalHash -cne '555c2e554e2e5eb70e9de20e3e3182482d826dcfff230be45c54d321cd7e8c2c') { throw "Goal Runtime texture identity mismatch: $goalHash" }

    $workflowLines = @(& pwsh -NoProfile -File $workflowVerifier -PackageRoot $package -OutputDirectory $workflowOutput 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "Workflow verifier failed: $($workflowLines -join ' | ')" }
    if (@($workflowLines | Where-Object { $_ -ceq 'verification=ok' }).Count -ne 1) { throw 'Workflow verifier did not complete successfully' }

    $runtimeLogPath = Join-Path $workflowOutput 'runtime.stderr.log'
    if (-not (Test-Path -LiteralPath $runtimeLogPath -PathType Leaf)) { throw 'Runtime stderr log is missing' }
    $runtimeLog = [IO.File]::ReadAllText($runtimeLogPath)
    # 关键运行证据：同时证明 Resource→Renderer2D 传递和 Vulkan RHI multi-region upload 已执行。
    if (-not $runtimeLog.Contains('RHI texture created: handle=1, extent=2x2, mip_levels=2, upload_bytes=20')) { throw 'RHI multi-mip upload evidence is missing' }
    if (-not $runtimeLog.Contains('RHI texture created: handle=2, extent=2x2, mip_levels=2, upload_bytes=20')) { throw 'Secondary RHI multi-mip upload evidence is missing' }
    if ([regex]::Matches($runtimeLog, [regex]::Escape('Renderer2D texture upload complete: mip_levels=2, sampler=smooth_mipmap_anisotropic')).Count -lt 2) { throw 'Renderer2D dual anisotropic sampler request evidence is missing' }
    if ([regex]::Matches($runtimeLog, [regex]::Escape('sampler_requested=smooth_mipmap_anisotropic')).Count -lt 2) { throw 'RHI dual anisotropic sampler request evidence is missing' }
    $anisotropyEnabled = $runtimeLog.Contains('sampler=smooth_mipmap_anisotropic, anisotropy=on, anisotropy_level=4, lod=0..1')
    $anisotropyFallback = $runtimeLog.Contains('sampler=smooth_mipmap, anisotropy=off, anisotropy_level=1, lod=0..1') -and $runtimeLog.Contains('Texture sampler anisotropy unsupported; falling back to smooth_mipmap')
    if (-not ($anisotropyEnabled -or $anisotropyFallback)) { throw 'RHI anisotropy capability evidence is missing' }

    Write-Output 'texture_artifact_version=2'
    Write-Output 'texture_artifact_count=2'
    Write-Output 'mip_level_count=2'
    Write-Output 'upload_bytes=20'
    Write-Output 'rhi_mip_upload=ok'
    Write-Output 'renderer2d_mip_upload=ok'
    Write-Output 'sampler_profile=smooth_mipmap_anisotropic'
    Write-Output 'lod_range=0..1'
    if ($anisotropyEnabled) { Write-Output 'anisotropy=enabled' } else { Write-Output 'anisotropy=fallback_to_smooth_mipmap' }
    Write-Output 'sampler_policy=ok'
    Write-Output 'runtime_workflow=ok'
    Write-Output 'verification=ok'
} finally {
    if (Test-Path -LiteralPath $output) {
        $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $output.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Verifier cleanup root escapes temp: $output" }
        Remove-Item -LiteralPath $output -Recurse -Force
    }
}
