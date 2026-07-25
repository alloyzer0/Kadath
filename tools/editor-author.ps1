[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Create', 'Update', 'Validate', 'Preview')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [float]$SceneGoalX = [float]::NaN,
    [float]$SceneGoalY = [float]::NaN,
    [float]$ScriptGoalX = [float]::NaN,
    [float]$ScriptGoalY = [float]::NaN,
    [float]$ScriptVelocityX = [float]::NaN,
    [float]$ScriptVelocityY = [float]::NaN,

    [string]$ExpectedRevision = '',

    [ValidateRange(0, 300000)]
    [int]$StopAfterMilliseconds = 0,

    [ValidateRange(0, 300000)]
    [int]$ReloadScriptAfterMilliseconds = 0,

    [switch]$WatchChanges,

    [ValidateRange(25, 2000)]
    [int]$PollIntervalMilliseconds = 100,

    [ValidateRange(50, 5000)]
    [int]$DebounceMilliseconds = 250,

    [switch]$StructuredStatus,

    # Live Bake 显式开启；未传入时保留原有 JSON Preview 行为。
    [switch]$LiveBake,

    [ValidateSet('debug', 'release')]
    [string]$BakeProfile = 'debug',

    [string]$DerivedDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Create 的 duplicate/lost-claim 共享同一稳定业务退出码；stdout/stderr 仍只用于诊断。
$ProjectAlreadyExistsExitCode = 17

. (Join-Path $PSScriptRoot 'editor-project-model.ps1')

function Resolve-ExistingDirectory([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Name does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Owner) {
    if ($null -eq $Object) { throw "$Owner is null" }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "$Owner is missing required property: $Name"
    }
    return $property.Value
}

function Assert-Properties([object]$Object, [string[]]$Expected, [string]$Owner) {
    if ($null -eq $Object) { throw "$Owner is null" }
    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -notin $Expected) { throw "$Owner contains an unsupported property: $($property.Name)" }
    }
    foreach ($name in $Expected) { [void](Get-RequiredProperty $Object $name $Owner) }
}

function Assert-Finite([object]$Value, [string]$Name) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) {
        throw "$Name must be numeric"
    }
    try { $number = [double]$Value } catch { throw "$Name must be numeric" }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw "$Name must be finite"
    }
    return $number
}

function Get-Vector([object]$Value, [int]$Length, [string]$Name) {
    $items = @($Value)
    if ($items.Count -ne $Length) { throw "$Name must contain exactly $Length numbers" }
    foreach ($item in $items) { [void](Assert-Finite $item $Name) }
    return $items
}

function Assert-PositiveVector([object]$Value, [string]$Name) {
    foreach ($item in (Get-Vector $Value 2 $Name)) {
        if ([double]$item -le 0.0) { throw "$Name values must be greater than zero" }
    }
}

function Assert-Color([object]$Value, [string]$Name) {
    foreach ($item in (Get-Vector $Value 4 $Name)) {
        if ([double]$item -lt 0.0 -or [double]$item -gt 1.0) {
            throw "$Name values must be in the range [0, 1]"
        }
    }
}

function Assert-SceneSprite([object]$Sprite, [string]$Name) {
    $position = Get-RequiredProperty $Sprite 'position' $Name
    $size = Get-RequiredProperty $Sprite 'size' $Name
    $color = Get-RequiredProperty $Sprite 'color' $Name
    [void](Get-Vector $position 2 "$Name.position")
    Assert-PositiveVector $size "$Name.size"
    Assert-Color $color "$Name.color"
}

