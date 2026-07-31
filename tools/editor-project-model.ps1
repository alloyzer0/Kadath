Set-StrictMode -Version Latest

# Project Model v1 是 GUI 的只读投影，不取代 editor-author.ps1 的权威校验与写入事务。
$script:EditorProjectModelVersion = 1
function Get-EditorAuthoringRevision([string]$ScenePath, [string]$ScriptPath) {
    foreach ($path in @($ScenePath, $ScriptPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Authoring source does not exist: $path" }
    }
    $sceneHash = (Get-FileHash -LiteralPath $ScenePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $scriptHash = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $identity = "kadath-authoring-v1`nscene:$sceneHash`nscript:$scriptHash"
    $bytes = [Text.Encoding]::UTF8.GetBytes($identity)
    $digest = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($digest).ToLowerInvariant()
}

function Assert-EditorProjectName([string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$') {
        throw 'ProjectName must start with a letter or digit and contain at most 48 safe characters'
    }
}

function Get-EditorProjectFiles([string]$PackageRoot, [string]$Name) {
    Assert-EditorProjectName $Name
    $projects = Join-Path (Join-Path $PackageRoot 'bin') 'projects'
    $project = [IO.Path]::GetFullPath((Join-Path $projects $Name))
    $prefix = [IO.Path]::GetFullPath($projects).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    # 关键安全边界：Project Model 只能读取 package/bin/projects 下的项目文件。
    if (-not $project.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Project path escapes projects directory: $Name"
    }
    return [ordered]@{
        Directory = $project
        Scene = Join-Path $project 'scene.json'
        Script = Join-Path $project 'script.json'
        Preview = Join-Path $project 'preview.json'
    }
}

function Read-EditorJson([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Name does not exist: $Path" }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        throw "Failed to parse $Name`: $($_.Exception.Message)"
    }
}

function Read-EditorProjectModel([string]$PackageRoot, [string]$Name) {
    $root = (Resolve-Path -LiteralPath $PackageRoot).Path
    $files = Get-EditorProjectFiles $root $Name
    $scene = Read-EditorJson $files.Scene 'Scene'
    $scriptDocument = Read-EditorJson $files.Script 'Script'
    $preview = Read-EditorJson $files.Preview 'Preview config'

    $onStart = @($scriptDocument.instructions | Where-Object { $_.hook -eq 'on_start' -and $_.op -eq 'set_goal_position' })
    $fixedUpdate = @($scriptDocument.instructions | Where-Object { $_.hook -eq 'fixed_update' -and $_.op -eq 'move_goal_velocity' })
    if ($onStart.Count -ne 1 -or $fixedUpdate.Count -ne 1) {
        throw 'Project script does not contain the editable Hook v1 instructions'
    }

    # 只投影当前稳定字段；原始文档仍留在文件系统，未知字段不会被模型重写或丢弃。
    return [pscustomobject]@{
        ModelVersion = $script:EditorProjectModelVersion
        ProjectName = $Name
        AuthoringRevision = Get-EditorAuthoringRevision $files.Scene $files.Script
        Files = [pscustomobject]@{
            Directory = $files.Directory
            Scene = $files.Scene
            Script = $files.Script
            Preview = $files.Preview
        }
        Scene = [pscustomobject]@{
            SchemaVersion = [int]$scene.schemaVersion
            GoalPosition = @([double]$scene.goal.position[0], [double]$scene.goal.position[1])
            PlayerTextureId = [uint32]$scene.player.textureId
            GoalTextureId = [uint32]$scene.goal.textureId
            HazardTextureId = [uint32]$scene.hazard.textureId
        }
        Script = [pscustomobject]@{
            SchemaVersion = [int]$scriptDocument.schemaVersion
            GoalPosition = @([double]$onStart[0].value[0], [double]$onStart[0].value[1])
            GoalVelocity = @([double]$fixedUpdate[0].value[0], [double]$fixedUpdate[0].value[1])
        }
        Preview = [pscustomobject]@{
            SchemaVersion = [int]$preview.schemaVersion
        }
    }
}

function Get-EditorProjectEditableValues([object]$Model) {
    if ($null -eq $Model) { throw 'Project Model is null' }
    if ([int]$Model.ModelVersion -ne $script:EditorProjectModelVersion) {
        throw "Unsupported Project Model version: $($Model.ModelVersion)"
    }
    return @{
        SceneGoalX = $Model.Scene.GoalPosition[0]
        SceneGoalY = $Model.Scene.GoalPosition[1]
        ScenePlayerTextureId = $Model.Scene.PlayerTextureId
        SceneGoalTextureId = $Model.Scene.GoalTextureId
        SceneHazardTextureId = $Model.Scene.HazardTextureId
        ScriptGoalX = $Model.Script.GoalPosition[0]
        ScriptGoalY = $Model.Script.GoalPosition[1]
        ScriptVelocityX = $Model.Script.GoalVelocity[0]
        ScriptVelocityY = $Model.Script.GoalVelocity[1]
    }
}

function Convert-EditorVectorToText([object]$Value) {
    return (@($Value) | ForEach-Object { ([double]$_).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture) }) -join ', '
}

function New-EditorHierarchyNode([string]$Id, [string]$ParentId, [string]$DisplayName, [string]$Kind, [hashtable]$Properties) {
    # 根节点统一输出 JSON null，避免 PowerShell [string] 空值变成空字符串。
    $normalizedParentId = if ([string]::IsNullOrWhiteSpace($ParentId)) { $null } else { $ParentId }
    return [pscustomobject]@{
        Id = $Id
        ParentId = $normalizedParentId
        DisplayName = $DisplayName
        Kind = $Kind
        Properties = $Properties
    }
}
function Get-EditorHierarchySnapshot([object]$Model) {
    if ($null -eq $Model) { throw 'Project Model is null' }
    if ([int]$Model.ModelVersion -ne $script:EditorProjectModelVersion) {
        throw "Unsupported Project Model version for hierarchy: $($Model.ModelVersion)"
    }
    $scene = Read-EditorJson $Model.Files.Scene 'Scene'
    $scriptDocument = Read-EditorJson $Model.Files.Script 'Script'
    $preview = Read-EditorJson $Model.Files.Preview 'Preview config'
    $nodes = [System.Collections.Generic.List[object]]::new()

    $nodes.Add((New-EditorHierarchyNode 'scene' $null 'Scene' 'SceneDocument' ([ordered]@{
        SchemaVersion = [int]$scene.schemaVersion
        File = $Model.Files.Scene
    })))
    $nodes.Add((New-EditorHierarchyNode 'scene.player' 'scene' 'Player' 'Sprite' ([ordered]@{
        Position = Convert-EditorVectorToText $scene.player.position
        Size = Convert-EditorVectorToText $scene.player.size
        Color = Convert-EditorVectorToText $scene.player.color
        MoveSpeed = ([double]$scene.player.moveSpeed).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
        TextureId = [uint32]$scene.player.textureId
    })))
    $nodes.Add((New-EditorHierarchyNode 'scene.goal' 'scene' 'Goal' 'Sprite' ([ordered]@{
        Position = Convert-EditorVectorToText $scene.goal.position
        Size = Convert-EditorVectorToText $scene.goal.size
        Color = Convert-EditorVectorToText $scene.goal.color
        TextureId = [uint32]$scene.goal.textureId
    })))
    $nodes.Add((New-EditorHierarchyNode 'scene.hazard' 'scene' 'Hazard' 'Sprite' ([ordered]@{
        Position = Convert-EditorVectorToText $scene.hazard.position
        Size = Convert-EditorVectorToText $scene.hazard.size
        Color = Convert-EditorVectorToText $scene.hazard.color
        TextureId = [uint32]$scene.hazard.textureId
        PatrolRange = "$( [double]$scene.hazard.patrolMinY ) - $( [double]$scene.hazard.patrolMaxY )"
        PatrolSpeed = ([double]$scene.hazard.patrolSpeed).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
    })))

    $nodes.Add((New-EditorHierarchyNode 'script' $null 'Script' 'ScriptDocument' ([ordered]@{
        SchemaVersion = [int]$scriptDocument.schemaVersion
        InstructionCount = @($scriptDocument.instructions).Count
        File = $Model.Files.Script
    })))
    $instructionIndex = 0
    foreach ($instruction in @($scriptDocument.instructions)) {
        $nodes.Add((New-EditorHierarchyNode "script.instructions[$instructionIndex]" 'script' "Instruction $instructionIndex" 'HookInstruction' ([ordered]@{
            Hook = [string]$instruction.hook
            Operation = [string]$instruction.op
            Value = Convert-EditorVectorToText $instruction.value
        })))
        $instructionIndex++
    }

    $nodes.Add((New-EditorHierarchyNode 'preview' $null 'Preview Config' 'PreviewConfig' ([ordered]@{
        SchemaVersion = [int]$preview.schemaVersion
        Executable = [string]$preview.runtime.executable
        WorkingDirectory = [string]$preview.runtime.workingDirectory
        ArgumentCount = @($preview.runtime.arguments).Count
        File = $Model.Files.Preview
    })))

    return [pscustomobject]@{
        SnapshotVersion = 1
        ProjectModelVersion = [int]$Model.ModelVersion
        ProjectName = $Model.ProjectName
        Nodes = @($nodes)
    }
}
