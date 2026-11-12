<#
  CampusNet-GUI.ps1 —— 郑航校园网自动登录 · 图形界面
  ------------------------------------------------------------------
  一个简单的 WinForms 小工具，用来：
    · 输入学号/密码，一键安装开机自动登录（SYSTEM 计划任务）
    · 查看运行状态、快速自检、真实断网测试
    · 暂停/恢复、卸载
  运行需要管理员权限（脚本会自动请求 UAC）。
  仅使用 Windows 自带 PowerShell 5.1 + .NET Framework，无需安装任何依赖。
#>
[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'

$script:AppDir        = $PSScriptRoot
$script:SrcDir        = Split-Path -Parent $PSScriptRoot
$script:RepoRoot      = Split-Path -Parent $script:SrcDir
$script:RuntimeSource = Join-Path $script:SrcDir 'runtime'
$script:CampusTargetDir = 'C:\CampusNet'
$script:CampusTaskName  = 'CampusNet-AutoLogin'
$script:Version = '1.2.3'
$script:ProjectName = '郑航校园网自动登录'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:IsAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------- 管理员自提升 ----------
if (-not $script:IsAdmin -and -not $SelfTest) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')
        ) | Out-Null
    } catch {}
    exit
}

# ---------- 载入运行时 ----------
. (Join-Path $script:RuntimeSource 'portal-lib.ps1')
. (Join-Path $script:RuntimeSource 'install-lib.ps1')
$script:cfg = Get-DefaultCfg
$script:installedCfgFile = Join-Path $script:CampusTargetDir 'config.json'
if (Test-Path $script:installedCfgFile) {
    try {
        $j = Get-Content -LiteralPath $script:installedCfgFile -Raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { if ($null -ne $p.Value) { $script:cfg[$p.Name] = $p.Value } }
    } catch {}
}

