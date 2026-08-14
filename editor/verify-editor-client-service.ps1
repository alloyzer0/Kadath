[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$ProjectName = "editor_client_service_smoke_$PID",
    [string]$ServiceDll = '',
    [string]$KadathRoot = '',

    [switch]$RealServiceOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$editorRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$kadath = if ([string]::IsNullOrWhiteSpace($KadathRoot)) {
    (Resolve-Path -LiteralPath (Join-Path $editorRoot '..')).Path
} else {
    (Resolve-Path -LiteralPath $KadathRoot).Path
}
$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$service = if ([string]::IsNullOrWhiteSpace($ServiceDll)) {
    Join-Path $editorRoot 'Kadath.Editor.Service\bin\Debug\net8.0\Kadath.Editor.Service.dll'
} else {
    (Resolve-Path -LiteralPath $ServiceDll).Path
}
$verifier = Join-Path $editorRoot 'Kadath.Editor.Client.ContractVerifier\Kadath.Editor.Client.ContractVerifier.csproj'

if (-not (Test-Path -LiteralPath $service -PathType Leaf)) { throw "Editor Service DLL does not exist: $service" }
if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) { throw "Client verifier project does not exist: $verifier" }

$projectsRoot = [IO.Path]::GetFullPath((Join-Path $package 'bin\projects'))
$projectDirectory = [IO.Path]::GetFullPath((Join-Path $projectsRoot $ProjectName))
$projectsPrefix = $projectsRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $projectDirectory.StartsWith($projectsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean a project outside package bin/projects: $projectDirectory"
}

$created = $false
try {
    if (Test-Path -LiteralPath $projectDirectory) {
        throw "Verifier project already exists: $projectDirectory"
    }
    $created = $true

    # 该入口跨越真实 stdio transport，不使用 fake server；项目由当前 project_create RPC 创建。
    $verifierArguments = @($service, $kadath, $package, $ProjectName)
    if ($RealServiceOnly) { $verifierArguments = @('--real-service-only') + $verifierArguments }
    & dotnet run --project $verifier --no-build -- @verifierArguments
    if ($LASTEXITCODE -ne 0) { throw "Editor client service smoke failed with exit code $LASTEXITCODE" }
}
finally {
    # 只删除本次 verifier 创建、且已经通过 projectsRoot 边界检查的临时项目。
    if ($created -and (Test-Path -LiteralPath $projectDirectory -PathType Container)) {
        Remove-Item -LiteralPath $projectDirectory -Recurse -Force
    }
}
