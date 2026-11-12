# portal-lib.ps1 —— 郑航（ZUA）bossWeb 校园网门户通用助手
# 被 login.ps1 / test.ps1 / setup.ps1 点源加载。
# 约定：调用方先定义 $script:cfg（哈希表）。

if (-not $script:UA) {
    $script:UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36 Edg/157.0.0.0'
}
$script:EncUtf8 = New-Object System.Text.UTF8Encoding($false)

function Get-DefaultCfg {
    $c = [ordered]@{
        portalHost         = '202.196.169.166'
        wlanacname         = 'ZZHK-ZAX-BRAS'
        wlanacip           = '10.0.1.10'
        wlanInterface      = 'WLAN'
        onlineCheckSeconds = 6
        gatewayProbes      = @(
            'http://www.msftconnecttest.com/redirect',
            'http://connect.rom.miui.com/generate_204'
        )
    }
    return ,$c
}

function Resolve-PortalUrl {
    param([string]$Base, [string]$Location)
    if (-not $Location) { return $null }
    if ($Location -match '(?i)^https?://') { return $Location }
    if ($Location.StartsWith('/')) { return ('http://' + $script:cfg.portalHost + $Location) }
    try { return ([System.Uri]::new([System.Uri]$Base, $Location)).AbsoluteUri } catch { return $Location }
}

function Invoke-Http {
    param(
        [string]$Url,
        [string]$Method = 'GET',
        $Body = $null,
        $Cookies = $null,
        [string]$Referer = $null,
        [switch]$NoRedirect,
        [int]$TimeoutSec = 8
    )
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.UserAgent = $script:UA
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.AllowAutoRedirect = (-not $NoRedirect)
    $req.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    if ($Cookies) { $req.CookieContainer = $Cookies }
    if ($Referer) { $req.Referer = $Referer }
    if ($null -ne $Body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = 'application/x-www-form-urlencoded'
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }
    $resp = $null
    try {
        $resp = [System.Net.HttpWebResponse]$req.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $resp = [System.Net.HttpWebResponse]$_.Exception.Response }
        else { throw }
    }
    try {
        $status = [int]$resp.StatusCode
        $location = $null
        try { $location = $resp.Headers['Location'] } catch {}
        $content = ''
        $stream = $resp.GetResponseStream()
        if ($stream) {
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            $content = $reader.ReadToEnd()
            $reader.Close()
        }
        [pscustomobject]@{
            Status   = $status
            Location = $location
            Content  = $content
            FinalUrl = $resp.ResponseUri.AbsoluteUri
        }
    } finally {
        if ($resp) { $resp.Close() }
    }
}

# 取 WLAN 网卡当前 IP / MAC；未连接或无 IP 返回 $null
# 优先用 .NET NetworkInterface（毫秒级，冷启动也快），失败再退回 CIM
function Get-WlanLocal {
    try {
        $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
        foreach ($nic in $nics) {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($nic.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) { continue }
            $ipv4 = ''
            foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
                $addr = [string]$ua.Address.IPAddressToString
                if ($ua.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $addr -notlike '169.254.*') { $ipv4 = $addr; break }
            }
            if (-not $ipv4) { continue }
            $mac = ([string]$nic.GetPhysicalAddress().ToString()).ToLower()
            if ($mac.Length -eq 12) { $mac = ($mac -replace '(..)(?!$)', '$1:') }
            return [pscustomobject]@{ IP = $ipv4; MAC = $mac; Alias = [string]$nic.Name }
        }
    } catch {}
    # 兜底：CIM / 网卡枚举（少部分机器网卡类型识别不出时用）
    $alias = [string]$script:cfg.wlanInterface
    $ad = $null
    try { $ad = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue } catch {}
    if (-not $ad) {
        try {
            $ad = Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match '(?i)Wi-?Fi|Wireless|WLAN' } |
                Select-Object -First 1
        } catch {}
    }
    if (-not $ad) { return $null }
    $ip = ''
    try {
        $ipObj = Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Select-Object -First 1
        if ($ipObj) { $ip = [string]$ipObj.IPAddress }
    } catch {}
    if (-not $ip) { return $null }
    $mac = ''
    if ($ad.MacAddress) { $mac = ($ad.MacAddress -replace '-', ':').ToLower() }
    [pscustomobject]@{ IP = $ip; MAC = $mac; Alias = [string]$ad.Name }
}

