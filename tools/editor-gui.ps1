[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$ProjectName = 'authoring_demo',

    # 无桌面 CI 使用该开关验证入口、参数和既有 authoring 契约，不创建窗口。
    [switch]$Headless,

    # 由 verifier 驱动真实按钮事件的可重复 GUI workflow smoke。
    [switch]$WorkflowSmoke
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:resolvedPackageRoot = $null
$script:authorScript = Join-Path $PSScriptRoot 'editor-author.ps1'
$script:previewScript = Join-Path $PSScriptRoot 'editor-preview.ps1'
$script:modelScript = Join-Path $PSScriptRoot 'editor-project-model.ps1'
if (-not (Test-Path -LiteralPath $script:modelScript -PathType Leaf)) { throw ('Project Model adapter does not exist: ' + $script:modelScript) }
. $script:modelScript
$script:assetCatalogScript = Join-Path $PSScriptRoot 'editor-asset-catalog.ps1'
if (-not (Test-Path -LiteralPath $script:assetCatalogScript -PathType Leaf)) { throw ('Asset Catalog adapter does not exist: ' + $script:assetCatalogScript) }
. $script:assetCatalogScript
$script:projectName = $ProjectName
$script:projectLoaded = $false
$script:previewProcess = $null
$script:previewStdoutTask = $null
$script:previewStderrTask = $null
$script:previewExitedAt = $null
$script:runtimeProcess = $null
$script:stopDeadline = $null
$script:controls = @{}
$script:runWorkflowSmoke = [bool]$WorkflowSmoke
$script:workflowStage = 0
$script:workflowStartedAt = $null
$script:workflowProjectDirectory = $null
$script:workflowSmokeError = $null
$script:workflowProjectCreated = $false
$script:workflowCompletedCommands = 0
$script:workflowReloadAcknowledged = 0
$script:workflowInitialLoaded = 0
$script:workflowEvidence = @()
$script:workflowTickActive = $false
$script:hierarchySnapshot = $null
$script:hierarchyBindingActive = $false
$script:assetCatalogSnapshot = $null
$script:assetBindingActive = $false
$script:lastUiError = $null

function Resolve-PackageRoot([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Package root does not exist: $Path"
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (-not (Test-Path -LiteralPath (Join-Path $resolved 'bin') -PathType Container)) {
        throw "Package root must contain a bin directory: $resolved"
    }
    return $resolved
}

function Assert-ProjectName([string]$Name) {
    Assert-EditorProjectName $Name
}

function Get-ProjectFiles([string]$Name) {
    return Get-EditorProjectFiles $script:resolvedPackageRoot $Name
}

function Invoke-AuthorAction([string]$Action, [hashtable]$Values = @{}) {
    if (-not (Test-Path -LiteralPath $script:authorScript -PathType Leaf)) {
        throw "Authoring adapter does not exist: $script:authorScript"
    }
    $arguments = @('-NoProfile', '-File', $script:authorScript, '-Action', $Action, '-PackageRoot', $script:resolvedPackageRoot, '-ProjectName', $script:projectName)
    foreach ($name in @('SceneGoalX', 'SceneGoalY', 'ScriptGoalX', 'ScriptGoalY', 'ScriptVelocityX', 'ScriptVelocityY')) {
        if ($Values.ContainsKey($name)) {
            $rawValue = $Values[$name]
            $formatted = if ($rawValue -is [IFormattable]) { $rawValue.ToString($null, [Globalization.CultureInfo]::InvariantCulture) } else { [string]$rawValue }
            $arguments += @("-$name", $formatted)
        }
    }
    # 关键扩展边界：GUI 只调用稳定的 CLI，未来可替换为 JSON/IPC adapter 而不改变表单事件。
    $output = & pwsh @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw $message
    }
    return @($output | ForEach-Object { $_.ToString() })
}

function Set-NumberText([string]$Name, [double]$Value) {
    $script:controls[$Name].Text = $Value.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
}

function Read-Number([string]$Name) {
    $raw = $script:controls[$Name].Text.Trim()
    $value = 0.0
    if (-not [double]::TryParse($raw, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        throw "$Name must be a finite number"
    }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw "$Name must be a finite number" }
    return $value
}

function Read-DebounceMilliseconds {
    $value = 0
    if (-not [int]::TryParse($script:controls.Debounce.Text.Trim(), [ref]$value) -or $value -lt 50 -or $value -gt 5000) {
        throw 'Debounce 必须是 50 到 5000 之间的整数毫秒值'
    }
    return $value
}

function Read-EditableValues {
    return @{
        SceneGoalX = Read-Number 'SceneGoalX'
        SceneGoalY = Read-Number 'SceneGoalY'
        ScriptGoalX = Read-Number 'ScriptGoalX'
        ScriptGoalY = Read-Number 'ScriptGoalY'
        ScriptVelocityX = Read-Number 'ScriptVelocityX'
        ScriptVelocityY = Read-Number 'ScriptVelocityY'
    }
}

function Set-Status([string]$Message, [bool]$IsError = $false) {
    # Headless/旧协议事件可能在 WinForms 控件尚未创建时到达；Hashtable 缺失键也必须视为“无 UI 投影”。
    $status = if ($script:controls.ContainsKey('Status')) { $script:controls['Status'] } else { $null }
    if ($null -eq $status -or $status.IsDisposed) { return }
    $status.Text = $Message
    $status.ForeColor = if ($IsError) { [Drawing.Color]::Firebrick } else { [Drawing.Color]::DarkGreen }
}

function Write-Log([string]$Message) {
    $log = if ($script:controls.ContainsKey('Log')) { $script:controls['Log'] } else { $null }
    if ($null -eq $log -or $log.IsDisposed) { return }
    $log.AppendText("[$([DateTime]::Now.ToString('HH:mm:ss'))] $Message`r`n")
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
}

function Show-InspectorProperties([object]$Node) {
    if ($null -eq $script:controls.Inspector) { return }
    $script:controls.Inspector.Items.Clear()
    if ($null -eq $Node) { return }
    foreach ($name in $Node.Properties.Keys) {
        $item = New-Object Windows.Forms.ListViewItem([string]$name)
        [void]$item.SubItems.Add([string]$Node.Properties[$name])
        [void]$script:controls.Inspector.Items.Add($item)
    }
}

function Bind-HierarchySnapshot([object]$Snapshot) {
    if ($null -eq $script:controls.Hierarchy) { return }
    if ([int]$Snapshot.SnapshotVersion -ne 1) { throw "Unsupported Hierarchy Snapshot version: $($Snapshot.SnapshotVersion)" }
    $tree = $script:controls.Hierarchy
    $nodeMap = @{}
    $script:hierarchyBindingActive = $true
    try {
        $tree.Nodes.Clear()
        $script:controls.Inspector.Items.Clear()
        foreach ($node in $Snapshot.Nodes) {
            $treeNode = New-Object Windows.Forms.TreeNode([string]$node.DisplayName)
            $treeNode.Tag = $node
            $nodeMap[$node.Id] = $treeNode
            if ([string]::IsNullOrWhiteSpace([string]$node.ParentId)) {
                [void]$tree.Nodes.Add($treeNode)
            } else {
                [void]$nodeMap[$node.ParentId].Nodes.Add($treeNode)
            }
        }
        $tree.ExpandAll()
        # 绑定期间禁止 AfterSelect 回调重入；TreeView 状态稳定后再填充只读 Inspector。
        if ($null -ne $nodeMap['scene.goal']) {
            $tree.SelectedNode = $nodeMap['scene.goal']
        }
    } finally {
        $script:hierarchyBindingActive = $false
    }
    if ($null -ne $nodeMap['scene.goal']) { Show-InspectorProperties $nodeMap['scene.goal'].Tag }
}

function Bind-AssetCatalogSnapshot([object]$Snapshot) {
    if ($null -eq $script:controls.AssetTree) { return }
    if ([int]$Snapshot.CatalogVersion -ne 1) { throw "Unsupported Asset Catalog version: $($Snapshot.CatalogVersion)" }
    $tree = $script:controls.AssetTree
    $firstAssetNode = $null
    $script:assetBindingActive = $true
    try {
        $tree.Nodes.Clear()
        $script:controls.Inspector.Items.Clear()
        foreach ($category in @('Audio', 'Texture', 'Scene', 'Script', 'Other')) {
            $categoryItems = @($Snapshot.Items | Where-Object { $_.Category -eq $category })
            if ($categoryItems.Count -eq 0) { continue }
            $categoryNode = New-Object Windows.Forms.TreeNode("$category ($($categoryItems.Count))")
            $categoryNode.Tag = [pscustomobject]@{ Properties = [ordered]@{ Category = $category; ItemCount = $categoryItems.Count } }
            foreach ($asset in $categoryItems) {
                $assetNode = New-Object Windows.Forms.TreeNode([string]$asset.DisplayName)
                $assetNode.Tag = $asset
                [void]$categoryNode.Nodes.Add($assetNode)
                if ($null -eq $firstAssetNode) { $firstAssetNode = $assetNode }
            }
            [void]$tree.Nodes.Add($categoryNode)
        }
        $tree.ExpandAll()
        # 与 Hierarchy 相同，绑定阶段屏蔽选择回调，避免 PowerShell/WinForms 消息重入。
        if ($null -ne $firstAssetNode) { $tree.SelectedNode = $firstAssetNode }
    } finally {
        $script:assetBindingActive = $false
    }
    if ($null -ne $firstAssetNode) { Show-InspectorProperties $firstAssetNode.Tag }
}

function Load-AssetCatalogIntoForm {
    $script:assetCatalogSnapshot = Get-EditorAssetCatalogSnapshot $script:resolvedPackageRoot
    Bind-AssetCatalogSnapshot $script:assetCatalogSnapshot
    Write-Log "Asset Catalog v$($script:assetCatalogSnapshot.CatalogVersion) 已加载：$($script:assetCatalogSnapshot.ItemCount) 项"
}

function Load-ProjectIntoForm {
    $script:projectName = $script:controls.ProjectName.Text.Trim()
    Assert-ProjectName $script:projectName
    Invoke-AuthorAction 'Validate' | Out-Null
    $model = Read-EditorProjectModel $script:resolvedPackageRoot $script:projectName
    $editable = Get-EditorProjectEditableValues $model
    $script:assetCatalogSnapshot = Get-EditorAssetCatalogSnapshot $script:resolvedPackageRoot
    Bind-AssetCatalogSnapshot $script:assetCatalogSnapshot
    $script:hierarchySnapshot = Get-EditorHierarchySnapshot $model
    Bind-HierarchySnapshot $script:hierarchySnapshot
    Set-NumberText 'SceneGoalX' $editable.SceneGoalX
    Set-NumberText 'SceneGoalY' $editable.SceneGoalY
    Set-NumberText 'ScriptGoalX' $editable.ScriptGoalX
    Set-NumberText 'ScriptGoalY' $editable.ScriptGoalY
    Set-NumberText 'ScriptVelocityX' $editable.ScriptVelocityX
    Set-NumberText 'ScriptVelocityY' $editable.ScriptVelocityY
    Write-Log "项目模型 v$($model.ModelVersion) 已加载"
    $script:projectLoaded = $true
    Write-Log "已加载项目 $script:projectName"
    Set-Status "项目已加载：$script:projectName"
}

function Invoke-UiAction([scriptblock]$Action, [string]$SuccessMessage) {
    try {
        & $Action
        Set-Status $SuccessMessage
        Write-Log $SuccessMessage
    } catch {
        $script:lastUiError = $_.Exception.ToString()
        Set-Status $_.Exception.Message $true
        Write-Log "错误：$($_.Exception.Message)"
    }
}

function Get-PreviewEventValue([object]$Event, [string]$Name, [object]$Default = $null) {
    # JSONL 可选字段在 StrictMode 下不能直接点访问；缺失时显式返回默认值。
    $property = $Event.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Handle-PreviewLine([string]$Line, [string]$Stream = 'stdout') {
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    if ($Stream -eq 'stderr') {
        Write-Log "Runtime：$Line"
        return
    }
    try { $event = $Line | ConvertFrom-Json } catch {
        Write-Log "Launcher：$Line"
        return
    }
    $eventNameProperty = $event.PSObject.Properties['event']
    if ($null -eq $eventNameProperty) { Write-Log '协议错误：事件缺少 event 字段'; return }
    $eventName = [string]$eventNameProperty.Value
    if ($eventName -eq 'launcher_status' -and $event.PSObject.Properties['name'].Value -eq 'runtime_pid') {
        try { $script:runtimeProcess = [Diagnostics.Process]::GetProcessById([int]$event.PSObject.Properties['value'].Value) } catch { $script:runtimeProcess = $null }
    }
    switch ($eventName) {
        'live_bake_started' { Write-Log "Live Bake 开始：target=$($event.target) profile=$($event.profile)" }
        'live_bake_completed' { Set-Status "Live Bake 完成：$($event.target)"; Write-Log "Live Bake 完成：target=$($event.target) entries=$(@($event.entries).Count)" }
        'live_bake_reused' { Write-Log "Live Bake 复用最近成功 artifact：$($event.target)" }
        'live_bake_failed' { Set-Status "Live Bake 失败，保留旧 artifact" $true; Write-Log "Live Bake 失败：$($event.errorCode) $($event.message)" }
        'runtime_ready' { Set-Status 'Runtime 已就绪'; Write-Log 'Runtime ready' }
        'runtime_initial_loaded' {
            if ($script:runWorkflowSmoke) { $script:workflowInitialLoaded++ }
            $sceneArtifact = Get-PreviewEventValue $event.scene 'artifactRevision' 'built-in/source'
            $scriptArtifact = Get-PreviewEventValue $event.script 'artifactRevision' 'built-in/source'
            Set-Status 'Runtime 初始内容身份已确认'
            Write-Log "Runtime initial loaded：scene=$sceneArtifact script=$scriptArtifact"
        }
        'runtime_initial_load_failed' {
            $errorCode = Get-PreviewEventValue $event 'errorCode' 'runtime_initial_load_failed'
            Set-Status "Runtime 初始身份失败：$errorCode" $true
            Write-Log "Runtime initial load failed：$errorCode"
        }
        'command_requested' { Write-Log "请求：$($event.command) #$($event.requestId)" }
        'command_completed' {
            $result = [string]$event.result
            if ($script:runWorkflowSmoke -and $result -eq 'succeeded') { $script:workflowCompletedCommands++ }
            $suffix = if ($event.PSObject.Properties['errorCode']) { " ($($event.errorCode))" } else { '' }
            Write-Log "完成：$($event.command) #$($event.requestId) = $result$suffix"
        }
        'command_response' { Write-Log "响应：$($event.command) #$($event.requestId) = $($event.result)" }
        'runtime_reload_requested' {
            $sourceRevision = Get-PreviewEventValue $event 'sourceRevision' '—'
            Write-Log "Runtime reload pending：$($event.target) source=$sourceRevision"
        }
        'runtime_reload_acknowledged' {
            if ($script:runWorkflowSmoke) { $script:workflowReloadAcknowledged++ }
            $sourceRevision = Get-PreviewEventValue $event 'sourceRevision' '—'
            $artifactRevision = Get-PreviewEventValue $event 'artifactRevision' '—'
            $artifactBytes = Get-PreviewEventValue $event 'artifactBytes' '—'
            Set-Status "Runtime 已加载：$($event.target)"
            Write-Log "Runtime reload 已确认：target=$($event.target) source=$sourceRevision artifact=$artifactRevision bytes=$artifactBytes"
        }
        'runtime_reload_failed' {
            $errorCode = Get-PreviewEventValue $event 'errorCode' 'runtime_reload_failed'
            $retainedRevision = Get-PreviewEventValue $event 'acknowledgedSourceRevision' '—'
            Set-Status "Runtime reload 失败，保留旧内容：$errorCode" $true
            Write-Log "Runtime reload 失败：target=$($event.target) error=$errorCode retained=$retainedRevision"
        }
        'runtime_reload_stale' { Write-Log "Runtime reload 迟到响应已忽略：target=$($event.target) request=$($event.requestId)" }
        'runtime_stopping' { Write-Log "Runtime stopping：$($event.reason)" }
        'runtime_failed' {
            $phase = [string]$event.PSObject.Properties['phase'].Value
            $errorCode = [string]$event.PSObject.Properties['errorCode'].Value
            Set-Status "Runtime 失败：$phase / $errorCode" $true
            Write-Log "Runtime failed：$phase / $errorCode"
        }
        'runtime_log' { Write-Log "Runtime：$($event.message)" }
        'launcher_status' { Write-Log "Launcher：$($event.name)=$($event.value)" }
        'launcher_log' { Write-Log "Launcher：$($event.message)" }
        'protocol_error' { Set-Status "协议错误：$($event.message)" $true; Write-Log "Protocol error：$($event.message)" }
        default { Write-Log "事件：$eventName" }
    }
}
function Drain-PreviewStreams {
    if ($null -eq $script:previewProcess) { return }
    foreach ($stream in @('stdout', 'stderr')) {
        $task = if ($stream -eq 'stdout') { $script:previewStdoutTask } else { $script:previewStderrTask }
        while ($null -ne $task -and $task.IsCompleted) {
            $line = $task.GetAwaiter().GetResult()
            if ($null -eq $line) {
                if ($stream -eq 'stdout') { $script:previewStdoutTask = $null } else { $script:previewStderrTask = $null }
                break
            }
            Handle-PreviewLine $line $stream
            $task = if ($stream -eq 'stdout') { $script:previewProcess.StandardOutput.ReadLineAsync() } else { $script:previewProcess.StandardError.ReadLineAsync() }
            if ($stream -eq 'stdout') { $script:previewStdoutTask = $task } else { $script:previewStderrTask = $task }
        }
    }
    if ($script:previewProcess.HasExited -and $null -eq $script:previewExitedAt) {
        $script:previewProcess.WaitForExit()
        $script:previewExitedAt = [DateTime]::UtcNow
    }
    if ($script:previewProcess.HasExited -and $null -ne $script:previewExitedAt -and ([DateTime]::UtcNow - $script:previewExitedAt).TotalSeconds -ge 2) {
        # 退出后给异步 reader 两秒排空；超时则以进程终态为准，避免 UI 永久停在“正在停止”。
        $script:previewStdoutTask = $null
        $script:previewStderrTask = $null
    }
    if ($script:previewProcess.HasExited -and $null -eq $script:previewStdoutTask -and $null -eq $script:previewStderrTask) {
        $exitCode = $script:previewProcess.ExitCode
        Set-Status (if ($exitCode -eq 0) { 'Preview 已停止' } else { "Preview 失败，退出码 $exitCode" }) ($exitCode -ne 0)
        Write-Log "Preview exit code=$exitCode"
        $script:previewProcess.Dispose()
        $script:previewProcess = $null
        $script:runtimeProcess = $null
        $script:stopDeadline = $null
        $script:previewExitedAt = $null
    } elseif ($null -ne $script:stopDeadline -and [DateTime]::UtcNow -gt $script:stopDeadline) {
        # 关键恢复语义：正常路径先发 WM_CLOSE；超时才强制终止，避免 GUI 关闭时遗留 Runtime。
        if ($null -ne $script:runtimeProcess -and -not $script:runtimeProcess.HasExited) { $script:runtimeProcess.Kill($true) }
        if (-not $script:previewProcess.HasExited) { $script:previewProcess.Kill($true) }
        $script:stopDeadline = $null
    }
}

function Start-Preview {
    if ($null -ne $script:previewProcess -and -not $script:previewProcess.HasExited) { Set-Status 'Preview 已在运行'; return }
    if (-not $script:projectLoaded) { Load-ProjectIntoForm }
    $files = Get-ProjectFiles $script:projectName
    Invoke-AuthorAction 'Validate' | ForEach-Object { Write-Log $_ }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'pwsh'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $debounceMilliseconds = Read-DebounceMilliseconds
    $arguments = @('-NoProfile', '-File', $script:previewScript, '-ConfigPath', $files.Preview, '-PackageRoot', $script:resolvedPackageRoot, '-StructuredStatus', '-PollIntervalMilliseconds', '100', '-DebounceMilliseconds', [string]$debounceMilliseconds)
    if ($script:controls.Watch.Checked) { $arguments += '-WatchChanges' }
    if ($script:controls.LiveBake.Checked) { $arguments += @('-LiveBake', '-BakeProfile', 'debug') }
    foreach ($argument in $arguments) { [void]$info.ArgumentList.Add([string]$argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'Failed to start Preview Launcher' }
    $script:previewProcess = $process
    $script:previewStdoutTask = $process.StandardOutput.ReadLineAsync()
    $script:previewStderrTask = $process.StandardError.ReadLineAsync()
    $script:previewExitedAt = $null
    $script:stopDeadline = $null
    Set-Status 'Preview 正在启动'
    Write-Log (if ($script:controls.LiveBake.Checked) { 'Preview 已启动（结构化状态 + Live Bake/watch）' } else { 'Preview 已启动（结构化状态 + 自动监听）' })
}

function Stop-Preview {
    if ($null -eq $script:previewProcess -or $script:previewProcess.HasExited) { return }
    if ($null -ne $script:runtimeProcess -and -not $script:runtimeProcess.HasExited) {
        $window = [KadathEditorGuiNative]::FindRuntimeWindow($script:runtimeProcess.Id)
        if ($window -ne [IntPtr]::Zero) {
            # 只通过既有 WM_CLOSE 生命周期命令关闭 Runtime，不向 GUI 引入第二套停止协议。
            [void][KadathEditorGuiNative]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        }
    }
    $script:stopDeadline = [DateTime]::UtcNow.AddSeconds(5)
    Set-Status '正在停止 Preview'
}

function Close-PreviewSynchronously {
    if ($null -eq $script:previewProcess) { return }
    # 关闭窗口时先排空状态流，给 GUI 一个机会拿到 runtime_pid，再执行正常 WM_CLOSE。
    $discoverDeadline = [DateTime]::UtcNow.AddSeconds(2)
    while ($null -eq $script:runtimeProcess -and -not $script:previewProcess.HasExited -and [DateTime]::UtcNow -lt $discoverDeadline) {
        Drain-PreviewStreams
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
    }
    Stop-Preview
    $waitDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($null -ne $script:previewProcess -and -not $script:previewProcess.HasExited -and [DateTime]::UtcNow -lt $waitDeadline) {
        Drain-PreviewStreams
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
    }
    if ($null -ne $script:runtimeProcess -and -not $script:runtimeProcess.HasExited) { $script:runtimeProcess.Kill($true) }
    if ($null -ne $script:previewProcess -and -not $script:previewProcess.HasExited) { $script:previewProcess.Kill($true); $script:previewProcess.WaitForExit() }
}

function Invoke-GuiWorkflowSmokeTick(
    [object]$Form,
    [object]$SmokeTimer,
    [object]$ProjectText,
    [object]$CreateButton,
    [object]$ApplyButton,
    [object]$PreviewButton,
    [object]$StopButton
) {
    if (-not $Form.Visible -or $script:workflowTickActive) { return }
    # 关键测试边界：按钮事件由 PowerShell/WinForms 消息泵异步调度；每个阶段先提交点击，再在后续 Tick 验证结果。
    $script:workflowTickActive = $true
    try {
        switch ($script:workflowStage) {
            0 {
                $ProjectText.Text = $script:projectName
                $files = Get-ProjectFiles $script:projectName
                $script:workflowProjectDirectory = $files.Directory
                $script:workflowStage = 1
                $script:workflowStartedAt = [DateTime]::UtcNow
                $CreateButton.PerformClick()
            }
            1 {
                $script:workflowProjectCreated = Test-Path -LiteralPath $script:workflowProjectDirectory
                if (-not $script:projectLoaded) {
                    if (([DateTime]::UtcNow - $script:workflowStartedAt).TotalSeconds -gt 10) {
                        $diagnostic = $script:controls.Log.Text.Replace("`r", ' ').Replace("`n", ' | ')
                        throw "GUI Create button did not load the new project: status=$($script:controls.Status.Text) lastUiError=$($script:lastUiError) log=$diagnostic"
                    }
                    return
                }
                if ($null -eq $script:hierarchySnapshot -or [int]$script:hierarchySnapshot.SnapshotVersion -ne 1) { throw 'Hierarchy Snapshot v1 was not bound after Create' }
                if ($null -eq $script:assetCatalogSnapshot -or [int]$script:assetCatalogSnapshot.CatalogVersion -ne 1) { throw 'Asset Catalog v1 was not bound after Create' }
                $script:controls.SceneGoalX.Text = '610'
                $script:controls.SceneGoalY.Text = '210'
                $script:controls.ScriptGoalX.Text = '610'
                $script:controls.ScriptGoalY.Text = '210'
                $script:controls.ScriptVelocityX.Text = '15'
                $script:controls.ScriptVelocityY.Text = '0'
                $script:workflowStage = 2
                $script:workflowStartedAt = [DateTime]::UtcNow
                $ApplyButton.PerformClick()
            }
            2 {
                $model = Read-EditorProjectModel $script:resolvedPackageRoot $script:projectName
                $applyCompleted = [double]$model.Scene.GoalPosition[0] -eq 610.0 -and [double]$model.Script.GoalVelocity[0] -eq 15.0
                if (-not $applyCompleted) {
                    if (([DateTime]::UtcNow - $script:workflowStartedAt).TotalSeconds -gt 10) { throw "GUI Apply button did not persist Project Model values: lastUiError=$script:lastUiError" }
                    return
                }
                if (-not $script:projectLoaded) { throw 'GUI Apply button did not keep the project loaded' }
                if ($null -eq $script:hierarchySnapshot -or [int]$script:hierarchySnapshot.SnapshotVersion -ne 1) { throw 'Hierarchy Snapshot v1 was not rebound after Apply' }
                if (@($script:hierarchySnapshot.Nodes).Count -ne 8 -or $script:controls.Hierarchy.Nodes.Count -ne 3) { throw 'Hierarchy tree does not contain the expected 8 nodes / 3 roots' }
                if ($script:controls.Inspector.Items.Count -eq 0) { throw 'Inspector did not show the selected node properties' }
                if (@($script:assetCatalogSnapshot.Items).Count -ne 10 -or $script:controls.AssetTree.Nodes.Count -ne 4) { throw 'Asset panel does not contain the expected 10 items / 4 categories' }
                if ($null -eq $script:controls.AssetTree.SelectedNode) { throw 'Asset panel did not select a catalog item' }
                Show-InspectorProperties $script:controls.AssetTree.SelectedNode.Tag
                if ($script:controls.Inspector.Items.Count -lt 5) { throw 'Inspector did not show the selected asset properties' }
                Show-InspectorProperties $script:controls.Hierarchy.SelectedNode.Tag
                $script:workflowStage = 3
                $script:workflowStartedAt = [DateTime]::UtcNow
                $script:controls.LiveBake.Checked = $true
                $PreviewButton.PerformClick()
            }
            3 {
                if ($null -eq $script:previewProcess -or $null -eq $script:runtimeProcess) {
                    if (([DateTime]::UtcNow - $script:workflowStartedAt).TotalSeconds -gt 10) { throw 'Runtime did not become ready during GUI workflow smoke' }
                    return
                }
                if (([DateTime]::UtcNow - $script:workflowStartedAt).TotalMilliseconds -lt 1000) { return }
                # 关键验收动作：Preview 运行中再次通过 authoring adapter 写入，要求 watcher 产生 Scene/Script 两个成功终态。
                Invoke-AuthorAction 'Update' @{ SceneGoalX = 620.0; SceneGoalY = 220.0; ScriptGoalX = 620.0; ScriptGoalY = 220.0; ScriptVelocityX = 20.0; ScriptVelocityY = 0.0 } | Out-Null
                Load-ProjectIntoForm
                $script:workflowStage = 4
                $script:workflowStartedAt = [DateTime]::UtcNow
            }
            4 {
                if ($script:workflowInitialLoaded -lt 1 -or $script:workflowCompletedCommands -lt 2 -or $script:workflowReloadAcknowledged -lt 2) {
                    if (([DateTime]::UtcNow - $script:workflowStartedAt).TotalSeconds -gt 10) { throw "Expected initial identity and Scene/Script reload completions/ack, got $script:workflowInitialLoaded/$script:workflowCompletedCommands/$script:workflowReloadAcknowledged" }
                    return
                }
                $script:workflowStage = 5
                $script:workflowStartedAt = [DateTime]::UtcNow
                $StopButton.PerformClick()
            }
            5 {
                if ($null -ne $script:previewProcess) {
                    if ($script:previewProcess.HasExited) {
                        $script:previewProcess.WaitForExit()
                        $script:previewProcess.Dispose()
                        $script:previewProcess = $null
                        $script:previewStdoutTask = $null
                        $script:previewStderrTask = $null
                        $script:previewExitedAt = $null
                        $script:runtimeProcess = $null
                    } else {
                        if (([DateTime]::UtcNow - $script:workflowStartedAt).TotalSeconds -gt 10) {
                            $launcherExited = $script:previewProcess.HasExited
                            $runtimeExited = if ($null -eq $script:runtimeProcess) { $true } else { $script:runtimeProcess.HasExited }
                            throw "Preview did not stop during GUI workflow smoke: launcherExited=$launcherExited runtimeExited=$runtimeExited"
                        }
                        return
                    }
                }
                Invoke-AuthorAction 'Validate' | Out-Null
                $model = Read-EditorProjectModel $script:resolvedPackageRoot $script:projectName
                if ([int]$model.ModelVersion -ne 1) { throw "Unexpected Project Model version: $($model.ModelVersion)" }
                $snapshot = Get-EditorHierarchySnapshot $model
                if ([int]$snapshot.SnapshotVersion -ne 1 -or @($snapshot.Nodes).Count -ne 8) { throw 'Final Hierarchy Snapshot is invalid' }
                $catalog = Get-EditorAssetCatalogSnapshot $script:resolvedPackageRoot
                if ([int]$catalog.CatalogVersion -ne 1 -or @($catalog.Items).Count -ne 10) { throw 'Final Asset Catalog Snapshot is invalid' }
                $script:workflowEvidence = @(
                    'workflow_create=ok',
                    'workflow_apply=ok',
                    'workflow_preview=ok',
                    "workflow_initial_loaded=$script:workflowInitialLoaded",
                    "workflow_reload_completions=$script:workflowCompletedCommands",
                    "workflow_reload_acknowledged=$script:workflowReloadAcknowledged",
                    "project_model_version=$($model.ModelVersion)",
                    "hierarchy_snapshot_version=$($snapshot.SnapshotVersion)",
                    "hierarchy_node_count=$(@($snapshot.Nodes).Count)",
                    'hierarchy_inspector=ok',
                    "asset_catalog_version=$($catalog.CatalogVersion)",
                    "asset_item_count=$(@($catalog.Items).Count)",
                    'asset_panel=ok',
                    'workflow_stop=ok',
                    'workflow_validation=ok'
                )
                $script:workflowStage = 6
                $SmokeTimer.Stop()
                $Form.Close()
            }
        }
    } catch {
        $script:workflowSmokeError = $_.Exception.Message
        $SmokeTimer.Stop()
        Close-PreviewSynchronously
        $Form.Close()
    } finally {
        $script:workflowTickActive = $false
    }
}

function Show-Editor {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class KadathEditorGuiNative {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);
    public static IntPtr FindRuntimeWindow(int processId) {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr _) {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != (uint)processId) return true;
            StringBuilder className = new StringBuilder(256);
            if (GetClassName(window, className, className.Capacity) > 0 && className.ToString() == "KadathRuntimeWindow") {
                result = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
"@

    $form = New-Object Windows.Forms.Form
    $form.Text = 'Kadath Authoring'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object Drawing.Size(960, 780)
    $form.MinimumSize = New-Object Drawing.Size(820, 680)

    $rootLabel = New-Object Windows.Forms.Label; $rootLabel.Text = 'Package Root'; $rootLabel.Location = New-Object Drawing.Point(16, 18); $rootLabel.AutoSize = $true
    $rootText = New-Object Windows.Forms.TextBox; $rootText.Location = New-Object Drawing.Point(120, 14); $rootText.Size = New-Object Drawing.Size(680, 24); $rootText.Text = $script:resolvedPackageRoot; $rootText.ReadOnly = $true; $rootText.Anchor = 'Top,Left,Right'
    $browse = New-Object Windows.Forms.Button; $browse.Text = '浏览…'; $browse.Location = New-Object Drawing.Point(812, 12); $browse.Size = New-Object Drawing.Size(120, 28); $browse.Anchor = 'Top,Right'
    $projectLabel = New-Object Windows.Forms.Label; $projectLabel.Text = 'Project'; $projectLabel.Location = New-Object Drawing.Point(16, 56); $projectLabel.AutoSize = $true
    $projectText = New-Object Windows.Forms.TextBox; $projectText.Location = New-Object Drawing.Point(120, 52); $projectText.Size = New-Object Drawing.Size(260, 24); $projectText.Text = $script:projectName
    $load = New-Object Windows.Forms.Button; $load.Text = '加载'; $load.Location = New-Object Drawing.Point(392, 50); $load.Size = New-Object Drawing.Size(90, 28)
    $create = New-Object Windows.Forms.Button; $create.Text = '创建项目'; $create.Location = New-Object Drawing.Point(492, 50); $create.Size = New-Object Drawing.Size(100, 28)
    $open = New-Object Windows.Forms.Button; $open.Text = '打开目录'; $open.Location = New-Object Drawing.Point(602, 50); $open.Size = New-Object Drawing.Size(100, 28)
    $status = New-Object Windows.Forms.Label; $status.Text = '请选择项目并加载'; $status.Location = New-Object Drawing.Point(716, 56); $status.AutoSize = $true; $status.Anchor = 'Top,Right'

    $group = New-Object Windows.Forms.GroupBox; $group.Text = 'Scene / Script Hook v1（受控字段）'; $group.Location = New-Object Drawing.Point(16, 92); $group.Size = New-Object Drawing.Size(916, 168); $group.Anchor = 'Top,Left,Right'
    $fields = @(
        @('SceneGoalX', 'Scene Goal X', 24, 30), @('SceneGoalY', 'Scene Goal Y', 318, 30),
        @('ScriptGoalX', 'Script Goal X', 612, 30), @('ScriptGoalY', 'Script Goal Y', 24, 82),
        @('ScriptVelocityX', 'Velocity X', 318, 82), @('ScriptVelocityY', 'Velocity Y', 612, 82)
    )
    foreach ($field in $fields) {
        $label = New-Object Windows.Forms.Label; $label.Text = $field[1]; $label.Location = New-Object Drawing.Point([int]$field[2], [int]$field[3]); $label.AutoSize = $true
        $input = New-Object Windows.Forms.TextBox; $input.Location = New-Object Drawing.Point(([int]$field[2] + 120), ([int]$field[3] - 4)); $input.Size = New-Object Drawing.Size(130, 24); $input.Anchor = 'Top,Left'
        $group.Controls.Add($label); $group.Controls.Add($input); $script:controls[$field[0]] = $input
    }
    $hint = New-Object Windows.Forms.Label; $hint.Text = '未知 JSON 字段由 authoring adapter 保留；GUI 只暴露当前稳定的最小编辑集合。'; $hint.Location = New-Object Drawing.Point(24, 132); $hint.AutoSize = $true; $hint.ForeColor = [Drawing.Color]::DimGray; $group.Controls.Add($hint)

    $apply = New-Object Windows.Forms.Button; $apply.Text = '应用修改'; $apply.Location = New-Object Drawing.Point(16, 278); $apply.Size = New-Object Drawing.Size(100, 32)
    $validate = New-Object Windows.Forms.Button; $validate.Text = '校验'; $validate.Location = New-Object Drawing.Point(126, 278); $validate.Size = New-Object Drawing.Size(90, 32)
    $preview = New-Object Windows.Forms.Button; $preview.Text = '启动预览'; $preview.Location = New-Object Drawing.Point(226, 278); $preview.Size = New-Object Drawing.Size(100, 32)
    $stop = New-Object Windows.Forms.Button; $stop.Text = '停止预览'; $stop.Location = New-Object Drawing.Point(336, 278); $stop.Size = New-Object Drawing.Size(100, 32)
    $watch = New-Object Windows.Forms.CheckBox; $watch.Text = '自动监听（当前默认开启）'; $watch.Checked = $true; $watch.Enabled = $true; $watch.Location = New-Object Drawing.Point(452, 284); $watch.AutoSize = $true
    $liveBake = New-Object Windows.Forms.CheckBox; $liveBake.Text = 'Live Bake'; $liveBake.Checked = $false; $liveBake.Enabled = $true; $liveBake.Location = New-Object Drawing.Point(452, 306); $liveBake.AutoSize = $true
    $debounceLabel = New-Object Windows.Forms.Label; $debounceLabel.Text = 'Debounce ms'; $debounceLabel.Location = New-Object Drawing.Point(674, 284); $debounceLabel.AutoSize = $true
    $debounce = New-Object Windows.Forms.TextBox; $debounce.Text = '250'; $debounce.Location = New-Object Drawing.Point(760, 280); $debounce.Size = New-Object Drawing.Size(80, 24)
    $workspaceSplit = New-Object Windows.Forms.SplitContainer
    $workspaceSplit.Location = New-Object Drawing.Point(16, 326)
    $workspaceSplit.Size = New-Object Drawing.Size(916, 430)
    $workspaceSplit.Anchor = 'Top,Bottom,Left,Right'
    $workspaceSplit.Orientation = [Windows.Forms.Orientation]::Horizontal
    $workspaceSplit.SplitterDistance = 240
    $workspaceSplit.Panel1MinSize = 160
    $workspaceSplit.Panel2MinSize = 100

    $inspectorSplit = New-Object Windows.Forms.SplitContainer
    $inspectorSplit.Dock = 'Fill'
    $inspectorSplit.Orientation = [Windows.Forms.Orientation]::Vertical
    $inspectorSplit.SplitterDistance = 340

    $navigationTabs = New-Object Windows.Forms.TabControl
    $navigationTabs.Dock = 'Fill'
    $hierarchyPage = New-Object Windows.Forms.TabPage('Hierarchy')
    $assetsPage = New-Object Windows.Forms.TabPage('Assets')
    $hierarchy = New-Object Windows.Forms.TreeView
    $hierarchy.Dock = 'Fill'
    $hierarchy.HideSelection = $false
    $assetTree = New-Object Windows.Forms.TreeView
    $assetTree.Dock = 'Fill'
    $assetTree.HideSelection = $false
    $hierarchyPage.Controls.Add($hierarchy)
    $assetsPage.Controls.Add($assetTree)
    [void]$navigationTabs.TabPages.Add($hierarchyPage)
    [void]$navigationTabs.TabPages.Add($assetsPage)

    $inspector = New-Object Windows.Forms.ListView
    $inspector.Dock = 'Fill'
    $inspector.View = [Windows.Forms.View]::Details
    $inspector.FullRowSelect = $true
    $inspector.GridLines = $true
    [void]$inspector.Columns.Add('Property', 180)
    [void]$inspector.Columns.Add('Value', 350)
    $inspectorSplit.Panel1.Controls.Add($navigationTabs)
    $inspectorSplit.Panel2.Controls.Add($inspector)

    $log = New-Object Windows.Forms.RichTextBox
    $log.ReadOnly = $true
    $log.Font = New-Object Drawing.Font('Consolas', 9)
    $log.Dock = 'Fill'
    $workspaceSplit.Panel1.Controls.Add($inspectorSplit)
    $workspaceSplit.Panel2.Controls.Add($log)

    $script:controls.ProjectName = $projectText; $script:controls.Status = $status; $script:controls.Log = $log; $script:controls.Debounce = $debounce; $script:controls.Watch = $watch; $script:controls.LiveBake = $liveBake; $script:controls.Hierarchy = $hierarchy; $script:controls.AssetTree = $assetTree; $script:controls.NavigationTabs = $navigationTabs; $script:controls.Inspector = $inspector
    $hierarchy.Add_AfterSelect({ param($sender, $args) if (-not $script:hierarchyBindingActive) { Show-InspectorProperties $args.Node.Tag } })
    $assetTree.Add_AfterSelect({ param($sender, $args) if (-not $script:assetBindingActive) { Show-InspectorProperties $args.Node.Tag } })
    $navigationTabs.Add_SelectedIndexChanged({ $selected = if ($navigationTabs.SelectedIndex -eq 0) { $hierarchy.SelectedNode } else { $assetTree.SelectedNode }; if ($null -ne $selected) { Show-InspectorProperties $selected.Tag } })
    $form.Controls.AddRange(@($rootLabel, $rootText, $browse, $projectLabel, $projectText, $load, $create, $open, $status, $group, $apply, $validate, $preview, $stop, $watch, $liveBake, $debounceLabel, $debounce, $workspaceSplit))

    $timer = New-Object Windows.Forms.Timer; $timer.Interval = 50
    $timer.Add_Tick({ Drain-PreviewStreams })
    $browse.Add_Click({
        $dialog = New-Object Windows.Forms.FolderBrowserDialog; $dialog.SelectedPath = $rootText.Text
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            $rootText.Text = $dialog.SelectedPath
            try {
                $script:resolvedPackageRoot = Resolve-PackageRoot $rootText.Text
                $script:projectLoaded = $false
                $script:hierarchySnapshot = $null
                $hierarchy.Nodes.Clear()
                Load-AssetCatalogIntoForm
                Set-Status 'Package Root 与 Asset Catalog 已更新'
            } catch { Set-Status $_.Exception.Message $true }
        }
    })
    $projectText.Add_TextChanged({ if ($projectText.Text.Trim() -ne $script:projectName) { $script:projectLoaded = $false; $script:hierarchySnapshot = $null
$script:lastUiError = $null; $hierarchy.Nodes.Clear(); $inspector.Items.Clear() } })
    $load.Add_Click({ Invoke-UiAction { Load-ProjectIntoForm } "项目已加载：$script:projectName" })
    $create.Add_Click({
        Invoke-UiAction {
            $script:projectName = $projectText.Text.Trim()
            Assert-ProjectName $script:projectName
            Invoke-AuthorAction 'Create' | ForEach-Object { Write-Log $_ }
            Load-ProjectIntoForm
        } "项目已创建：$script:projectName"
    })
    $open.Add_Click({ try { $files = Get-ProjectFiles $projectText.Text.Trim(); if (-not (Test-Path -LiteralPath $files.Directory)) { throw '项目目录不存在' }; Start-Process explorer.exe -ArgumentList $files.Directory } catch { Set-Status $_.Exception.Message $true; Write-Log "错误：$($_.Exception.Message)" } })
    $apply.Add_Click({ Invoke-UiAction { if (-not $script:projectLoaded) { throw '请先加载当前项目，再应用修改' }; Invoke-AuthorAction 'Update' (Read-EditableValues) | ForEach-Object { Write-Log $_ }; Load-ProjectIntoForm } '修改已应用并通过校验' })
    $validate.Add_Click({ Invoke-UiAction { if (-not $script:projectLoaded) { Load-ProjectIntoForm }; Invoke-AuthorAction 'Validate' | ForEach-Object { Write-Log $_ } } '项目校验通过' })
    $preview.Add_Click({ Invoke-UiAction { Start-Preview; $timer.Start() } 'Preview 已启动' })
    $stop.Add_Click({ Stop-Preview })
    $form.Add_FormClosing({ $timer.Stop(); Close-PreviewSynchronously })
    $form.Add_Shown({ try { if (Test-Path -LiteralPath (Get-ProjectFiles $script:projectName).Directory) { Load-ProjectIntoForm } else { Load-AssetCatalogIntoForm } } catch { Write-Log "提示：$($_.Exception.Message)" } })
    $timer.Start()
    if ($script:runWorkflowSmoke) {
        $smokeTimer = New-Object Windows.Forms.Timer
        $smokeTimer.Interval = 100
        $smokeTimer.Add_Tick({ Invoke-GuiWorkflowSmokeTick $form $smokeTimer $projectText $create $apply $preview $stop })
        $smokeTimer.Start()
    }
    [Windows.Forms.Application]::Run($form)
    if ($script:runWorkflowSmoke) {
        if ($script:workflowProjectCreated -and $null -ne $script:workflowProjectDirectory -and (Test-Path -LiteralPath $script:workflowProjectDirectory)) {
            # smoke 只使用隔离 package 项目目录，结束后始终清理，避免污染开发包。
            Remove-Item -LiteralPath $script:workflowProjectDirectory -Recurse -Force
        }
        if ($null -ne $script:workflowSmokeError) { throw $script:workflowSmokeError }
        foreach ($evidence in $script:workflowEvidence) { Write-Output $evidence }
        Write-Output 'gui_workflow_smoke=ok'
    }
}

$script:resolvedPackageRoot = Resolve-PackageRoot $PackageRoot
Assert-ProjectName $script:projectName
if ($Headless -and $WorkflowSmoke) { throw 'Headless and WorkflowSmoke cannot be enabled together' }
if ($WorkflowSmoke) {
    $workflowFiles = Get-ProjectFiles $script:projectName
    if (Test-Path -LiteralPath $workflowFiles.Directory) { throw "WorkflowSmoke project already exists; refusing to overwrite: $script:projectName" }
}
if ($Headless) {
    # Headless contract 只验证 GUI 依赖的路径/命令入口；内容事务仍由 editor-author verifier 覆盖。
    Add-Type -AssemblyName System.Windows.Forms
    # 覆盖非 Live JSON watcher 与首次失败：artifact/retained 字段均允许缺失，StrictMode 下也不能中断事件流。
    Handle-PreviewLine '{"event":"runtime_initial_loaded","loadVersion":1,"state":"loaded","scene":{"target":"Scene","kind":"built_in","correlation":"runtime_only"},"script":{"target":"Script","kind":"built_in","correlation":"runtime_only"}}'
    Handle-PreviewLine '{"event":"runtime_reload_acknowledged","target":"Scene","requestId":1,"source":"file_change","sourceRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","result":"succeeded"}'
    Handle-PreviewLine '{"event":"runtime_reload_failed","target":"Script","requestId":2,"source":"file_change","sourceRevision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","result":"rejected","errorCode":"UnsupportedScriptSchema"}'
    Write-Output 'gui_contract=ok'
    Write-Output 'gui_optional_reload_fields=ok'
    Write-Output "package_root=$script:resolvedPackageRoot"
    Write-Output "project_name=$script:projectName"
    exit 0
}

Show-Editor
