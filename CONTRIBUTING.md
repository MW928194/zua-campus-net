# 反馈与贡献

## 遇到问题怎么反馈

提 Issue 时请附上：

1. **现象**：做了什么操作、期望是什么、实际发生了什么（最好有截图）。
2. **日志**：点界面上的「复制日志」按钮，把内容贴上来（日志里不含明文密码）。
3. **环境**：Windows 版本（如 Win11 23H2）、是否连接 ZUA-Student、是首次安装还是更新。
4. 如果涉及开机自动登录，说明「开机后多久解锁」「日志里登录成功的时间」。

> 注意：请不要在 Issue 里贴 `cred.dat`、明文密码、学号等个人信息。

## 本地开发 / 修改

```
src/app/CampusNet-GUI.ps1     图形界面
src/runtime/portal-lib.ps1    门户协议（状态查询/登录表单/密码校验）
src/runtime/install-lib.ps1   安装/卸载/暂停/状态
src/runtime/login.ps1         常驻守护（开机自动登录 + 掉线重连）
src/runtime/test.ps1          真实断网回环测试
```

改动后的自检：

```powershell
# 语法 + 界面构造 + 状态读取（不登录、不断网）
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\src\app\CampusNet-GUI.ps1 -SelfTest
```

注意事项：

- 所有 `.ps1` 必须保存为 **UTF-8 with BOM**（Windows PowerShell 5.1 否则会把中文按 ANSI 解析报错）。
- PowerShell 双引号字符串里**不要**用中文弯引号 `“ ”`（会被当成字符串定界符），用 `「」`。
- 安装器会注册 SYSTEM 计划任务，测试安装/卸载需要管理员权限。
- 改完请在真实校园网环境跑一次「真实断网测试」。

## 适配其他学校

见 [docs/how-it-works.md](docs/how-it-works.md) 第四节。