# 解析页面里所有「有 name 且未 disabled」的 input  返回 OrderedDictionary
function Get-HtmlInputs {
    param([string]$Html)
    $result = [ordered]@{}
    if (-not $Html) { return ,$result }
    foreach ($m in [regex]::Matches($Html, '(?is)<input\b[^>]*>')) {
        $tag = $m.Value
        if ($tag -match '(?i)\sdisabled(\s|=|>|/)') { continue }
        $n = [regex]::Match($tag, '(?i)\bname\s*=\s*"([^"]*)"')
        if (-not $n.Success) { $n = [regex]::Match($tag, "(?i)\bname\s*=\s*'([^']*)'") }
        if (-not $n.Success) { continue }
        $v = [regex]::Match($tag, '(?i)\bvalue\s*=\s*"([^"]*)"')
        if (-not $v.Success) { $v = [regex]::Match($tag, "(?i)\bvalue\s*=\s*'([^']*)'") }
        $val = ''
        if ($v.Success) { $val = $v.Groups[1].Value }
        $result[$n.Groups[1].Value] = $val
    }
    return ,$result
}

# 取指定 id 的 input 的 value 属性（即使 disabled 也取）
function Get-InputValue {
    param([string]$Html, [string]$Id)
    if (-not $Html) { return '' }
    $m = [regex]::Match($Html, '(?is)<input\b[^>]*\bid\s*=\s*"' + [regex]::Escape($Id) + '"[^>]*>')
    if (-not $m.Success) { return '' }
    $v = [regex]::Match($m.Value, '(?is)\bvalue\s*=\s*"([^"]*)"')
    if ($v.Success) { return $v.Groups[1].Value }
    return ''
}

function ConvertTo-FormBody {
    param($Fields)
    $parts = foreach ($k in $Fields.Keys) {
        '{0}={1}' -f [System.Uri]::EscapeDataString([string]$k), [System.Uri]::EscapeDataString([string]$Fields[$k])
    }
    return ($parts -join '&')
}

function Extract-PortalError {
    param([string]$Html)
    if (-not $Html) { return '' }
    $m = [regex]::Match($Html, "(?is)var\s+s\s*=\s*'(.*?)';")
    if ($m.Success) {
        $s = [regex]::Replace($m.Groups[1].Value, '<[^>]+>', '')
        $s = [System.Net.WebUtility]::HtmlDecode($s).Trim()
        if ($s) { return $s }
    }
    $m = [regex]::Match($Html, '(?is)errorMsg=([^&"''<>]{1,100})')
    if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value).Trim() }
    return ''
}