function Validate-SceneDocument([object]$Scene) {
    Assert-Properties $Scene @('schemaVersion', 'player', 'goal', 'hazard') 'Scene'
    $schemaVersion = Get-RequiredProperty $Scene 'schemaVersion' 'Scene'
    if ($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) { throw 'Scene schemaVersion must be an integer' }
    if ([int64]$schemaVersion -ne 1) { throw "Unsupported Scene schemaVersion: $schemaVersion" }

    $player = Get-RequiredProperty $Scene 'player' 'Scene'
    $goal = Get-RequiredProperty $Scene 'goal' 'Scene'
    $hazard = Get-RequiredProperty $Scene 'hazard' 'Scene'
    # 与 Runtime 严格 JSON 解析保持一致，避免 CLI 接受 Runtime 会拒绝的未知字段。
    Assert-Properties $player @('position', 'size', 'color', 'moveSpeed') 'Scene.player'
    Assert-Properties $goal @('position', 'size', 'color') 'Scene.goal'
    Assert-Properties $hazard @('position', 'size', 'color', 'patrolMinY', 'patrolMaxY', 'patrolSpeed') 'Scene.hazard'
    Assert-SceneSprite $player 'Scene.player'
    Assert-SceneSprite $goal 'Scene.goal'
    Assert-SceneSprite $hazard 'Scene.hazard'

    $moveSpeed = Assert-Finite (Get-RequiredProperty $player 'moveSpeed' 'Scene.player') 'Scene.player.moveSpeed'
    if ($moveSpeed -lt 0.0) { throw 'Scene.player.moveSpeed must be non-negative' }

    $patrolMinY = Assert-Finite (Get-RequiredProperty $hazard 'patrolMinY' 'Scene.hazard') 'Scene.hazard.patrolMinY'
    $patrolMaxY = Assert-Finite (Get-RequiredProperty $hazard 'patrolMaxY' 'Scene.hazard') 'Scene.hazard.patrolMaxY'
    $patrolSpeed = Assert-Finite (Get-RequiredProperty $hazard 'patrolSpeed' 'Scene.hazard') 'Scene.hazard.patrolSpeed'
    $hazardPosition = Get-Vector (Get-RequiredProperty $hazard 'position' 'Scene.hazard') 2 'Scene.hazard.position'
    if ($patrolMinY -ge $patrolMaxY) { throw 'Scene.hazard patrolMinY must be less than patrolMaxY' }
    if ($patrolSpeed -lt 0.0) { throw 'Scene.hazard.patrolSpeed must be non-negative' }
    if ([double]$hazardPosition[1] -lt $patrolMinY -or [double]$hazardPosition[1] -gt $patrolMaxY) {
        throw 'Scene.hazard.position[1] must be inside the patrol range'
    }
}

function Validate-ScriptDocument([object]$Script) {
    Assert-Properties $Script @('schemaVersion', 'instructions') 'Script'
    $schemaVersion = Get-RequiredProperty $Script 'schemaVersion' 'Script'
    if ($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) { throw 'Script schemaVersion must be an integer' }
    if ([int64]$schemaVersion -ne 1) { throw "Unsupported Script schemaVersion: $schemaVersion" }
    $instructions = @(Get-RequiredProperty $Script 'instructions' 'Script')
    if ($instructions.Count -gt 16) { throw 'Script instruction budget exceeded: maximum is 16' }

    $index = 0
    foreach ($instruction in $instructions) {
        $owner = "Script.instructions[$index]"
        Assert-Properties $instruction @('hook', 'op', 'value') $owner
        $hook = [string](Get-RequiredProperty $instruction 'hook' $owner)
        $op = [string](Get-RequiredProperty $instruction 'op' $owner)
        $value = Get-Vector (Get-RequiredProperty $instruction 'value' $owner) 2 "$owner.value"
        if ($hook -eq 'on_start' -and $op -ne 'set_goal_position') {
            throw "$owner has an invalid on_start operation: $op"
        }
        if ($hook -eq 'fixed_update') {
            if ($op -ne 'move_goal_velocity') { throw "$owner has an invalid fixed_update operation: $op" }
            if ([math]::Abs([double]$value[0]) -gt 1000.0 -or [math]::Abs([double]$value[1]) -gt 1000.0) {
                throw "$owner velocity exceeds the 1000 units/second limit"
            }
        }
        if ($hook -ne 'on_start' -and $hook -ne 'fixed_update') {
            throw "$owner has an unsupported hook: $hook"
        }

        $index++
    }
}

