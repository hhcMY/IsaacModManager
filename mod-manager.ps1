# ============================================================
#  以撒 Mod 管理器  v1.1
#  不进游戏，直接在外面开关 mod、改 mod 在游戏里显示的名字
#  由「Mod管理器.vbs」启动（不弹黑框）
#  只用 Windows 自带的 PowerShell + .NET WinForms，不需要安装任何东西
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) { $root = Split-Path -Parent $MyInvocation.MyCommand.Definition }

. (Join-Path $root "common.ps1")

$script:CFG     = Resolve-UiConfig
$script:Mods    = New-Object System.Collections.ArrayList
$script:Loading = $false
$script:Filter  = ""

# ------------------------------------------------------------
#  读 / 改 mod 文件夹
# ------------------------------------------------------------

# 读文本文件并记住它原本的编码（UTF-8 带不带 BOM、UTF-16、GBK）
# 改完按原编码写回去，避免把别人的中文 metadata.xml 弄成乱码
function Read-TextFileEx([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $n = $bytes.Length
    $enc = $null
    $off = 0
    if ($n -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $enc = New-Object System.Text.UTF8Encoding($true); $off = 3
    } elseif ($n -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = New-Object System.Text.UnicodeEncoding($false, $true); $off = 2
    } elseif ($n -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $enc = New-Object System.Text.UnicodeEncoding($true, $true); $off = 2
    } else {
        # 没有 BOM：能严格解成 UTF-8 就当 UTF-8，否则按 GBK（老 mod 常见）
        try {
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            [void]$strict.GetString($bytes)
            $enc = New-Object System.Text.UTF8Encoding($false)
        } catch {
            $enc = [System.Text.Encoding]::GetEncoding(936)
        }
        $off = 0
    }
    $count = $n - $off
    if ($count -le 0) {
        $text = ""
    } else {
        $body = New-Object byte[] $count
        [System.Array]::Copy($bytes, $off, $body, 0, $count)
        $text = $enc.GetString($body)
    }
    return [pscustomobject]@{ Text = $text.TrimStart([char]0xFEFF); Encoding = $enc }
}

function Read-ModInfo([string]$dir) {
    $meta = Join-Path $dir "metadata.xml"
    $name = ""; $ver = ""
    if (Test-Path -LiteralPath $meta) {
        try {
            $f = Read-TextFileEx $meta
            $x = [xml]$f.Text
            $name = [string]$x.metadata.name
            $ver  = [string]$x.metadata.version
        } catch { }
    }
    $enabled = -not (Test-Path -LiteralPath (Join-Path $dir "disable.it"))
    if ([string]::IsNullOrWhiteSpace($name)) { $name = Split-Path $dir -Leaf }
    return [pscustomobject]@{
        Dir         = Split-Path $dir -Leaf
        Path        = $dir
        Name        = $name.Trim()
        Version     = ([string]$ver).Trim()
        Enabled     = $enabled
        OrigName    = $name.Trim()
        OrigEnabled = $enabled
    }
}

function Set-ModEnabled([string]$dir, [bool]$enabled) {
    $flag = Join-Path $dir "disable.it"
    try {
        if ($enabled) {
            if (Test-Path -LiteralPath $flag) { Remove-Item -LiteralPath $flag -Force -ErrorAction Stop }
        } else {
            if (-not (Test-Path -LiteralPath $flag)) { [System.IO.File]::WriteAllText($flag, "") }
        }
        return $true
    } catch {
        return $false
    }
}

# 成功返回 $null，失败返回一句原因
function Set-ModName([string]$dir, [string]$newName) {
    $meta = Join-Path $dir "metadata.xml"
    if (-not (Test-Path -LiteralPath $meta)) { return "没有 metadata.xml，改不了名" }
    if ([string]::IsNullOrWhiteSpace($newName)) { return "名称是空的" }
    try {
        $f   = Read-TextFileEx $meta
        $raw = $f.Text
        $safe = $newName.Trim() -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
        $ic = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        if ($raw -match '(?i)<name>[\s\S]*?</name>') {
            $raw = [regex]::Replace($raw, '<name>[\s\S]*?</name>', "<name>$safe</name>", $ic)
        } elseif ($raw -match '(?i)<metadata\s*/>') {
            $raw = [regex]::Replace($raw, '<metadata\s*/>', "<metadata><name>$safe</name></metadata>", $ic)
        } elseif ($raw -match '(?i)<metadata(\s[^>]*)?>') {
            $raw = [regex]::Replace($raw, '<metadata(\s[^>]*)?>', ('<metadata$1>' + "`r`n    <name>$safe</name>"), $ic)
        } else {
            return "metadata.xml 格式看不懂，没敢动"
        }
        [System.IO.File]::WriteAllText($meta, $raw, $f.Encoding)
        return $null
    } catch {
        return ("写入失败：" + $_.Exception.Message)
    }
}

function Load-Mods {
    $script:Mods.Clear()
    $md = Get-ModsDir $script:CFG
    if ($md -eq "" -or -not (Test-Path -LiteralPath $md)) { return $false }
    Get-ChildItem -LiteralPath $md -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { [void]$script:Mods.Add((Read-ModInfo $_.FullName)) }
    return $true
}

# ------------------------------------------------------------
#  界面
# ------------------------------------------------------------
try {

$form = New-Object System.Windows.Forms.Form
$form.Text = "以撒 Mod 管理器  v1.1"

# 屏幕小、或者系统缩放调大了，就按可用桌面缩一点，别让底下的按钮跑到屏幕外
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$fW = 820
$fH = 660
if ($wa.Width  -lt ($fW + 24)) { $fW = [Math]::Max(720, $wa.Width  - 24) }
if ($wa.Height -lt ($fH + 24)) { $fH = [Math]::Max(500, $wa.Height - 24) }
$form.Size = New-Object System.Drawing.Size($fW, $fH)
$form.MinimumSize = New-Object System.Drawing.Size(720, 500)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 239, 227)
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei", 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Mod 管理器"
$title.Font = New-Object System.Drawing.Font("Microsoft YaHei", 14, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(14, 10)
$title.Size = New-Object System.Drawing.Size(300, 30)
$form.Controls.Add($title)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "勾选 = 启用；双击（F2）改显示名称；改完点「保存」，重启游戏生效"
$hint.Location = New-Object System.Drawing.Point(18, 46)
$hint.Size = New-Object System.Drawing.Size(430, 20)
$hint.ForeColor = [System.Drawing.Color]::FromArgb(120, 100, 80)
$form.Controls.Add($hint)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = "搜索"
$lblSearch.Location = New-Object System.Drawing.Point(592, 46)
$lblSearch.Size = New-Object System.Drawing.Size(44, 20)
$lblSearch.ForeColor = [System.Drawing.Color]::FromArgb(120, 100, 80)
$lblSearch.Anchor = "Top,Right"
$form.Controls.Add($lblSearch)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(638, 42)
$txtSearch.Size = New-Object System.Drawing.Size(164, 24)
$txtSearch.Anchor = "Top,Right"
$form.Controls.Add($txtSearch)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(16, 74)
$grid.Size = New-Object System.Drawing.Size(772, 404)
$grid.Anchor = "Top,Left,Right,Bottom"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = "FullRowSelect"
$grid.AutoSizeColumnsMode = "Fill"
$grid.EditMode = "EditOnKeystrokeOrF2"
$grid.BackgroundColor = [System.Drawing.Color]::FromArgb(255, 252, 246)
$grid.GridColor = [System.Drawing.Color]::FromArgb(220, 205, 185)
$form.Controls.Add($grid)

$colOn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colOn.HeaderText = "启用"; $colOn.Name = "Enabled"; $colOn.FillWeight = 9
[void]$grid.Columns.Add($colOn)

$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.HeaderText = "显示名称（双击可改）"; $colName.Name = "Name"; $colName.FillWeight = 46
[void]$grid.Columns.Add($colName)

$colVer = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colVer.HeaderText = "版本"; $colVer.Name = "Version"; $colVer.FillWeight = 11; $colVer.ReadOnly = $true
[void]$grid.Columns.Add($colVer)

$colDir = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colDir.HeaderText = "文件夹"; $colDir.Name = "Dir"; $colDir.FillWeight = 34; $colDir.ReadOnly = $true
[void]$grid.Columns.Add($colDir)

$labPath = New-Object System.Windows.Forms.Label
$labPath.Location = New-Object System.Drawing.Point(16, 486)
$labPath.Size = New-Object System.Drawing.Size(772, 20)
$labPath.ForeColor = [System.Drawing.Color]::FromArgb(120, 100, 80)
$form.Controls.Add($labPath)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "保存"; $btnSave.Location = New-Object System.Drawing.Point(16, 514); $btnSave.Size = New-Object System.Drawing.Size(86, 32)
$form.Controls.Add($btnSave)

$btnAllOn = New-Object System.Windows.Forms.Button
$btnAllOn.Text = "全部启用"; $btnAllOn.Location = New-Object System.Drawing.Point(110, 514); $btnAllOn.Size = New-Object System.Drawing.Size(86, 32)
$form.Controls.Add($btnAllOn)

$btnAllOff = New-Object System.Windows.Forms.Button
$btnAllOff.Text = "全部禁用"; $btnAllOff.Location = New-Object System.Drawing.Point(204, 514); $btnAllOff.Size = New-Object System.Drawing.Size(86, 32)
$form.Controls.Add($btnAllOff)

$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = "刷新"; $btnReload.Location = New-Object System.Drawing.Point(298, 514); $btnReload.Size = New-Object System.Drawing.Size(86, 32)
$form.Controls.Add($btnReload)

$btnPaths = New-Object System.Windows.Forms.Button
$btnPaths.Text = "设置路径"; $btnPaths.Location = New-Object System.Drawing.Point(392, 514); $btnPaths.Size = New-Object System.Drawing.Size(96, 32)
$form.Controls.Add($btnPaths)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = "打开 mods 文件夹"; $btnOpen.Location = New-Object System.Drawing.Point(496, 514); $btnOpen.Size = New-Object System.Drawing.Size(130, 32)
$form.Controls.Add($btnOpen)

$labCount = New-Object System.Windows.Forms.Label
$labCount.Location = New-Object System.Drawing.Point(16, 556)
$labCount.Size = New-Object System.Drawing.Size(280, 22)
$labCount.ForeColor = [System.Drawing.Color]::FromArgb(90, 120, 60)
$form.Controls.Add($labCount)

$labMsg = New-Object System.Windows.Forms.Label
$labMsg.Location = New-Object System.Drawing.Point(400, 556)
$labMsg.Size = New-Object System.Drawing.Size(388, 22)
$labMsg.TextAlign = "MiddleRight"
$labMsg.ForeColor = [System.Drawing.Color]::FromArgb(90, 120, 60)
$form.Controls.Add($labMsg)

# 底部这一排贴着窗口底边走：窗口被缩小（小屏 / 高缩放）时按钮和状态文字不会被裁掉
$labPath.Anchor  = "Bottom,Left,Right"
$labCount.Anchor = "Bottom,Left,Right"
$labMsg.Anchor   = "Bottom,Right"
foreach ($b in @($btnSave, $btnAllOn, $btnAllOff, $btnReload, $btnPaths, $btnOpen)) {
    $b.Anchor = "Bottom,Left"
}

function Update-PathLabel {
    $md = Get-ModsDir $script:CFG
    if (Test-IsaacGameDir $script:CFG["gameDir"]) {
        $script:labPath.Text = "mods 目录：" + $md
        $script:labPath.ForeColor = [System.Drawing.Color]::FromArgb(120, 100, 80)
    } else {
        $script:labPath.Text = "还没找到游戏目录 —— 点「设置路径」；不知道装哪了就用「自动识别游戏目录」"
        $script:labPath.ForeColor = [System.Drawing.Color]::FromArgb(170, 60, 60)
    }
}

function Update-Status {
    $on = 0
    foreach ($m in $script:Mods) { if ($m.Enabled) { $on++ } }
    $t = "共 " + $script:Mods.Count + " 个 mod，已启用 " + $on + " 个"
    if ($script:Filter -ne "") { $t += "，匹配 " + $script:grid.Rows.Count + " 个" }
    $script:labCount.Text = $t
}

function Update-Grid {
    $script:Loading = $true
    try {
        $script:grid.Rows.Clear()
        $kw = $script:Filter
        foreach ($m in $script:Mods) {
            $hit = $false
            if ($kw -eq "") {
                $hit = $true
            } else {
                if ($m.Name.IndexOf($kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true }
                if ($m.Dir.IndexOf($kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true }
            }
            if ($hit) {
                $i = $script:grid.Rows.Add($m.Enabled, $m.Name, $m.Version, $m.Dir)
                $script:grid.Rows[$i].Tag = $m
            }
        }
    } finally {
        $script:Loading = $false
    }
    Update-Status
}

# 勾选框要立刻提交，否则刚点的勾还在编辑态里，模型读不到
$grid.Add_CurrentCellDirtyStateChanged({
    try {
        if ($grid.IsCurrentCellDirty -and ($grid.CurrentCell -is [System.Windows.Forms.DataGridViewCheckBoxCell])) {
            [void]$grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    } catch { }
})

$grid.Add_CellValueChanged({
    param($s, $e)
    if ($script:Loading) { return }
    if ($e.RowIndex -lt 0) { return }
    $row = $grid.Rows[$e.RowIndex]
    $m = $row.Tag
    if ($m -eq $null) { return }
    $v = $row.Cells["Enabled"].Value
    if ($v -eq $null) { $m.Enabled = $false } else { $m.Enabled = [bool]$v }
    $nm = [string]$row.Cells["Name"].Value
    if (-not [string]::IsNullOrWhiteSpace($nm)) { $m.Name = $nm.Trim() }
})

$txtSearch.Add_TextChanged({
    $script:Filter = $txtSearch.Text.Trim()
    Update-Grid
})

$btnSave.Add_Click({
    $grid.EndEdit()
    $done = 0
    $bad = New-Object System.Collections.ArrayList

    foreach ($m in $script:Mods) {
        if ($m.Enabled -ne $m.OrigEnabled) {
            if (Set-ModEnabled $m.Path $m.Enabled) {
                $m.OrigEnabled = $m.Enabled
                $done++
            } else {
                [void]$bad.Add($m.Dir + "：开关失败（mod 文件夹是只读的？）")
            }
        }
        if ($m.Name -ne $m.OrigName -and -not [string]::IsNullOrWhiteSpace($m.Name)) {
            $err = Set-ModName $m.Path $m.Name
            if ($err -eq $null) {
                $m.OrigName = $m.Name
                $done++
            } else {
                [void]$bad.Add($m.Dir + "：" + $err)
            }
        }
    }

    if ($bad.Count -eq 0) {
        $labMsg.Text = "已保存 " + $done + " 项，重启游戏生效"
        $labMsg.ForeColor = [System.Drawing.Color]::FromArgb(60, 120, 60)
    } else {
        $labMsg.Text = "已保存 " + $done + " 项，失败 " + $bad.Count + " 项"
        $labMsg.ForeColor = [System.Drawing.Color]::FromArgb(170, 60, 60)
        $txt = "下面这些没能写进去：`r`n`r`n" + ($bad -join "`r`n")
        [void][System.Windows.Forms.MessageBox]::Show($txt, "保存失败")
    }
    Update-Status
})

$btnAllOn.Add_Click({
    $script:Loading = $true
    try {
        foreach ($row in $grid.Rows) {
            $row.Cells["Enabled"].Value = $true
            if ($row.Tag -ne $null) { $row.Tag.Enabled = $true }
        }
    } finally { $script:Loading = $false }
    $labMsg.Text = "已勾选看得见的 " + $grid.Rows.Count + " 行，点「保存」生效"
})

$btnAllOff.Add_Click({
    $script:Loading = $true
    try {
        foreach ($row in $grid.Rows) {
            $row.Cells["Enabled"].Value = $false
            if ($row.Tag -ne $null) { $row.Tag.Enabled = $false }
        }
    } finally { $script:Loading = $false }
    $labMsg.Text = "已取消看得见的 " + $grid.Rows.Count + " 行，点「保存」生效"
})

$btnReload.Add_Click({
    $ok = Load-Mods
    Update-Grid
    Update-PathLabel
    if (-not $ok) {
        $labMsg.Text = "找不到 mods 文件夹，先设置路径"
        $labMsg.ForeColor = [System.Drawing.Color]::FromArgb(170, 60, 60)
    } else {
        $labMsg.Text = "已刷新"
        $labMsg.ForeColor = [System.Drawing.Color]::FromArgb(60, 120, 60)
    }
})

$btnOpen.Add_Click({
    $md = Get-ModsDir $script:CFG
    if ($md -ne "" -and (Test-Path -LiteralPath $md)) {
        try { Start-Process -FilePath $md } catch { }
    } else {
        [void][System.Windows.Forms.MessageBox]::Show("mods 文件夹不存在，先点「设置路径」。", "打开失败")
    }
})

# ---------------- 路径设置窗口 ----------------
$btnPaths.Add_Click({
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "设置路径"
    $dlg.Size = New-Object System.Drawing.Size(700, 272)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(246, 239, 227)
    $dlg.Font = New-Object System.Drawing.Font("Microsoft YaHei", 9)

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = "游戏目录"; $l1.Location = New-Object System.Drawing.Point(16, 22); $l1.Size = New-Object System.Drawing.Size(90, 22)
    $dlg.Controls.Add($l1)

    $t1 = New-Object System.Windows.Forms.TextBox
    $t1.Text = $CFG["gameDir"]; $t1.Location = New-Object System.Drawing.Point(110, 20); $t1.Size = New-Object System.Drawing.Size(466, 24)
    $dlg.Controls.Add($t1)

    $b1 = New-Object System.Windows.Forms.Button
    $b1.Text = "浏览"; $b1.Location = New-Object System.Drawing.Point(582, 19); $b1.Size = New-Object System.Drawing.Size(80, 26)
    $dlg.Controls.Add($b1)
    $b1.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = "选含 isaac-ng.exe 的那个文件夹"
        if (Test-Path -LiteralPath $t1.Text) { $fb.SelectedPath = $t1.Text }
        if ($fb.ShowDialog() -eq "OK") { $t1.Text = $fb.SelectedPath }
    })

    $bAuto = New-Object System.Windows.Forms.Button
    $bAuto.Text = "自动识别游戏目录"; $bAuto.Location = New-Object System.Drawing.Point(110, 54); $bAuto.Size = New-Object System.Drawing.Size(132, 28)
    $dlg.Controls.Add($bAuto)
    $bAuto.Add_Click({
        $found = Find-IsaacGameDir
        if ($found -ne "") {
            $t1.Text = $found
        } else {
            [void][System.Windows.Forms.MessageBox]::Show("没自动找到。`r`n`r`n可以点「浏览」自己选：`r`nSteam → 库 → 右键 The Binding of Isaac → 管理 → 浏览本地文件。", "没找到")
        }
    })

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = "卡片输出目录"; $l2.Location = New-Object System.Drawing.Point(16, 96); $l2.Size = New-Object System.Drawing.Size(94, 22)
    $dlg.Controls.Add($l2)

    $t2 = New-Object System.Windows.Forms.TextBox
    $t2.Text = $CFG["outDir"]; $t2.Location = New-Object System.Drawing.Point(110, 94); $t2.Size = New-Object System.Drawing.Size(466, 24)
    $dlg.Controls.Add($t2)

    $b2 = New-Object System.Windows.Forms.Button
    $b2.Text = "浏览"; $b2.Location = New-Object System.Drawing.Point(582, 93); $b2.Size = New-Object System.Drawing.Size(80, 26)
    $dlg.Controls.Add($b2)
    $b2.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        if (Test-Path -LiteralPath $t2.Text) { $fb.SelectedPath = $t2.Text }
        if ($fb.ShowDialog() -eq "OK") { $t2.Text = $fb.SelectedPath }
    })

    $tip = New-Object System.Windows.Forms.Label
    $tip.Text = "游戏目录 = 含 isaac-ng.exe 的文件夹（一般在 ...\steamapps\common\The Binding of Isaac Rebirth）`r`n卡片输出目录 = 战报图片放哪，只给战报工具用，不管的话留空就行"
    $tip.Location = New-Object System.Drawing.Point(16, 128)
    $tip.Size = New-Object System.Drawing.Size(650, 40)
    $tip.ForeColor = [System.Drawing.Color]::FromArgb(130, 110, 90)
    $dlg.Controls.Add($tip)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "保存并刷新"; $ok.Location = New-Object System.Drawing.Point(456, 180); $ok.Size = New-Object System.Drawing.Size(118, 32)
    $dlg.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "取消"; $cancel.Location = New-Object System.Drawing.Point(582, 180); $cancel.Size = New-Object System.Drawing.Size(80, 32)
    $dlg.Controls.Add($cancel)

    $ok.Add_Click({
        $g = $t1.Text.Trim().TrimEnd('\')
        if ($g -ne "" -and -not (Test-IsaacGameDir $g)) {
            $r = [System.Windows.Forms.MessageBox]::Show("这个文件夹里没有 isaac-ng.exe，可能选错了一层。`r`n`r`n还是要保存吗？", "确认", 4, 48)
            if ($r -ne 6) { return }
        }
        $CFG["gameDir"] = $g
        if ($t2.Text.Trim() -ne "") { $CFG["outDir"] = $t2.Text.Trim().TrimEnd('\') }
        Save-UiConfig $CFG
        Update-PathLabel
        $okLoad = Load-Mods
        Update-Grid
        if ($okLoad) {
            $labMsg.Text = "路径已保存，读出 " + $script:Mods.Count + " 个 mod"
            $labMsg.ForeColor = [System.Drawing.Color]::FromArgb(60, 120, 60)
        } else {
            $labMsg.Text = "路径已保存，但这个目录下没有 mods 文件夹"
            $labMsg.ForeColor = [System.Drawing.Color]::FromArgb(170, 60, 60)
        }
        $dlg.Close()
    })
    $cancel.Add_Click({ $dlg.Close() })

    [void]$dlg.ShowDialog()
})

# ---------------- 启动 ----------------
[void](Load-Mods)
Update-Grid
Update-PathLabel

if (-not (Test-IsaacGameDir $script:CFG["gameDir"])) {
    # 第一次用：直接把路径窗口弹出来，省得看着空列表发愁
    $labMsg.Text = "先设置一次游戏目录"
    $labMsg.ForeColor = [System.Drawing.Color]::FromArgb(170, 60, 60)
    $tmr = New-Object System.Windows.Forms.Timer
    $tmr.Interval = 350
    $tmr.Add_Tick({
        $this.Stop()
        $btnPaths.PerformClick()
    })
    $tmr.Start()
}

[void]$form.ShowDialog()

} catch {
    [void][System.Windows.Forms.MessageBox]::Show(("启动出错：`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" + $_.InvocationInfo.PositionMessage), "Mod 管理器")
}