# 查门户状态：Online / Offline / Unreachable / Unknown
function Get-PortalState {
    param($Cookies, [int]$TimeoutSec = 8)
    $statusUrl = 'http://' + $script:cfg.portalHost + '/webdisconnweb.do?wlanacname=' + [System.Uri]::EscapeDataString([string]$script:cfg.wlanacname)
    try {
        $r = Invoke-Http -Url $statusUrl -NoRedirect -Cookies $Cookies -TimeoutSec $TimeoutSec
    } catch {
        return [pscustomobject]@{ State = 'Unreachable'; LoginUrl = $null; Error = $_.Exception.Message }
    }
    $loc = $null
    if ($r.Status -ge 300 -and $r.Status -lt 400 -and $r.Location) {
        $loc = Resolve-PortalUrl -Base $statusUrl -Location $r.Location
    }
    if ($loc) {
        if ($loc -match '(?i)act=LOGINSUCC') { return [pscustomobject]@{ State = 'Online'; LoginUrl = $null } }
        if ($loc -match '(?i)/webauth\.do') { return [pscustomobject]@{ State = 'Offline'; LoginUrl = $loc } }
        if ($loc -match '(?i)index_auth\.jsp') {
            $page = $null
            try { $page = Invoke-Http -Url $loc -Cookies $Cookies -TimeoutSec $TimeoutSec } catch {}
            if ($page -and $page.Content) {
                $c = $page.Content
                if ($c -match "'LOGINSUCC'\s*===\s*'LOGINSUCC'") { return [pscustomobject]@{ State = 'Online'; LoginUrl = $null } }
                $m = [regex]::Match($c, "(?i)location\.href\s*=\s*'/webauth\.do\?([^']*)'")
                if ($m.Success -and $m.Groups[1].Value -match '^wlan') {
                    return [pscustomobject]@{ State = 'Offline'; LoginUrl = ('http://' + $script:cfg.portalHost + '/webauth.do?' + $m.Groups[1].Value) }
                }
                if ($c -match 'id="goLoginForm"') { return [pscustomobject]@{ State = 'Offline'; LoginUrl = $null } }
            }
            return [pscustomobject]@{ State = 'Offline'; LoginUrl = $null }
        }
        return [pscustomobject]@{ State = 'Unknown'; LoginUrl = $loc }
    }
    if ($r.Status -eq 200 -and $r.Content) {
        if ($r.Content -match 'id="connUserId"|id="auth_success"') { return [pscustomobject]@{ State = 'Online'; LoginUrl = $null } }
        if ($r.Content -match 'id="goLoginForm"') { return [pscustomobject]@{ State = 'Offline'; LoginUrl = $null } }
        return [pscustomobject]@{ State = 'Unknown'; LoginUrl = $null }
    }
    return [pscustomobject]@{ State = 'Unknown'; LoginUrl = $null; Error = "HTTP $($r.Status)" }
}

# 通过网关（captive portal 302）拿带完整参数的登录页地址；已在线返回 __ONLINE__
function Find-GatewayLoginUrl {
    foreach ($probe in @($script:cfg.gatewayProbes)) {
        try { $g = Invoke-Http -Url $probe -NoRedirect -TimeoutSec 6 } catch { continue }
        if ($g.Location) {
            $loc = Resolve-PortalUrl -Base $probe -Location $g.Location
            if ($loc -match '(?i)/webauth\.do') { return $loc }
            if ($loc -match '(?i)act=LOGINSUCC') { return '__ONLINE__' }
        }
        if ($g.Content) {
            $m = [regex]::Match($g.Content, '(?i)(?:location\.href\s*=\s*[''"]?|url=)(https?://[^\s''"<>]*/webauth\.do[^\s''"<>]*)')
            if ($m.Success) { return $m.Groups[1].Value }
        }
    }
    return $null
}

function Build-LoginUrl {
    param($Wlan)
    $ip = ''
    $mac = ''
    if ($Wlan) { $ip = $Wlan.IP; $mac = $Wlan.MAC }
    $url = [System.Uri]::EscapeDataString('http://www.msftconnecttest.com/redirect')
    return ('http://' + $script:cfg.portalHost + '/webauth.do?wlanacip=' + $script:cfg.wlanacip +
        '&wlanacname=' + [System.Uri]::EscapeDataString([string]$script:cfg.wlanacname) +
        '&wlanuserip=' + $ip + '&mac=' + $mac + '&vlan=0&url=' + $url)
}

