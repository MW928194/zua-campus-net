<#
    login.ps1 —— 郑航（ZUA）校园网自动登录 / 掉线自动重连
    ------------------------------------------------------------------
    由 Windows 计划任务以 SYSTEM 身份在「开机时」启动，常驻循环：
      1) 等 Wi-Fi 拿到 IP
      2) 查门户认证状态（webdisconnweb.do）
      3) 未认证就重放认证页的登录表单（webauth.do POST）
      4) 已认证则定时复查；掉线自动重登
    因为跑在 SYSTEM（session 0），所以发生在你输密码解锁之前。

    手动用法（调试）：
      powershell -NoProfile -ExecutionPolicy Bypass -File login.ps1 -Diagnose
      powershell -NoProfile -ExecutionPolicy Bypass -File login.ps1 -Once -Console
      powershell -NoProfile -ExecutionPolicy Bypass -File login.ps1 -Force -Console
#>
[CmdletBinding()]
param(
    [switch]$Once,       # 只跑一轮（手动测试用）
    [switch]$Force,      # 已在线也强制发一次登录请求（验证请求格式/密码）
    [switch]$Diagnose,   # 只打印诊断信息，不登录
    [switch]$Console     # 同时输出到控制台
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:LogFile = Join-Path $scriptDir 'login.log'
$script:PauseFile = Join-Path $scriptDir 'pause.flag'
$script:CredFile = Join-Path $scriptDir 'cred.dat'
$script:CfgFile = Join-Path $scriptDir 'config.json'

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    try {
        [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
    if ($Console -or $Diagnose) { Write-Host $line }
}

# ---------- 配置 ----------
. (Join-Path $scriptDir 'portal-lib.ps1')
$script:cfg = Get-DefaultCfg
if (Test-Path $script:CfgFile) {
    try {
        $j = Get-Content -LiteralPath $script:CfgFile -Raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { if ($null -ne $p.Value) { $script:cfg[$p.Name] = $p.Value } }
    } catch {}
}

# ---------- 诊断模式（不需要凭据） ----------
if ($Diagnose) {
    Write-Log '=== 配置 ==='
    foreach ($k in $script:cfg.Keys) { Write-Log ("  $k = " + ($script:cfg[$k] -join ', ')) }
    $w = Get-WlanLocal
    if ($w) { Write-Log "WLAN: IP=$($w.IP)  MAC=$($w.MAC)" } else { Write-Log 'WLAN: 未连接/无有效 IP' }
    $st = Get-PortalState
    Write-Log "门户状态: $($st.State)"
    if ($st.LoginUrl) { Write-Log "状态接口给的登录地址: $($st.LoginUrl)" }
    if ($st.Error) { Write-Log "状态接口错误: $($st.Error)" }
    if ($st.State -ne 'Online') {
        $gw = Find-GatewayLoginUrl
        Write-Log "网关重定向发现: $gw"
        $u = $null
        if ($gw -and $gw -ne '__ONLINE__') { $u = $gw }
        elseif ($st.LoginUrl) { $u = $st.LoginUrl }
        else { $u = Build-LoginUrl -Wlan $w }
        $u = Complete-LoginUrl -Url $u -Wlan $w
        Write-Log "最终将使用的登录页: $u"
        try {
            $p = Invoke-Http -Url $u -TimeoutSec 10
            Write-Log "登录页 HTTP $($p.Status)，长度 $($p.Content.Length)"
            $f = Get-HtmlInputs -Html $p.Content
            Write-Log "解析到表单字段 $($f.Count) 个: $($f.Keys -join ', ')"
            Write-Log "urlParameter = $(Get-InputValue -Html $p.Content -Id 'urlParameter')"
        } catch { Write-Log "登录页抓取失败: $($_.Exception.Message)" }
    }
    exit 0
}

# ---------- 凭据 ----------
if (-not (Test-Path $script:CredFile)) {
    Write-Log "缺少凭据文件 $script:CredFile，请先运行 setup.ps1 安装"
    exit 2
}
try {
    Add-Type -AssemblyName System.Security
    $cred = Get-Content -LiteralPath $script:CredFile -Raw | ConvertFrom-Json
    $script:userId = [string]$cred.userId
    $enc = [Convert]::FromBase64String([string]$cred.pass)
    $script:pwd = [System.Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, 'LocalMachine'))
    if (-not $script:userId -or -not $script:pwd) { throw '凭据内容为空' }
} catch {
    Write-Log "读取凭据失败: $($_.Exception.Message)"
    exit 2
}

# ---------- 核心：登录一次 ----------
function Try-Login {
    param($Wlan, [switch]$IgnoreOnline, $KnownState)
    $state = $KnownState
    if (-not $state) { $state = Get-PortalState }
    if (-not $IgnoreOnline -and $state.State -eq 'Online') {
        return [pscustomobject]@{ Success = $true; Message = '已在线' }
    }
    $loginUrl = $null
    if (-not $IgnoreOnline) {
        if ($state.LoginUrl) { $loginUrl = $state.LoginUrl }
        if (-not $loginUrl) {
            $gw = Find-GatewayLoginUrl
            if ($gw -eq '__ONLINE__') { return [pscustomobject]@{ Success = $true; Message = '网关显示已在线' } }
            if ($gw) { $loginUrl = $gw }
        }
    }
    if (-not $loginUrl) { $loginUrl = Build-LoginUrl -Wlan $Wlan }
    $loginUrl = Complete-LoginUrl -Url $loginUrl -Wlan $Wlan
    Write-Log "登录页: $loginUrl"

    $jar = New-Object System.Net.CookieContainer
    $page = Invoke-Http -Url $loginUrl -Cookies $jar -TimeoutSec 10
    if ($page.Status -ne 200) {
        return [pscustomobject]@{ Success = $false; Message = "登录页 HTTP $($page.Status)" }
    }
    $fields = Get-HtmlInputs -Html $page.Content
    if ($fields.Count -lt 3) {
        $snip = ''
        if ($page.Content) { $snip = $page.Content.Substring(0, [Math]::Min(120, $page.Content.Length)) }
        return [pscustomobject]@{ Success = $false; Message = "登录页解析失败(字段 $($fields.Count)): $snip" }
    }
    $fields['userId'] = $script:userId
    $fields['passwd'] = $script:pwd
    $fields['isRemind'] = '1'
    $fields['remInfo'] = 'on'
    $fields['desc_lb'] = 'on'

    $urlPam = Get-InputValue -Html $page.Content -Id 'urlParameter'
    if (-not $urlPam) {
        $q = ([System.Uri]$loginUrl).Query
        if ($q) { $urlPam = $q.TrimStart('?') }
    }
    $action = 'http://' + $script:cfg.portalHost + '/webauth.do?' + $urlPam
    $body = ConvertTo-FormBody -Fields $fields
    $resp = Invoke-Http -Url $action -Method 'POST' -Body $body -Cookies $jar -Referer $loginUrl -TimeoutSec 15

    $hasSuccess = ($resp.Content -match 'id="auth_success"|id="connUserId"')
    $hasLoginForm = ($resp.Content -match 'id="goLoginForm"')
    for ($i = 0; $i -lt 3; $i++) {
        Start-Sleep -Milliseconds 1000
        $st = Get-PortalState
        if ($st.State -eq 'Online') {
            return [pscustomobject]@{
                Success = $true; Message = "登录成功（POST HTTP $($resp.Status)）"
                ResponseStatus = $resp.Status; ResponseLength = $resp.Content.Length
                ErrorText = ''; HasSuccessMarker = $hasSuccess; HasLoginForm = $hasLoginForm
            }
        }
    }
    $err = Extract-PortalError -Html $resp.Content
    $msg = "登录失败: POST HTTP $($resp.Status)，响应 $($resp.Content.Length) 字节"
    if ($err) { $msg = $msg + "，门户提示: $err" }
    return [pscustomobject]@{
        Success = $false; Message = $msg
        ResponseStatus = $resp.Status; ResponseLength = $resp.Content.Length
        ErrorText = $err; HasSuccessMarker = $hasSuccess; HasLoginForm = $hasLoginForm
    }
}

# ---------- Force 模式：验证登录请求格式/密码 ----------
if ($Force) {
    $w = Get-WlanLocal
    if (-not $w) { Write-Log 'WLAN 未就绪，无法测试'; exit 3 }
    $r = Try-Login -Wlan $w -IgnoreOnline
    Write-Log ('FORCE 结果: ' + $r.Message)
    Write-Log ("  POST 响应: HTTP $($r.ResponseStatus)，$($r.ResponseLength) 字节，含成功标记=$($r.HasSuccessMarker)，含登录表单=$($r.HasLoginForm)")
    if ($r.ErrorText) { Write-Log ('  门户错误: ' + $r.ErrorText) }
    if ($r.Success) { exit 0 } else { exit 1 }
}

# ---------- 主循环 ----------
# 单实例保护：避免重复安装/多次触发导致多个守护进程同时登录
if (-not $Once -and -not $Force) {
    try {
        $script:singletonMutex = New-Object System.Threading.Mutex($false, 'Global\ZUA-CampusNet-AutoLogin')
        if (-not $script:singletonMutex.WaitOne(0)) {
            Write-Log '已有守护实例在运行，本实例退出'
            exit 0
        }
    } catch {}
}

$fail = 0
$lastState = ''
Write-Log 'watcher started v1.2.0'
while ($true) {
    try {
        if (Test-Path $script:PauseFile) {
            if ($lastState -ne 'paused') { Write-Log '检测到 pause.flag，暂停自动登录'; $lastState = 'paused' }
            Start-Sleep -Seconds 10
            continue
        }
        $st = Get-PortalState
        if ($st.State -eq 'Online') {
            if ($lastState -ne 'online') { Write-Log '网络已在线'; $lastState = 'online' }
            $fail = 0
            if ($Once) { exit 0 }
            Start-Sleep -Seconds ([int]$script:cfg.onlineCheckSeconds)
            continue
        }
        if ($st.State -eq 'Unreachable') {
            if ($lastState -ne 'unreachable') { Write-Log "认证服务器不可达（可能在等 Wi-Fi/获取 IP）: $($st.Error)"; $lastState = 'unreachable' }
            if ($Once) { Write-Log '网络不可达，退出'; exit 1 }
            Start-Sleep -Seconds 5
            continue
        }
        $w = Get-WlanLocal
        if (-not $w) {
            if ($lastState -ne 'wlan-down') { Write-Log 'Wi-Fi 未连接/未取得 IP，等待...'; $lastState = 'wlan-down' }
            if ($Once) { Write-Log 'WLAN 未就绪，退出'; exit 1 }
            Start-Sleep -Seconds 5
            continue
        }
        if ($lastState -ne 'offline') { Write-Log '网络未认证，尝试登录...'; $lastState = 'offline' }
        $r = Try-Login -Wlan $w -KnownState $st
        if ($r.Success) {
            Write-Log $r.Message
            $fail = 0
            $lastState = 'online'
            if ($Once) { exit 0 }
            Start-Sleep -Seconds 5
        } else {
            $fail++
            Write-Log "第 $fail 次失败: $($r.Message)"
            if ($Once) { exit 1 }
            $waits = @(4, 15, 60, 120, 300, 600)
            $wait = $waits[[Math]::Min($fail - 1, $waits.Count - 1)]
            Write-Log "等待 $wait 秒后重试"
            Start-Sleep -Seconds $wait
        }
    } catch {
        Write-Log "异常: $($_.Exception.Message)"
        if ($Once) { exit 1 }
        Start-Sleep -Seconds 10
    }
}
