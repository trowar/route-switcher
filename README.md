# 路由切换器 (Route Switcher)

macOS 图形界面工具：按**应用**选择网络走 **VPN** 还是 **本地网关**，支持全局默认与进程级覆盖。

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## 功能

- **应用级分流**：Chrome 等多窗口 / Helper 合并为一条规则，设一次即可  
- **全局默认**：未单独配置的应用可默认走 VPN 或本地  
- **进程覆盖**：为个别 App 指定「走 VPN / 走本地 / 跟随默认」  
- **一次授权**：首次输入管理员密码后启动提权助手，本会话内改规则不再反复要密码  
- **规则持久化**：按 Bundle ID 保存，重启后仍有效  

## 下载

### 预编译应用

- 仓库目录：`dist/路由切换器.app`（及 zip）
- Release 下载：[RouteSwitcher.app.zip](https://github.com/trowar/route-switcher/releases/latest/download/RouteSwitcher.app.zip)
- 全部版本：[Releases](https://github.com/trowar/route-switcher/releases)
- **版本号**：`年-月日`（如 `2026-07-14`），显示在窗口左下角；启动时自动对照 GitHub 最新 Release，有更新会提示下载替换

**打开方式：**

1. 解压 / 复制 `路由切换器.app` 到「应用程序」或桌面  
2. 首次打开若提示未签名：系统设置 → 隐私与安全性 → 仍要打开  
3. 或在终端执行：

```bash
xattr -cr "/path/to/路由切换器.app"
open "/path/to/路由切换器.app"
```

### 从源码构建

**环境：** macOS 14+，Swift 6 / Command Line Tools 或 Xcode  

```bash
git clone https://github.com/trowar/route-switcher.git
cd route-switcher
chmod +x Scripts/build-app.sh
./Scripts/build-app.sh
open ".build/路由切换器.app"
```

## 使用说明

1. **连接 VPN**（如 OpenVPN / WireGuard 等）  
2. 打开「路由切换器」  
3. 首次改路由时输入**一次**管理员密码（左侧显示「管理员权限：已授权」）  
4. 在左侧设置 **全局默认**（跟随系统 / 默认走 VPN / 默认走本地）  
5. 需要例外时，选中右侧应用 → **走 VPN** 或 **走本地**  
6. 点 **跟随默认** 可清除该应用的单独规则  

| 优先级 | 说明 |
|--------|------|
| 高 | 应用单独规则 |
| 低 | 全局默认 |
| — | 「跟随系统」表示不强制写主机路由 |

## 工作原理与限制

本工具通过观察应用的远程连接 IP，写入更具体的 **主机路由**（`/sbin/route`），使流量走 VPN 接口/网关或本地网关。

| 能力 | 说明 |
|------|------|
| 需要 | 管理员权限（改路由表）；VPN 连接后才能「走 VPN」 |
| 生效方式 | 主机路由优先于默认路由 |
| 限制 | 同一目标 IP 被多个策略争用时只能有一种 |
| 限制 | 新连接的首包可能短暂走系统默认，数秒内会纠正 |
| 限制 | 主要覆盖 IPv4 TCP 已建立连接 |
| 非目标 | 不是内核级 Network Extension / 企业 Per-App VPN |

企业级零泄漏按 App VPN 请使用 Apple Network Extension 方案。

## 项目结构

```text
route-switcher/
├── Package.swift
├── Sources/                 # Swift 源码
│   ├── main.swift
│   ├── ProcessRouteApp.swift
│   ├── ContentView.swift
│   ├── AppViewModel.swift
│   ├── ProcessMonitor.swift
│   ├── NetworkInterfaceManager.swift
│   ├── RouteEngine.swift
│   ├── PrivilegeSession.swift
│   ├── RootHelper.swift
│   └── ...
├── Scripts/build-app.sh     # 打包 .app
├── Resources/               # 图标等
├── dist/路由切换器.app       # 预编译应用
└── README.md
```

## 安全说明

- 提权助手仅允许执行受校验的 `/sbin/route` 命令  
- 助手通过本机 Unix Socket 通信，退出应用后结束  
- **请勿**将 GitHub Token、密码等提交进仓库  

## 许可

MIT License. 本地自用或按需修改。欢迎 Issue / PR。

## 作者

[@trowar](https://github.com/trowar)
