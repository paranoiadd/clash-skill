# clash-skill

> 给你的 AI 助手一套可控的 Clash 代理能力：**访问国外资源时自动用上节点，国内流量保持直连。**

![Platform](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows&logoColor=white) ![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white) ![Clash](https://img.shields.io/badge/Clash-for%20Windows-4B5563) ![License](https://img.shields.io/badge/license-MIT-2ea44f)

## 解决什么问题

AI 助手帮你 `git clone`、`pip install`、拉模型权重时，经常卡死在对国外服务的请求上。
但如果手动打开全局代理，百度、B站、微信又全部被拉去国外节点绕一圈再回来。

这个 skill 让助手**按需**操作代理：先诊断，再决定走哪条路，用完还原，不留脏状态。

## 三种生效方式

| 场景 | 手段 | 影响范围 |
| --- | --- | --- |
| 单个命令（curl / git / pip / npm） | `run "命令"` | **只有这一条命令**，零污染 |
| GUI 程序（浏览器 / IDE / 下载器） | `sysproxy on`，用完 `off` | 所有读系统代理的程序，国内仍直连 |
| 长期常开 | 在 Clash 界面自己开 | 由你手动管理 |

## 快速开始

**前置要求**

- Windows + PowerShell 5.1+
- [Clash for Windows](https://github.com/Fndroid/clash_for_windows_pkg)，已导入订阅
- 订阅需**带分流规则**（`GEOIP,CN,DIRECT` + `MATCH,节点`），否则 `rule` 模式无意义

**一行安装（推荐）**

```bash
npx skills add paranoiadd/clash-skill          # 当前项目
npx skills add paranoiadd/clash-skill -g       # 全局，所有项目可用
```

走 [vercel-labs/skills](https://github.com/vercel-labs/skills) 生态，Claude Code / Cursor / Codex / OpenCode 等通用。

**备选：自带安装器**

```bash
npx github:paranoiadd/clash-skill
```

会探测本机 Clash 并写出 `clash-config.json`，同时装进检测到的 skills 目录
（`~/.workbuddy/skills`、`~/.claude/skills`）。

```bash
npx github:paranoiadd/clash-skill --dir ~/.workbuddy/skills   # 指定目录
npx github:paranoiadd/clash-skill --force                     # 覆盖已有配置
```

**零配置**

不需要手填 secret。脚本运行时会自己找：

| 需要的值 | 来源 |
| --- | --- |
| `ApiSecret` / 控制端口 / 混合端口 | `~/.config/clash/config.yaml`（Clash 每次启动都会写） |
| `Clash for Windows.exe` | 运行中的进程 → 卸载注册表 `InstallLocation` → 常见安装目录 |

想固定某些值再手写 `clash-config.json`（字段见 `clash-config.example.json`），
它会覆盖自动探测结果。

**手动安装**（没有 node 时）

```bash
git clone https://github.com/paranoiadd/clash-skill
cp -r clash-skill ~/.workbuddy/skills/clash
```

控制端口每次启动都会变，脚本会自动重读 `config.yaml`，不用你管。

## 命令

```powershell
& .\scripts\clashctl.ps1 status      # 进程 / API / mode / 系统代理 / 节点
& .\scripts\clashctl.ps1 auto        # 测直连 vs 代理，给出 verdict
& .\scripts\clashctl.ps1 mode rule   # 切分流模式（前提）
& .\scripts\clashctl.ps1 run "git clone https://github.com/user/repo"
& .\scripts\clashctl.ps1 sysproxy on|off
& .\scripts\clashctl.ps1 nodes       # 列出代理组
& .\scripts\clashctl.ps1 delay '节点名'
& .\scripts\clashctl.ps1 switch '组名' '节点名'
& .\scripts\clashctl.ps1 start|stop|restart
```

加 `-AsJson` 输出结构化结果。

## 工作原理

只有两件事：

1. **分流交给 Clash 自己**。`mode=rule` 下由规则决定：`GEOIP,CN` 直连、其余走节点。skill 不按域名手工指定。
2. **决定程序怎么"用上"代理**。命令行用环境变量注入（只影响那一条命令），GUI 程序才临时开系统代理。

实测（`rule` 模式）：google 0.37s、youtube 1.42s 走节点；百度 0.25s、B站 0.35s 直连。

## 安全设计

- **secret 不进仓库**：`clash-config.json` 已被 `.gitignore` 忽略，仓库里只有 example
- **只关自己开的**：`start` 会写标记文件，`stop` 只关闭带标记的实例，绝不碰你手动启动的 Clash
- **系统代理可还原**：`sysproxy on` 先把原值备份，`off` 时精确恢复，不留脏状态
- **单命令零污染**：`run` 结束即还原环境变量

## License

MIT
