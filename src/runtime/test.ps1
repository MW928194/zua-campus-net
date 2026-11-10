<#
    test.ps1 —— 真实环回测试
    流程：暂停后台守护 → 主动下线 → 确认已离线 → 运行 login.ps1 -Once 自动登录 → 确认在线
    注意：测试期间会断网约 10~60 秒（失败时会自己继续重试）。请先确认可以接受。
#>
[CmdletBinding()]
param(
    [switch]$NoLogout,   # 跳过下线步骤，只测登录请求
    [switch]$PauseAtEnd  # 结束后等待回车（GUI 拉起时用，便于看结果）
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$reportFile = Join-Path $scriptDir '测试报告.txt'
$pauseFile = Join-Path $scriptDir 'pause.flag'
$cfgFile = Join-Path $scriptDir 'config.json'
$loginPs1 = Join-Path $scriptDir 'login.ps1'

function Say {
    param([string]$Message)
    Write-Host $Message
    try {
        [System.IO.File]::AppendAllText($reportFile, $Message + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

if (-not (Test-Path $loginPs1)) { Say "找不到 $loginPs1，请先运行安装程序"; exit 1 }
try { [System.IO.File]::WriteAllText($reportFile, '', (New-Object System.Text.UTF8Encoding($false))) } catch {}

. (Join-Path $scriptDir 'portal-lib.ps1')
$script:cfg = Get-DefaultCfg
if (Test-Path $cfgFile) {
    try {
        $j = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { if ($null -ne $p.Value) { $script:cfg[$p.Name] = $p.Value } }
    } catch {}
}

$paused = $false
$logoutDone = $false
$offlineAfterLogout = $false
try {
    Say ('=== 校园网自动登录 环回测试  ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ===')
    $w = Get-WlanLocal
    if ($w) { Say "本机 WLAN: IP=$($w.IP) MAC=$($w.MAC)" } else { Say '本机 WLAN: 未连接/无 IP（继续测试登录流程）' }

    $st = Get-PortalState
    Say "当前门户状态: $($st.State)"

    if ($st.State -eq 'Online' -and -not $NoLogout) {
        # 1) 暂停后台守护，避免它抢在我们前面登录
        Set-Content -LiteralPath $pauseFile -Value 'test' -Encoding ASCII
        $paused = $true
        Say '已暂停后台守护进程（pause.flag），等待 10 秒...'
        Start-Sleep -Seconds 10

        # 2) 复现浏览器的「下线」动作
        $jar = New-Object System.Net.CookieContainer
        $statusUrl = 'http://' + $script:cfg.portalHost + '/webdisconnweb.do?wlanacname=' + [System.Uri]::EscapeDataString([string]$script:cfg.wlanacname)
        $r1 = Invoke-Http -Url $statusUrl -NoRedirect -Cookies $jar -TimeoutSec 8
        Say "状态接口: HTTP $($r1.Status)  Location=$($r1.Location)"
        if ($r1.Location -match 'index_auth') {
            $loc = Resolve-PortalUrl -Base $statusUrl -Location $r1.Location
            $q = ([System.Uri]$loc).Query.TrimStart('?')
            $succUrl = 'http://' + $script:cfg.portalHost + '/webauth.do?' + $q
            $page = Invoke-Http -Url $succUrl -Cookies $jar -TimeoutSec 10
            Say "已在线页面: HTTP $($page.Status)，$($page.Content.Length) 字节，connUserId=$(Get-InputValue -Html $page.Content -Id 'connUserId')"
            $fields = Get-HtmlInputs -Html $page.Content
            $urlPam = Get-InputValue -Html $page.Content -Id 'urlParameter'
            Say "下线用 urlParameter: $urlPam"
            if ($urlPam) {
                $action = 'http://' + $script:cfg.portalHost + '/webdisconn.do?' + $urlPam
                $body = ConvertTo-FormBody -Fields $fields
                $lr = Invoke-Http -Url $action -Method 'POST' -Body $body -Cookies $jar -Referer $succUrl -TimeoutSec 15
                Say "下线请求: HTTP $($lr.Status)，响应 $($lr.Content.Length) 字节"
                $logoutDone = $true
            }
        }

        # 3) 等待离线
        $s = $null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 2
            $s = Get-PortalState
            if ($s.State -ne 'Online') { break }
        }
        if ($s) { Say "下线后门户状态: $($s.State)" } else { Say '下线后门户状态: 未知' }
        if ($s -and $s.State -ne 'Online') { $offlineAfterLogout = $true }
    } elseif ($st.State -eq 'Online') {
        Say '按参数跳过下线步骤，直接测试登录请求'
    } else {
        Say '当前本来就未认证，直接测试登录'
        $offlineAfterLogout = $true
    }

    # 4) 记录未认证状态下网关会给出什么
    Say '--- 未认证状态下的网关探测（用于确认动态参数发现路径） ---'
    foreach ($p in @($script:cfg.gatewayProbes)) {
        try {
            $g = Invoke-Http -Url $p -NoRedirect -TimeoutSec 6
            Say ("  $p  ->  HTTP $($g.Status)  Location=$($g.Location)")
        } catch {
            Say ("  $p  ->  失败: " + $_.Exception.Message)
        }
    }

    # 5) 运行自动登录
    $result = 1
    if ($offlineAfterLogout) {
        Say '--- 运行 login.ps1 -Once（真实离线 → 自动登录） ---'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $loginPs1 -Once -Console 2>&1 | Out-String
        $code = $LASTEXITCODE
        Say $out.Trim()
        Say "login.ps1 退出码: $code"

        $final = $null
        for ($i = 0; $i -lt 15; $i++) {
            $final = Get-PortalState
            if ($final.State -eq 'Online') { break }
            Start-Sleep -Seconds 2
        }
        if ($final) { Say "最终门户状态: $($final.State)" } else { Say '最终门户状态: 未知' }
        if ($final -and $final.State -eq 'Online') {
            Say '>>> 测试通过：脚本在离线状态下自动完成了认证，网络已恢复。'
            $result = 0
        } else {
            Say '>>> 测试未通过：脚本未能恢复网络。请先用 Edge 手动登录，再把 测试报告.txt 反馈排查。'
            Say '正在打开校园网认证页（Edge 点两下即可手动登录）...'
            try { Start-Process 'http://202.196.169.166/' } catch {}
            $result = 1
        }
    } else {
        Say '--- 未能进入离线状态（主动下线接口可能被策略禁止），改为强制登录请求诊断 ---'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $loginPs1 -Force -Console 2>&1 | Out-String
        $code = $LASTEXITCODE
        Say $out.Trim()
        Say "login.ps1 -Force 退出码: $code（请把上面「POST 响应/门户错误」一行反馈出来）"
        $result = 2
    }
} catch {
    Say ("测试异常: " + $_.Exception.Message)
    $result = 1
} finally {
    if ($paused -and (Test-Path $pauseFile)) {
        Remove-Item -LiteralPath $pauseFile -Force -ErrorAction SilentlyContinue
        Say '已恢复后台守护进程（删除 pause.flag）'
    }
}
exit $result