# ============================ 界面 ============================
function New-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $script:ProjectName + '  v' + $script:Version
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.AutoScaleMode = 'Dpi'
    $form.ClientSize = New-Object System.Drawing.Size(640, 664)
    try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9) } catch {}
    try { $form.Icon = [System.Drawing.SystemIcons]::Application } catch {}

    $fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
    $fontSub = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $fontBold = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $fontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
    $fontMono = $null
    try { $fontMono = New-Object System.Drawing.Font('Consolas', 8.5) } catch {}

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = '郑航校园网自动登录'
    $lblTitle.Font = $fontTitle
    $lblTitle.AutoSize = $true
    $lblTitle.Location = New-Object System.Drawing.Point(16, 12)
    $form.Controls.Add($lblTitle)

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = '开源小工具 · 只登录你自己的 ZUA-Student 账号 · 密码加密保存在本机'
    $lblSub.Font = $fontSub
    $lblSub.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
    $lblSub.AutoSize = $true
    $lblSub.Location = New-Object System.Drawing.Point(18, 48)
    $form.Controls.Add($lblSub)

    # ---- 运行状态 ----
    $grpStatus = New-Object System.Windows.Forms.GroupBox
    $grpStatus.Text = '运行状态'
    $grpStatus.Location = New-Object System.Drawing.Point(12, 72)
    $grpStatus.Size = New-Object System.Drawing.Size(616, 136)
    $form.Controls.Add($grpStatus)

    $script:lblTask = New-Object System.Windows.Forms.Label
    $script:lblTask.Text = '计划任务：读取中...'
    $script:lblTask.AutoSize = $true
    $script:lblTask.Location = New-Object System.Drawing.Point(16, 24)
    $grpStatus.Controls.Add($script:lblTask)

    $script:lblRun = New-Object System.Windows.Forms.Label
    $script:lblRun.Text = '守护进程：读取中...'
    $script:lblRun.AutoSize = $true
    $script:lblRun.Location = New-Object System.Drawing.Point(16, 52)
    $grpStatus.Controls.Add($script:lblRun)

    $script:lblNet = New-Object System.Windows.Forms.Label
    $script:lblNet.Text = '网络状态：点击右侧「刷新状态」检测'
    $script:lblNet.AutoSize = $true
    $script:lblNet.Location = New-Object System.Drawing.Point(16, 80)
    $grpStatus.Controls.Add($script:lblNet)

    $script:lblLast = New-Object System.Windows.Forms.Label
    $script:lblLast.Text = '最近日志：'
    $script:lblLast.AutoSize = $true
    $script:lblLast.Font = $fontSmall
    $script:lblLast.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
    $script:lblLast.Location = New-Object System.Drawing.Point(16, 108)
    $grpStatus.Controls.Add($script:lblLast)

    $script:btnRefresh = New-Object System.Windows.Forms.Button
    $script:btnRefresh.Text = '刷新状态'
    $script:btnRefresh.Location = New-Object System.Drawing.Point(514, 24)
    $script:btnRefresh.Size = New-Object System.Drawing.Size(86, 30)
    $grpStatus.Controls.Add($script:btnRefresh)

    # ---- 账号与安装 ----
    $grpAccount = New-Object System.Windows.Forms.GroupBox
    $grpAccount.Text = '账号与安装'
    $grpAccount.Location = New-Object System.Drawing.Point(12, 216)
    $grpAccount.Size = New-Object System.Drawing.Size(616, 160)
    $form.Controls.Add($grpAccount)

    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = '学号：'
    $lblUser.AutoSize = $true
    $lblUser.Location = New-Object System.Drawing.Point(16, 32)
    $grpAccount.Controls.Add($lblUser)

    $script:txtUser = New-Object System.Windows.Forms.TextBox
    $script:txtUser.Location = New-Object System.Drawing.Point(80, 28)
    $script:txtUser.Size = New-Object System.Drawing.Size(250, 26)
    $grpAccount.Controls.Add($script:txtUser)

    $lblPwd = New-Object System.Windows.Forms.Label
    $lblPwd.Text = '密码：'
    $lblPwd.AutoSize = $true
    $lblPwd.Location = New-Object System.Drawing.Point(350, 32)
    $grpAccount.Controls.Add($lblPwd)

    $script:txtPwd = New-Object System.Windows.Forms.TextBox
    $script:txtPwd.Location = New-Object System.Drawing.Point(414, 28)
    $script:txtPwd.Size = New-Object System.Drawing.Size(186, 26)
    $script:txtPwd.UseSystemPasswordChar = $true
    $grpAccount.Controls.Add($script:txtPwd)

    $script:chkShow = New-Object System.Windows.Forms.CheckBox
    $script:chkShow.Text = '显示密码'
    $script:chkShow.AutoSize = $true
    $script:chkShow.Location = New-Object System.Drawing.Point(414, 62)
    $grpAccount.Controls.Add($script:chkShow)

    $script:btnInstall = New-Object System.Windows.Forms.Button
    $script:btnInstall.Text = '一键安装 / 更新凭据'
    $script:btnInstall.Font = $fontBold
    $script:btnInstall.Location = New-Object System.Drawing.Point(16, 96)
    $script:btnInstall.Size = New-Object System.Drawing.Size(220, 40)
    $grpAccount.Controls.Add($script:btnInstall)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = '安装后会注册 SYSTEM 计划任务：开机 / 锁屏界面就自动登录，掉线也自动重连。'
    $lblHint.Font = $fontSmall
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
    $lblHint.AutoSize = $true
    $lblHint.Location = New-Object System.Drawing.Point(250, 100)
    $grpAccount.Controls.Add($lblHint)

    $lblHint2 = New-Object System.Windows.Forms.Label
    $lblHint2.Text = '密码用 Windows DPAPI（机器级）加密保存在 C:\CampusNet\cred.dat，仅本机可解密。'
    $lblHint2.Font = $fontSmall
    $lblHint2.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
    $lblHint2.AutoSize = $true
    $lblHint2.Location = New-Object System.Drawing.Point(250, 122)
    $grpAccount.Controls.Add($lblHint2)

    # ---- 测试与维护 ----
    $grpMaint = New-Object System.Windows.Forms.GroupBox
    $grpMaint.Text = '测试与维护'
    $grpMaint.Location = New-Object System.Drawing.Point(12, 386)
    $grpMaint.Size = New-Object System.Drawing.Size(616, 100)
    $form.Controls.Add($grpMaint)

    $script:btnSelfCheck = New-Object System.Windows.Forms.Button
    $script:btnSelfCheck.Text = '快速自检'
    $script:btnSelfCheck.Location = New-Object System.Drawing.Point(16, 28)
    $script:btnSelfCheck.Size = New-Object System.Drawing.Size(110, 32)
    $grpMaint.Controls.Add($script:btnSelfCheck)

    $script:btnLoopTest = New-Object System.Windows.Forms.Button
    $script:btnLoopTest.Text = '真实断网测试'
    $script:btnLoopTest.Location = New-Object System.Drawing.Point(140, 28)
    $script:btnLoopTest.Size = New-Object System.Drawing.Size(130, 32)
    $grpMaint.Controls.Add($script:btnLoopTest)

    $script:btnPause = New-Object System.Windows.Forms.Button
    $script:btnPause.Text = '暂停自动登录'
    $script:btnPause.Location = New-Object System.Drawing.Point(284, 28)
    $script:btnPause.Size = New-Object System.Drawing.Size(130, 32)
    $grpMaint.Controls.Add($script:btnPause)

    $script:btnUninstall = New-Object System.Windows.Forms.Button
    $script:btnUninstall.Text = '卸载'
    $script:btnUninstall.Location = New-Object System.Drawing.Point(428, 28)
    $script:btnUninstall.Size = New-Object System.Drawing.Size(80, 32)
    $grpMaint.Controls.Add($script:btnUninstall)

    $script:btnLog = New-Object System.Windows.Forms.Button
    $script:btnLog.Text = '打开日志'
    $script:btnLog.Location = New-Object System.Drawing.Point(522, 28)
    $script:btnLog.Size = New-Object System.Drawing.Size(80, 32)
    $grpMaint.Controls.Add($script:btnLog)

    $lblMaintTip = New-Object System.Windows.Forms.Label
    $lblMaintTip.Text = '「真实断网测试」会主动下线并测试自动重连，期间断网约 10~30 秒。'
    $lblMaintTip.Font = $fontSmall
    $lblMaintTip.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
    $lblMaintTip.AutoSize = $true
    $lblMaintTip.Location = New-Object System.Drawing.Point(16, 70)
    $grpMaint.Controls.Add($lblMaintTip)

    # ---- 日志输出 ----
    $grpLog = New-Object System.Windows.Forms.GroupBox
    $grpLog.Text = '输出 / 日志（最近 40 行）'
    $grpLog.Location = New-Object System.Drawing.Point(12, 496)
    $grpLog.Size = New-Object System.Drawing.Size(616, 130)
    $form.Controls.Add($grpLog)

    $script:txtLog = New-Object System.Windows.Forms.TextBox
    $script:txtLog.Multiline = $true
    $script:txtLog.ReadOnly = $true
    $script:txtLog.ScrollBars = 'Vertical'
    $script:txtLog.Location = New-Object System.Drawing.Point(12, 24)
    $script:txtLog.Size = New-Object System.Drawing.Size(480, 96)
    if ($fontMono) { $script:txtLog.Font = $fontMono }
    $grpLog.Controls.Add($script:txtLog)

    $script:btnCopyLog = New-Object System.Windows.Forms.Button
    $script:btnCopyLog.Text = '复制日志'
    $script:btnCopyLog.Location = New-Object System.Drawing.Point(500, 26)
    $script:btnCopyLog.Size = New-Object System.Drawing.Size(80, 30)
    $grpLog.Controls.Add($script:btnCopyLog)

    # ---- 底部 ----
    $linkHelp = New-Object System.Windows.Forms.LinkLabel
    $linkHelp.Text = '项目说明 / 常见问题'
    $linkHelp.AutoSize = $true
    $linkHelp.Location = New-Object System.Drawing.Point(14, 636)
    $form.Controls.Add($linkHelp)

    $lblBottom = New-Object System.Windows.Forms.Label
    $lblBottom.Text = '开源项目 · MIT License · v' + $script:Version
    $lblBottom.Font = $fontSmall
    $lblBottom.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
    $lblBottom.AutoSize = $true
    $lblBottom.Location = New-Object System.Drawing.Point(430, 636)
    $form.Controls.Add($lblBottom)

    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 15000

    # ---- 事件 ----
    $script:chkShow.Add_CheckedChanged({
        $script:txtPwd.UseSystemPasswordChar = -not $script:chkShow.Checked
    })

    $script:btnCopyLog.Add_Click({
        try {
            [System.Windows.Forms.Clipboard]::SetText($script:txtLog.Text)
            Append-Log '日志已复制到剪贴板'
        } catch {
            [System.Windows.Forms.MessageBox]::Show('复制失败：' + $_.Exception.Message, '提示', 'OK', 'Warning') | Out-Null
        }
    })

    $script:txtUser.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Do-Install }
    })
    $script:txtPwd.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Do-Install }
    })

    $script:btnRefresh.Add_Click({
        $script:btnRefresh.Enabled = $false
        try {
            $script:form.UseWaitCursor = $true
            [System.Windows.Forms.Application]::DoEvents()
            Update-Status
            Update-NetStatus
        } finally {
            $script:form.UseWaitCursor = $false
            $script:btnRefresh.Enabled = $true
        }
    })

    $script:btnInstall.Add_Click({ Do-Install })
    $script:btnSelfCheck.Add_Click({ Do-SelfCheck })
    $script:btnLoopTest.Add_Click({ Do-LoopTest })
    $script:btnPause.Add_Click({ Do-TogglePause })
    $script:btnUninstall.Add_Click({ Do-Uninstall })
    $script:btnLog.Add_Click({ Do-OpenLog })
    $linkHelp.Add_Click({ Show-Help })

    $script:timer.Add_Tick({ Update-Status })

    $script:form = $form
    return $form
}