function Resolve-PackagePath(
    [string]$Root,
    [string]$RelativePath,
    [string]$Name,
    [ValidateSet('Leaf', 'Container')]
    [string]$PathType
) {
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "$Name must be relative to the package root: $RelativePath" }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    # 关键安全边界：Authoring CLI 的所有输入和输出必须留在隔离分发包内，拒绝绝对路径与 .. 越界。
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes the package root: $RelativePath"
    }
    $testType = if ($PathType -eq 'Container') { 'Container' } else { 'Leaf' }
    if (-not (Test-Path -LiteralPath $fullPath -PathType $testType)) { throw "$Name does not exist: $RelativePath" }
    return $fullPath
}

function Resolve-ProjectDirectory([string]$Root, [string]$Name, [bool]$AllowMissing) {
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$') {
        throw 'ProjectName must start with a letter or digit and contain at most 48 safe characters'
    }
    $bin = Resolve-PackagePath $Root 'bin' 'Package bin directory' 'Container'
    $projects = Join-Path $bin 'projects'
    if (-not (Test-Path -LiteralPath $projects -PathType Container)) {
        if (-not $AllowMissing) { throw "Projects directory does not exist: $projects" }
        New-Item -ItemType Directory -Path $projects -Force | Out-Null
    }
    $project = [IO.Path]::GetFullPath((Join-Path $projects $Name))
    $projectsPrefix = ([IO.Path]::GetFullPath($projects)).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $project.StartsWith($projectsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Project path escapes projects directory: $Name"
    }
    if ((-not $AllowMissing) -and -not (Test-Path -LiteralPath $project -PathType Container)) {
        throw "Project does not exist: $Name"
    }
    return $project
}

function Read-JsonDocument([string]$Path, [string]$Name) {
    if ((Get-Item -LiteralPath $Path).Length -gt 65536) { throw "$Name exceeds the 64 KiB Runtime document budget: $Path" }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json)
    } catch {
        throw "Failed to parse $Name`: $($_.Exception.Message)"
    }
}

function Write-TextAtomic([string]$Path, [string]$Contents) {
    $temporary = "$Path.tmp.$PID"
    try {
        [IO.File]::WriteAllText($temporary, $Contents, [Text.UTF8Encoding]::new($false))
        # 关键恢复语义：先完整写入同目录临时文件，再替换目标，避免半写入 JSON 被 Runtime 读取。
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-JsonAtomic([object]$Document, [string]$Path) {
    Write-TextAtomic $Path ($Document | ConvertTo-Json -Depth 12)
}

function Get-ProjectFiles([string]$ProjectDirectory) {
    return @{
        Scene = Join-Path $ProjectDirectory 'scene.json'
        Script = Join-Path $ProjectDirectory 'script.json'
        Preview = Join-Path $ProjectDirectory 'preview.json'
    }
}

function Validate-PreviewConfig([object]$Config, [string]$Root) {
    Assert-Properties $Config @('schemaVersion', 'runtime') 'Preview config'
    $schemaVersion = Get-RequiredProperty $Config 'schemaVersion' 'Preview config'
    if ($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) { throw 'Preview config schemaVersion must be an integer' }
    if ([int64]$schemaVersion -ne 1) { throw 'Unsupported Preview config schemaVersion' }
    $runtime = Get-RequiredProperty $Config 'runtime' 'Preview config'
    Assert-Properties $runtime @('executable', 'workingDirectory', 'arguments') 'Preview config.runtime'
    $executable = [string](Get-RequiredProperty $runtime 'executable' 'Preview config.runtime')
    $workingDirectory = [string](Get-RequiredProperty $runtime 'workingDirectory' 'Preview config.runtime')
    [void](Resolve-PackagePath $Root $executable 'Preview executable' 'Leaf')
    $workingDirectoryPath = Resolve-PackagePath $Root $workingDirectory 'Preview working directory' 'Container'
    $arguments = @(Get-RequiredProperty $runtime 'arguments' 'Preview config.runtime')
    $sceneArgumentCount = 0
    $scriptArgumentCount = 0
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        if ($arguments[$index] -isnot [string]) { throw 'Preview config.runtime.arguments must contain only strings' }
        $argument = [string]$arguments[$index]
        if ($argument -eq '--scene' -or $argument -eq '--script') {
            if ($index + 1 -ge $arguments.Count) { throw "Preview config is missing a path after $argument" }
            if ($argument -eq '--scene') { $sceneArgumentCount++ } else { $scriptArgumentCount++ }
            if ($arguments[$index + 1] -isnot [string]) { throw "Preview $argument path must be a string" }
            $runtimeArgument = [string]$arguments[$index + 1]
            if ([IO.Path]::IsPathRooted($runtimeArgument)) { throw "Preview $argument path must be relative to workingDirectory" }
            $runtimeFile = [IO.Path]::GetFullPath((Join-Path $workingDirectoryPath $runtimeArgument))
            $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $runtimeFile.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $runtimeFile -PathType Leaf)) {
                throw "Preview $argument path must resolve to a file inside the package: $runtimeArgument"
            }
            $index++
        }
    }
    if ($sceneArgumentCount -ne 1 -or $scriptArgumentCount -ne 1) { throw 'Preview config must contain exactly one --scene and one --script argument' }
}

