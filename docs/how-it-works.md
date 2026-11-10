# 工作原理与协议细节

> 本文档给想了解实现、或想适配其他学校的同学看。

## 一、校园网门户是怎么认证的

郑航的校园网（`ZUA-Student`）使用 `bossWebV1.0.1` 网页认证系统，门户地址
`http://202.196.169.166`。流程如下：

### 1. 网关重定向

连上 `ZUA-Student`（开放 Wi-Fi，无密码）后，设备会通过 DHCP 拿到 `10.x.x.x` 的地址；
此时任何 HTTP 访问都会被网关 302 重定向到认证页：

```
http://202.196.169.166/webauth.do?wlanacip=10.0.1.10&wlanacname=ZZHK-ZAX-BRAS
    &wlanuserip=<本机IP>&mac=<本机MAC>&vlan=0&url=<原访问地址>
```

### 2. 登录表单

认证页里有表单 `#goLoginForm`（method=post），关键字段：

| 字段 | 说明 |
|---|---|
| `userId` | 学号 |
| `passwd` | 密码（**明文提交**，无加密、无验证码） |
| `isRemind` / `remInfo` | “记住密码”复选框 |
| `desc_lb` | 用户协议复选框 |
| 其它 hidden 字段 | `scheme / serverIp / hostIp / pageid / templatetype / url / distoken ...` 照抄页面即可 |

提交地址为 `/webauth.do?<urlParameter>`，其中 `urlParameter` 就是页面里
`#urlParameter` 隐藏输入框的值（即上面那串查询参数）。

### 3. 认证状态查询

```
GET /webdisconnweb.do?wlanacname=ZZHK-ZAX-BRAS
```

- 已在线 → `302` 到 `index_auth.jsp...act=LOGINSUCC`
- 未在线 → 重定向回登录页（或 `index_auth.jsp`，其内联 JS 再跳到 `/webauth.do?...`）

### 4. 主动下线（仅测试用）

`POST /webdisconn.do?<urlParameter>`（页面上“下线”按钮的行为）。

## 二、本工具的实现

```
开机
 └─ 计划任务 CampusNet-AutoLogin（SYSTEM，AtStartup / AtLogOn）
      └─ powershell.exe -File C:\CampusNet\login.ps1
           ├─ 等 Wi-Fi 拿到 IP（.NET 网络接口 API，毫秒级）
           ├─ GET webdisconnweb.do 判断是否已认证
           ├─ 未认证：
           │    ├─ 优先用状态接口返回的登录页地址
           │    ├─ 否则请求 msftconnecttest/generate_204 抓网关 302 的 Location
           │    ├─ 否则用本机 IP/MAC + config 拼出登录页地址
           │    ├─ GET 登录页 → 解析全部表单字段（跳过 disabled）
           │    ├─ 填入 userId / passwd / isRemind / remInfo / desc_lb
           │    └─ POST /webauth.do?<urlParameter>
           ├─ 复查状态 → 记日志“登录成功”
           └─ 循环：每 6 秒复查，掉线自动重登；连续失败指数退避（4s→15s→60s→…→10min）
```

关键设计点：

- **SYSTEM 计划任务**：开机时即启动，早于用户登录/解锁；不依赖桌面会话。
- **常驻循环**：不只是开机，全天掉线（会话到期、IP 变化、休眠唤醒）都会自动重连。
- **动态参数**：`wlanuserip` / `mac` / `wlanacname` 等每次开机可能不同，所以不写死，从网关 302 或本机网卡现场取值。
- **密码存储**：Windows DPAPI `LocalMachine` 作用域加密（SYSTEM 才能解密给守护进程用）；文件 ACL 限定 SYSTEM/Administrators/当前用户。
- **失败退避**：连续失败按 4s→15s→60s→120s→300s→600s 退避，避免触发账号锁定。

## 三、目录与配置

运行时目录 `C:\CampusNet`：

| 文件 | 说明 |
|---|---|
| `config.json` | 门户地址与参数（换学校时改这里） |
| `cred.dat` | DPAPI 加密的账号密码 |
| `login.ps1` | 守护脚本 |
| `portal-lib.ps1` | 门户协议函数库 |
| `test.ps1` | 断网回环测试 |
| `login.log` | 运行日志（UTF-8） |
| `pause.flag` | 存在时暂停自动登录（GUI“暂停”按钮创建） |

`config.json` 默认值：

```json
{
  "portalHost": "202.196.169.166",
  "wlanacname": "ZZHK-ZAX-BRAS",
  "wlanacip": "10.0.1.10",
  "wlanInterface": "WLAN",
  "onlineCheckSeconds": 6,
  "gatewayProbes": [
    "http://www.msftconnecttest.com/redirect",
    "http://connect.rom.miui.com/generate_204"
  ]
}
```

## 四、适配其他学校

如果你们学校的校园网也是“网页认证”：

1. 用浏览器 F12 → 网络，抓一次登录请求，拿到登录 URL、表单字段、密码是否加密；
2. 改 `portal-lib.ps1` 里的：
   - `Build-LoginUrl`（登录页地址与参数）
   - `Get-PortalState`（如何判断在线）
   - `Try-Login` 的字段填充（`userId`/`passwd` 字段名可能不同）
3. 改 `config.json` 的门户地址。
4. 如果密码是 JS 加密的（例如深澜 `info` 字段），需要复刻加密算法，或改用无头浏览器方案。

## 五、已知限制

- 门户升级/改版会导致脚本失效，需要按新接口调整。
- 部分学校在锁屏状态下不连接 Wi-Fi（取决于网卡驱动/组策略），此时只能“解锁后立刻登录”。
- 密码明文提交是学校门户的设计，本工具只是重放浏览器本就会发的内容；请在可信网络使用。