# ============================ 状态 ============================
function Append-Log([string]$Text) {
    if (-not $script:txtLog) { return }
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Text
    $script:txtLog.AppendText($line + "`r`n")
    $script:txtLog.SelectionStart = $script:txtLog.TextLength
    $script:txtLog.ScrollToCaret()
}

function Update-Status {
    if ($script:Updating) { return }
    $script:Updating = $true
    try {
        $info = Get-CampusInstallInfo
        $taskText = '计划任务：'
        if ($info.Installed) { $taskText += $info.TaskState }
        else { $taskText += '未安装' }
        if ($info.AccountId) { $taskText += '    账号：' + $info.AccountId }
        $script:lblTask.Text = $taskText

        if ($info.WatcherPids.Count -gt 0) {
            $script:lblRun.Text = '守护进程：运行中（PID ' + ($info.WatcherPids -join ', ') + '）'
            $script:lblRun.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
        } elseif ($info.TaskState -eq 'Running' -and -not $info.Paused) {
            $script:lblRun.Text = '守护进程：运行中（计划任务）'
            $script:lblRun.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
        } elseif ($info.Paused) {
            $script:lblRun.Text = '守护进程：已暂停（运行中的进程会在下个周期停止动作）'
            $script:lblRun.ForeColor = [System.Drawing.Color]::FromArgb(170, 110, 0)
        } elseif ($info.Installed) {
            $script:lblRun.Text = '守护进程：未运行（计划任务会在开机/登录时启动）'
            $script:lblRun.ForeColor = [System.Drawing.Color]::FromArgb(160, 40, 40)
        } else {
            $script:lblRun.Text = '守护进程：未安装'
            $script:lblRun.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
        }

        $script:btnPause.Text = if ($info.Paused) { '恢复自动登录' } else { '暂停自动登录' }
        if ($info.Installed) { $script:btnInstall.Text = '更新凭据 / 重装' } else { $script:btnInstall.Text = '一键安装' }

        $last = ''
        if ($info.LogTail.Count -gt 0) { $last = [string]$info.LogTail[-1] }
        if ($last.Length -gt 76) { $last = $last.Substring(0, 76) + '…' }
        $script:lblLast.Text = '最近日志：' + $last

        if ($info.LogTail.Count -gt 0) {
            $script:txtLog.Text = ($info.LogTail -join "`r`n")
            $script:txtLog.SelectionStart = $script:txtLog.TextLength
            $script:txtLog.ScrollToCaret()
        }
    } catch {
        $script:lblTask.Text = '状态读取失败：' + $_.Exception.Message
    } finally {
        $script:Updating = $false
    }
}