function Validate-Project([string]$Root, [string]$ProjectDirectory) {
    $files = Get-ProjectFiles $ProjectDirectory
    foreach ($path in $files.Values) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Project file does not exist: $path" }
    }
    $scene = Read-JsonDocument $files.Scene 'Scene'
    $script = Read-JsonDocument $files.Script 'Script'
    $preview = Read-JsonDocument $files.Preview 'Preview config'
    Validate-SceneDocument $scene
    Validate-ScriptDocument $script
    Validate-PreviewConfig $preview $Root
}

function Test-ProvidedFloat([float]$Value) {
    return -not [float]::IsNaN($Value)
}

function Get-Instruction([object]$Script, [string]$Hook, [string]$Operation) {
    $matches = @($Script.instructions | Where-Object { $_.hook -eq $Hook -and $_.op -eq $Operation })
    if ($matches.Count -ne 1) { throw "Script must contain exactly one $Hook/$Operation instruction before Update" }
    return $matches[0]
}

$package = Resolve-ExistingDirectory $PackageRoot 'Package root'
$projectDirectory = Resolve-ProjectDirectory $package $ProjectName ($Action -eq 'Create')
$files = Get-ProjectFiles $projectDirectory

switch ($Action) {
    'Create' {
        if (Test-Path -LiteralPath $projectDirectory) {
            [Console]::Error.WriteLine("Refusing to overwrite existing project: $ProjectName")
            exit $ProjectAlreadyExistsExitCode
        }
        $ownershipToken = $null
        try {
            $sceneTemplate = Resolve-PackagePath $package 'bin/assets/scenes/preview.scene.json' 'Scene template' 'Leaf'
            $scriptTemplate = Resolve-PackagePath $package 'bin/assets/scripts/preview.script.json' 'Script template' 'Leaf'
            $claimedProjectDirectory = $null
            try {
                $claimedProjectDirectory = New-Item -ItemType Directory -Path $projectDirectory -ErrorAction Stop
            } catch {
                if (Test-Path -LiteralPath $projectDirectory) {
                    [Console]::Error.WriteLine("Lost project directory claim: $ProjectName")
                    exit $ProjectAlreadyExistsExitCode
                }
                throw
            }

            $claimMarker = Join-Path $projectDirectory '.kadath-create-claim'
            $claimValue = [Guid]::NewGuid().ToString('N')
            $claimStream = $null
            try {
                # 关键 ownership 边界：Windows pwsh 可让并发 New-Item 同时返回；CreateNew marker 才是最终目录内的原子排他 claim。
                $claimStream = [IO.File]::Open($claimMarker, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                $claimBytes = [Text.Encoding]::UTF8.GetBytes($claimValue)
                $claimStream.Write($claimBytes, 0, $claimBytes.Length)
                $claimStream.Flush($true)
                $ownershipToken = [pscustomobject]@{
                    Directory = $claimedProjectDirectory
                    MarkerPath = $claimMarker
                    Value = $claimValue
                    Stream = $claimStream
                }
                $claimStream = $null
            } catch {
                if ($null -ne $claimStream) { $claimStream.Dispose() }
                if (Test-Path -LiteralPath $claimMarker -PathType Leaf) {
                    [Console]::Error.WriteLine("Lost project directory claim: $ProjectName")
                    exit $ProjectAlreadyExistsExitCode
                }
                throw
            }

            [IO.File]::Copy($sceneTemplate, $files.Scene)
            [IO.File]::Copy($scriptTemplate, $files.Script)
            $projectRelative = "projects/$ProjectName"
            $preview = [ordered]@{
                schemaVersion = 1
                runtime = [ordered]@{
                    executable = 'bin/kadath.exe'
                    workingDirectory = 'bin'
                    arguments = @('--scene', "$projectRelative/scene.json", '--script', "$projectRelative/script.json")
                }
            }
            Write-JsonAtomic $preview $files.Preview
            Validate-Project $package $projectDirectory
            Write-Output "action=Create"
            Write-Output "project_directory=$projectDirectory"
            Write-Output 'validation=ok'

            $ownershipToken.Stream.Dispose()
            $ownershipToken.Stream = $null
            if (-not (Test-Path -LiteralPath $ownershipToken.MarkerPath -PathType Leaf) -or
                [IO.File]::ReadAllText($ownershipToken.MarkerPath) -ne $ownershipToken.Value) {
                throw 'Project create ownership marker no longer matches this invocation'
            }
            Remove-Item -LiteralPath $ownershipToken.MarkerPath -Force
            $ownershipToken = $null
        } catch {
            # 关键清理边界：只有仍匹配本次 marker 值与已校验目标路径的 ownership token 才能递归清理。
            if ($null -ne $ownershipToken) {
                if ($null -ne $ownershipToken.Stream) {
                    $ownershipToken.Stream.Dispose()
                    $ownershipToken.Stream = $null
                }
                $ownedPath = [IO.Path]::GetFullPath($ownershipToken.Directory.FullName)
                $expectedOwnedPath = [IO.Path]::GetFullPath($projectDirectory)
                if ($ownedPath.Equals($expectedOwnedPath, [StringComparison]::OrdinalIgnoreCase) -and
                    (Test-Path -LiteralPath $ownedPath -PathType Container) -and
                    (Test-Path -LiteralPath $ownershipToken.MarkerPath -PathType Leaf) -and
                    [IO.File]::ReadAllText($ownershipToken.MarkerPath) -eq $ownershipToken.Value) {
                    $ownedItem = Get-Item -LiteralPath $ownedPath -Force
                    if (($ownedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                        Remove-Item -LiteralPath $ownedPath -Recurse -Force
                    }
                }
            }
            throw
        }
    }
    'Update' {
        foreach ($path in $files.Values) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Project file does not exist: $path" } }
        $hasScene = (Test-ProvidedFloat $SceneGoalX) -or (Test-ProvidedFloat $SceneGoalY)
        $hasScriptGoal = (Test-ProvidedFloat $ScriptGoalX) -or (Test-ProvidedFloat $ScriptGoalY)
        $hasScriptVelocity = (Test-ProvidedFloat $ScriptVelocityX) -or (Test-ProvidedFloat $ScriptVelocityY)
        if ((Test-ProvidedFloat $SceneGoalX) -xor (Test-ProvidedFloat $SceneGoalY)) { throw 'SceneGoalX and SceneGoalY must be supplied together' }
        if ((Test-ProvidedFloat $ScriptGoalX) -xor (Test-ProvidedFloat $ScriptGoalY)) { throw 'ScriptGoalX and ScriptGoalY must be supplied together' }
        if ((Test-ProvidedFloat $ScriptVelocityX) -xor (Test-ProvidedFloat $ScriptVelocityY)) { throw 'ScriptVelocityX and ScriptVelocityY must be supplied together' }
        if (-not ($hasScene -or $hasScriptGoal -or $hasScriptVelocity)) { throw 'Update requires at least one editable field' }

        $originalScene = [IO.File]::ReadAllText($files.Scene)
        $originalScript = [IO.File]::ReadAllText($files.Script)
        $previousRevision = Get-EditorAuthoringRevision $files.Scene $files.Script
        if (-not [string]::IsNullOrWhiteSpace($ExpectedRevision)) {
            if ($ExpectedRevision -notmatch '^[0-9a-fA-F]{64}$') { throw '[invalid_expected_revision] ExpectedRevision must be a SHA-256 hex value' }
            if (-not $previousRevision.Equals($ExpectedRevision, [StringComparison]::OrdinalIgnoreCase)) {
                throw "[authoring_revision_conflict] Expected $ExpectedRevision but current revision is $previousRevision"
            }
        }
        try {
            $scene = Read-JsonDocument $files.Scene 'Scene'
            $script = Read-JsonDocument $files.Script 'Script'
            Validate-SceneDocument $scene
            Validate-ScriptDocument $script
            if ($hasScene) { $scene.goal.position = @([double]$SceneGoalX, [double]$SceneGoalY) }
            if ($hasScriptGoal) { (Get-Instruction $script 'on_start' 'set_goal_position').value = @([double]$ScriptGoalX, [double]$ScriptGoalY) }
            if ($hasScriptVelocity) { (Get-Instruction $script 'fixed_update' 'move_goal_velocity').value = @([double]$ScriptVelocityX, [double]$ScriptVelocityY) }
            Validate-SceneDocument $scene
            Validate-ScriptDocument $script
            if ($hasScene) { Write-JsonAtomic $scene $files.Scene }
            if ($hasScriptGoal -or $hasScriptVelocity) { Write-JsonAtomic $script $files.Script }
            $authoringRevision = Get-EditorAuthoringRevision $files.Scene $files.Script
            Write-Output 'action=Update'
            Write-Output "project_directory=$projectDirectory"
            Write-Output "previous_revision=$previousRevision"
            Write-Output "authoring_revision=$authoringRevision"
            Write-Output 'validation=ok'
        } catch {
            # 关键事务语义：任一文件写入失败时恢复本次 Update 之前的两个输入文件。
            Write-TextAtomic $files.Scene $originalScene
            Write-TextAtomic $files.Script $originalScript
            throw
        }
    }
    'Validate' {
        Validate-Project $package $projectDirectory
        Write-Output 'action=Validate'
        Write-Output "project_directory=$projectDirectory"
        Write-Output 'validation=ok'
    }
    'Preview' {
        Validate-Project $package $projectDirectory
        if ($ReloadScriptAfterMilliseconds -gt 0 -and $StopAfterMilliseconds -gt 0 -and $ReloadScriptAfterMilliseconds -ge $StopAfterMilliseconds) {
            throw 'ReloadScriptAfterMilliseconds must be less than StopAfterMilliseconds'
        }
        $previewScript = Join-Path $PSScriptRoot 'editor-preview.ps1'
        & pwsh -NoProfile -File $previewScript -ConfigPath $files.Preview -PackageRoot $package -StopAfterMilliseconds $StopAfterMilliseconds -ReloadScriptAfterMilliseconds $ReloadScriptAfterMilliseconds -WatchChanges:$WatchChanges -PollIntervalMilliseconds $PollIntervalMilliseconds -DebounceMilliseconds $DebounceMilliseconds -StructuredStatus:$StructuredStatus -LiveBake:$LiveBake -BakeProfile $BakeProfile -DerivedDirectory $DerivedDirectory
        if ($LASTEXITCODE -ne 0) { throw "Preview launcher failed with exit code $LASTEXITCODE" }
        Write-Output 'action=Preview'
        Write-Output "project_directory=$projectDirectory"
        Write-Output 'preview=ok'
    }
}