# 补全登录页 URL 缺失的参数
function Complete-LoginUrl {
    param([string]$Url, $Wlan)
    if (-not $Url) { return $Url }
    $add = New-Object System.Collections.Generic.List[string]
    if ($Url -notmatch '(?i)[?&]wlanacip=') { $add.Add('wlanacip=' + $script:cfg.wlanacip) }
    if ($Url -notmatch '(?i)[?&]wlanacname=') { $add.Add('wlanacname=' + [System.Uri]::EscapeDataString([string]$script:cfg.wlanacname)) }
    if ($Url -notmatch '(?i)[?&]wlanuserip=' -and $Wlan) { $add.Add('wlanuserip=' + $Wlan.IP) }
    if ($Url -notmatch '(?i)[?&]mac=' -and $Wlan) { $add.Add('mac=' + $Wlan.MAC) }
    if ($Url -notmatch '(?i)[?&]vlan=') { $add.Add('vlan=0') }
    if ($Url -notmatch '(?i)[?&]url=') { $add.Add('url=' + [System.Uri]::EscapeDataString('http://www.msftconnecttest.com/redirect')) }
    if ($add.Count -gt 0) {
        $sep = '?'
        if ($Url -match '\?') { $sep = '&' }
        $Url = $Url + $sep + ($add -join '&')
    }
    return $Url
}

# 真实互联网连通性：只看公网探测，不信任门户状态。
# 用于识别"门户显示在线、但网关实际还在拦截"的残留会话（v1.2.3 修复）。
function Test-InternetReachable {
    foreach ($u in @('http://connect.rom.miui.com/generate_204', 'http://www.msftconnecttest.com/connecttest.txt')) {
        try { $r = Invoke-Http -Url $u -NoRedirect -TimeoutSec 5 } catch { continue }
        if ($r.Status -eq 204 -and $u -match 'generate_204') { return $true }
        if ($r.Status -eq 200 -and $r.Content -match '(?i)Microsoft Connect Test') { return $true }
    }
    return $false
}

# 确认在线：优先真实联网，其次门户状态
function Test-Online {
    if (Test-InternetReachable) { return $true }
    $st = Get-PortalState
    return ($st.State -eq 'Online')
}

# 现场向认证服务器验证一次账号密码（安装 GUI / 诊断用；错误密码会返回 Ok=$false）
function Test-CampusPassword {
    param([string]$UserId, [string]$Password, [int]$TimeoutSec = 10)
    try {
        $w = Get-WlanLocal
        $u = Build-LoginUrl -Wlan $w
        $jar = New-Object System.Net.CookieContainer
        $page = Invoke-Http -Url $u -Cookies $jar -TimeoutSec $TimeoutSec
        if ($page.Status -ne 200) { return @{ Ok = $true; Msg = "跳过校验（登录页 HTTP $($page.Status)）" } }
        $f = Get-HtmlInputs -Html $page.Content
        if ($f.Count -lt 3) { return @{ Ok = $true; Msg = '跳过校验（登录页解析失败）' } }
        $f['userId'] = $UserId
        $f['passwd'] = $Password
        $f['isRemind'] = '1'
        $f['remInfo'] = 'on'
        $f['desc_lb'] = 'on'
        $urlPam = Get-InputValue -Html $page.Content -Id 'urlParameter'
        if (-not $urlPam) { $urlPam = ([System.Uri]$u).Query.TrimStart('?') }
        $action = 'http://' + $script:cfg.portalHost + '/webauth.do?' + $urlPam
        $resp = Invoke-Http -Url $action -Method 'POST' -Body (ConvertTo-FormBody -Fields $f) -Cookies $jar -Referer $u -TimeoutSec ($TimeoutSec + 5)
        $err = Extract-PortalError -Html $resp.Content
        if ($err) {
            if ($err -match '密码错误|密码不正确|密码有误|账号或密码|用户名或密码|账号不存在|用户不存在') {
                return @{ Ok = $false; Msg = $err }
            }
            return @{ Ok = $true; Msg = ('认证服务器提示: ' + $err + '（视为通过）') }
        }
        if ($resp.Content -match 'id="connUserId"|id="auth_success"') { return @{ Ok = $true; Msg = '认证成功' } }
        return @{ Ok = $true; Msg = '请求已提交（未返回错误）' }
    } catch {
        return @{ Ok = $true; Msg = ('跳过校验（网络错误: ' + $_.Exception.Message + '）') }
    }
}