function Update-NetStatus {
    $script:lblNet.Text = '网络状态：检测中...'
    $script:lblNet.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $st = Get-PortalState -TimeoutSec 3
        switch ([string]$st.State) {
            'Online' {
                $script:lblNet.Text = '网络状态：已认证，在线'
                $script:lblNet.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
            }
            'Offline' {
                $script:lblNet.Text = '网络状态：已连校园网，未认证（守护会自动登录）'
                $script:lblNet.ForeColor = [System.Drawing.Color]::FromArgb(170, 110, 0)
            }
            'Unreachable' {
                $script:lblNet.Text = '网络状态：未连接校园网（请先连 ZUA-Student）'
                $script:lblNet.ForeColor = [System.Drawing.Color]::FromArgb(160, 40, 40)
            }
            default {
                $script:lblNet.Text = '网络状态：' + $st.State
                $script:lblNet.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
            }
        }
    } catch {
        $script:lblNet.Text = '网络状态：检测失败（' + $_.Exception.Message + '）'
        $script:lblNet.ForeColor = [System.Drawing.Color]::FromArgb(160, 40, 40)
    }
}

# ============================ 动作 ============================
function Do-Install {
    $uid = $script:txtUser.Text.Trim()
    $pwd = $script:txtPwd.Text
    if (-not $uid) {
        [System.Windows.Forms.MessageBox]::Show('请输入学号。', '提示', 'OK', 'Warning') | Out-Null
        $script:txtUser.Focus()
        return
    }
    if (-not $pwd) {
        [System.Windows.Forms.MessageBox]::Show('请输入校园网密码。', '提示', 'OK', 'Warning') | Out-Null
        $script:txtPwd.Focus()
        return
    }
    if (-not $script:IsAdmin) {
        [System.Windows.Forms.MessageBox]::Show('需要管理员权限，请重新运行本程序并允许 UAC 提权。', '提示', 'OK', 'Warning') | Out-Null
        return
    }
    $script:btnInstall.Enabled = $false
    $script:form.UseWaitCursor = $true
    try {
        Append-Log '检查校园网连接状态...'
        [System.Windows.Forms.Application]::DoEvents()
        $st = Get-PortalState -TimeoutSec 3
        if ($st.State -eq 'Unreachable') {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "当前似乎没有连接校园网（ZUA-Student），无法向学校服务器校验密码。`r`n`r`n建议先连上校园网再安装；也可以继续，但密码要等有网时才能验证。`r`n`r`n仍然继续安装吗？",
                '网络提示', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') {
                Append-Log '已取消安装（未连接校园网）'
                return
            }
        }
        Append-Log '正在向学校认证服务器校验账号密码（几秒钟）...'
        [System.Windows.Forms.Application]::DoEvents()
        $check = Test-CampusPassword -UserId $uid -Password $pwd
        Append-Log ('校验结果：' + $check.Msg)
        if (-not $check.Ok) {
            [System.Windows.Forms.MessageBox]::Show(
                "密码校验失败：`r`n`r`n" + $check.Msg + "`r`n`r`n可能原因：密码输错（注意大小写/半角）、或账号已改密码。`r`n可以到 Edge 的「密码」设置里查看保存的校园网密码，再复制粘贴进来。",
                '校验失败', 'OK', 'Warning') | Out-Null
            return
        }
        Append-Log '校验通过，正在安装并注册开机任务...'
        [System.Windows.Forms.Application]::DoEvents()
        $info = Install-CampusNet -UserId $uid -Password $pwd
        $script:txtPwd.Clear()
        Append-Log '安装完成，守护进程已启动。正在做安装后自检...'
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $diag = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:CampusTargetDir 'login.ps1') -Diagnose 2>&1 | Out-String
            foreach ($line in ($diag -split "`r?`n")) {
                if ($line.Trim()) { Append-Log $line.Trim() }
            }
        } catch {
            Append-Log ('安装后自检失败：' + $_.Exception.Message)
        }
        [System.Windows.Forms.MessageBox]::Show(
            "安装成功！`r`n`r`n· 现在是：随时保持在线，掉线自动重连`r`n· 明天开机：锁屏界面就会自动登录，解锁即已联网`r`n`r`n建议点「真实断网测试」验证一次（约断网 10~30 秒）。",
            '安装成功', 'OK', 'Information') | Out-Null
        Update-Status
        Update-NetStatus
    } catch {
        Append-Log ('安装失败：' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show('安装失败：' + $_.Exception.Message, '错误', 'OK', 'Error') | Out-Null
    } finally {
        $script:form.UseWaitCursor = $false
        $script:btnInstall.Enabled = $true
    }
}

