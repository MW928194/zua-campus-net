# install-lib.ps1 —— 安装 / 卸载 / 暂停 / 状态查询（GUI 与命令行共用）
# 使用前需由调用方设置：
#   $script:CampusTargetDir  安装目录（默认 C:\CampusNet）
#   $script:CampusTaskName   计划任务名
#   $script:RuntimeSource    运行时脚本来源目录（login.ps1 / portal-lib.ps1 / test.ps1）
#   $script:cfg              配置（Get-DefaultCfg 的结果，可含已安装的 config.json 覆盖项）

function New-CampusAcl {
    param([string]$Dir)
    try {
        $acl = Get-Acl $Dir
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($n in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', ($env:USERDOMAIN + '\' + $env:USERNAME))) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($n, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -Path $Dir -AclObject $acl
    } catch {}
}

function Get-CampusWatcherPids {
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and ($_.CommandLine -match 'CampusNet') -and ($_.CommandLine -match 'login\.ps1') }
        return @($procs | Select-Object -ExpandProperty ProcessId)
    } catch { return @() }
}

function Stop-CampusWatcher {
    try { Stop-ScheduledTask -TaskName $script:CampusTaskName -ErrorAction SilentlyContinue } catch {}
    foreach ($procId in (Get-CampusWatcherPids)) {
        try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Milliseconds 500
}

function Get-CampusInstallInfo {
    $dir = $script:CampusTargetDir
    $taskName = $script:CampusTaskName
    $logFile = Join-Path $dir 'login.log'
    $info = [ordered]@{
        Installed   = (Test-Path (Join-Path $dir 'cred.dat'))
        Paused      = (Test-Path (Join-Path $dir 'pause.flag'))
        TaskName    = $taskName
        TaskState   = '未注册'
        TaskLastRun = ''
        TaskResult  = ''
        WatcherPids = @()
        LogFile     = $logFile
        LogTail     = @()
        AccountId   = ''
    }
    try {
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $info.TaskState = [string]$t.State
        $ti = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        if ($ti) {
            if ($ti.LastRunTime) { $info.TaskLastRun = $ti.LastRunTime.ToString('MM-dd HH:mm:ss') }
            $info.TaskResult = [string]$ti.LastTaskResult
        }
    } catch {}
    $info.WatcherPids = @(Get-CampusWatcherPids)
    if (Test-Path $logFile) {
        try { $info.LogTail = @(Get-Content -LiteralPath $logFile -Encoding UTF8 -Tail 40) } catch {}
    }
    if ($info.Installed) {
        try {
            $c = Get-Content -LiteralPath (Join-Path $dir 'cred.dat') -Raw | ConvertFrom-Json
            $id = [string]$c.userId
            if ($id.Length -gt 5) { $info.AccountId = $id.Substring(0, 4) + '****' + $id.Substring($id.Length - 2) } else { $info.AccountId = $id }
        } catch {}
    }
    return $info
}

function Set-CampusPaused {
    param([bool]$Paused)
    $dir = $script:CampusTargetDir
    $flag = Join-Path $dir 'pause.flag'
    if ($Paused) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath $flag -Value 'paused by GUI' -Encoding ASCII
    } else {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 400
}

function Install-CampusNet {
    param(
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $dir = $script:CampusTargetDir
    $runtime = $script:RuntimeSource
    $taskName = $script:CampusTaskName

    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-CampusAcl -Dir $dir

    foreach ($f in @('portal-lib.ps1', 'login.ps1', 'test.ps1')) {
        $srcFile = Join-Path $runtime $f
        if (-not (Test-Path $srcFile)) { throw "缺少运行文件：$srcFile" }
        Copy-Item -LiteralPath $srcFile -Destination (Join-Path $dir $f) -Force
    }

    ConvertTo-Json -InputObject $script:cfg -Depth 4 | Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8

    Add-Type -AssemblyName System.Security
    $enc = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($Password), $null, 'LocalMachine')
    $credObj = [ordered]@{
        userId    = $UserId
        pass      = [Convert]::ToBase64String($enc)
        createdAt = (Get-Date).ToString('s')
    }
    ConvertTo-Json -InputObject $credObj | Set-Content -LiteralPath (Join-Path $dir 'cred.dat') -Encoding UTF8

    Remove-Item -LiteralPath (Join-Path $dir 'pause.flag') -Force -ErrorAction SilentlyContinue

    Stop-CampusWatcher
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $psExe `
        -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $dir 'login.ps1') + '"') `
        -WorkingDirectory $dir
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn)
    )
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principalTask = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings `
        -Principal $principalTask -Description '郑航校园网自动登录 / 掉线重连（SYSTEM，开机启动）' | Out-Null

    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 2
    return (Get-CampusInstallInfo)
}

function Uninstall-CampusNet {
    $dir = $script:CampusTargetDir
    Stop-CampusWatcher
    Unregister-ScheduledTask -TaskName $script:CampusTaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 300
    return (-not (Test-Path $dir))
}