function Do-SelfCheck {
    $loginPs1 = Join-Path $script:CampusTargetDir 'login.ps1'
    if (-not (Test-Path $loginPs1)) {
        [System.Windows.Forms.MessageBox]::Show('还没有安装。请先输入学号和密码，点「一键安装 / 更新凭据」。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $script:btnSelfCheck.Enabled = $false
    $script:form.UseWaitCursor = $true
    try {
        Append-Log '--- 快速自检（不登录）---'
        [System.Windows.Forms.Application]::DoEvents()
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $loginPs1 -Diagnose 2>&1 | Out-String
        foreach ($line in ($out -split "`r?`n")) {
            if ($line.Trim()) { Append-Log $line.Trim() }
        }
        Append-Log '--- 自检结束 ---'
        Update-NetStatus
    } catch {
        Append-Log ('自检失败：' + $_.Exception.Message)
    } finally {
        $script:form.UseWaitCursor = $false
        $script:btnSelfCheck.Enabled = $true
    }
}

function Do-LoopTest {
    $testPs1 = Join-Path $script:CampusTargetDir 'test.ps1'
    if (-not (Test-Path $testPs1)) {
        [System.Windows.Forms.MessageBox]::Show('还没有安装，无法测试。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "真实断网测试会：暂停守护 → 主动下线 → 运行自动登录 → 恢复在线。`r`n`r`n测试期间会断网约 10~30 秒，测试窗口会显示每一步结果。`r`n`r`n确定开始？",
        '真实断网测试', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $testPs1 + '"'), '-PauseAtEnd'
        ) | Out-Null
        Append-Log '已打开断网测试窗口，请按窗口提示查看结果。'
    } catch {
        Append-Log ('启动测试失败：' + $_.Exception.Message)
    }
}

function Do-TogglePause {
    $info = Get-CampusInstallInfo
    if (-not $info.Installed) {
        [System.Windows.Forms.MessageBox]::Show('还没有安装。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    try {
        Set-CampusPaused -Paused (-not $info.Paused)
        if (-not $info.Paused) {
            Append-Log '已暂停自动登录（不会自动重连；重启后恢复）。'
        } else {
            Append-Log '已恢复自动登录。'
        }
        Start-Sleep -Milliseconds 300
        Update-Status
    } catch {
        Append-Log ('操作失败：' + $_.Exception.Message)
    }
}

function Do-Uninstall {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "确定卸载？`r`n`r`n将停止后台守护、删除计划任务，并删除 C:\CampusNet 下的全部文件（含日志和加密凭据）。",
        '确认卸载', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    try {
        $ok = Uninstall-CampusNet
        Append-Log '已卸载。'
        [System.Windows.Forms.MessageBox]::Show('已卸载。可以关闭本窗口，或重新安装。', '完成', 'OK', 'Information') | Out-Null
        Update-Status
    } catch {
        Append-Log ('卸载失败：' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show('卸载失败：' + $_.Exception.Message, '错误', 'OK', 'Error') | Out-Null
    }
}

function Do-OpenLog {
    $log = Join-Path $script:CampusTargetDir 'login.log'
    if (Test-Path $log) {
        try { Start-Process notepad.exe $log -ErrorAction SilentlyContinue; return } catch {}
    }
    if (Test-Path $script:CampusTargetDir) {
        Start-Process explorer.exe $script:CampusTargetDir
    } else {
        [System.Windows.Forms.MessageBox]::Show('还没有安装，暂无日志。', '提示', 'OK', 'Information') | Out-Null
    }
}

function Show-Help {
    $msg = @"
$($script:ProjectName) v$($script:Version)

【它做什么】
在开机时（锁屏界面，未解锁）由 SYSTEM 计划任务自动完成
ZUA-Student 校园网的网页认证；网络掉线后也会自动重连。
不需要打开浏览器，不使用你的浏览器密码。

【怎么用】
1. 先连上 ZUA-Student 校园网
2. 输入学号和密码 → 点「一键安装 / 更新凭据」
3. 以后开机会自动登录；想验证可点「真实断网测试」

【常见问题】
· 提示「密码错误」：密码输错或已改密码。可到 Edge 设置→密码 查看保存的密码。
· 开机没自动登录：先看「打开日志」里最后几行；断网时也可用 Edge 手动登录。
· 想临时关闭：点「暂停自动登录」；重启后自动恢复。
· 换电脑：在新电脑上重新运行本程序、重新安装即可。

【安全与隐私】
· 密码用 Windows DPAPI 加密保存在本机，仅本机可解密；不联网上传任何数据。
· 本工具只用于登录自己的校园网账号，请遵守学校网络管理规定，勿共享账号。
"@
    [System.Windows.Forms.MessageBox]::Show($msg, '说明 / 常见问题', 'OK', 'Information') | Out-Null
}

function Prefill-Account {
    try {
        $credFile = Join-Path $script:CampusTargetDir 'cred.dat'
        if ((Test-Path $credFile) -and -not $script:txtUser.Text.Trim()) {
            $c = Get-Content -LiteralPath $credFile -Raw | ConvertFrom-Json
            if ($c.userId) { $script:txtUser.Text = [string]$c.userId }
        }
    } catch {}
}

function Start-Main {
    $form = New-MainForm
    $form.Add_Shown({
        Prefill-Account
        Update-Status
        Update-NetStatus
        $script:timer.Start()
    })
    $form.Add_FormClosed({
        try { $script:timer.Stop() } catch {}
    })
    [System.Windows.Forms.Application]::Run($form)
}

# ============================ 入口 ============================
if ($SelfTest) {
    Write-Host '=== CampusNet GUI SelfTest ==='
    Write-Host ('IsAdmin       = ' + $script:IsAdmin)
    Write-Host ('RuntimeSource = ' + $script:RuntimeSource)
    foreach ($f in @('portal-lib.ps1', 'install-lib.ps1', 'login.ps1', 'test.ps1')) {
        Write-Host ('  ' + $f + ' : ' + (Test-Path (Join-Path $script:RuntimeSource $f)))
    }
    try {
        $info = Get-CampusInstallInfo
        Write-Host ('Installed=' + $info.Installed + '  TaskState=' + $info.TaskState + '  Paused=' + $info.Paused + '  Watcher=' + ($info.WatcherPids -join ','))
    } catch { Write-Host ('状态读取失败: ' + $_.Exception.Message) }
    try {
        $st = Get-PortalState -TimeoutSec 3
        Write-Host ('PortalState   = ' + $st.State)
    } catch { Write-Host ('门户检测失败: ' + $_.Exception.Message) }
    try {
        $w = Get-WlanLocal
        if ($w) { Write-Host ('WLAN          = ' + $w.IP + ' / ' + $w.MAC) } else { Write-Host 'WLAN          = 未连接' }
    } catch { Write-Host ('WLAN 读取失败: ' + $_.Exception.Message) }
    try {
        $form = New-MainForm
        Write-Host ('UI 构造完成，控件数 = ' + $form.Controls.Count)
        $form.Dispose()
    } catch {
        Write-Host ('UI 构造失败: ' + $_.Exception.Message)
        exit 1
    }
    Write-Host 'SelfTest OK'
    exit 0
}

try {
    Start-Main
} catch {
    try {
        [System.Windows.Forms.MessageBox]::Show('程序启动失败：' + $_.Exception.Message, '错误', 'OK', 'Error') | Out-Null
    } catch {}
    exit 1
}
