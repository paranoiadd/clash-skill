---
name: clash
description: "Control the local Clash for Windows proxy so that only traffic which needs it goes through a node. Covers: starting/stopping Clash, switching to split-routing (rule) mode, toggling the Windows system proxy for GUI apps, running a single command through the proxy, checking/choosing nodes, and diagnosing why a given site fails. Use whenever downloading overseas resources, opening foreign sites, or when a command times out against GitHub / raw.githubusercontent / npm / pip / docker / huggingface / google / youtube."
description_zh: "按需使用本机 Clash 代理：只让需要的程序走节点，国内流量保持直连。支持启停、分流模式、系统代理、单命令注入、节点切换与故障诊断"
description_en: "Route only the traffic that needs a proxy through local Clash, keep domestic traffic direct"
version: 2.2.0
display_name: "clash"
display_name_en: "clash"
visibility: "public"
---

# Clash 代理控制（按需分流）

目标：让需要出国的流量走节点，国内流量保持直连。这靠 Clash 自己的规则分流实现，不需要按域名手工指定。

## 前提：`mode` 必须是 `rule`

| 模式 | 行为 |
|---|---|
| `rule` | 按规则分流：国内直连、其余走节点 ✅ |
| `global` | 所有流量都走同一节点（百度、B站也绕道国外）❌ |
| `direct` | 全部直连，代理形同关闭（仅应急） |

本机订阅含 523 条规则（`GEOIP,CN,DIRECT` + `MATCH,节点`），`rule` 模式实测：google 0.37s、youtube 1.42s（走节点），百度 0.25s、B站 0.35s（直连）。
**`start` 会自动确保 `mode=rule`**；若发现是 `global`，先 `mode rule`。

## 本机环境

| 项 | 值 |
|---|---|
| GUI 路径 | 自动探测（进程 → 卸载注册表 → 常见目录），`clash-config.json` → `GuiExe` 可覆盖 |
| 进程名 | `Clash for Windows`（GUI）／ `clash-win64`（核心），配置可改 |
| 混合端口 | 自动读 `~/.config/clash/config.yaml`（通常 `7890`） |
| 控制 API | 同上；端口每次启动都变，由脚本自动处理 |

**零配置**：`clash-config.json` 是可选的。缺省时脚本自己从 `~/.config/clash/config.yaml`
读 secret 与端口、自己找 `Clash for Windows.exe`，`status` 的 `config_source` 会说明当前来源
（`auto-detected` / `clash-config.json`）。有该文件时只覆盖其中填了值的字段，secret 不要外传。

## 三种让程序用上代理的方式

| 场景 | 手段 | 影响范围 |
|---|---|---|
| 单个命令（curl/git/pip/npm/wget） | `run "命令"` | 只有这一条命令，零污染 |
| GUI 程序（浏览器/IDE/下载器） | `sysproxy on`，用完 `off` | 所有读系统代理的程序，国内仍直连 |
| 长期常开 | 在 Clash 界面自己开 | 由用户手动管理 |

**优先用 `run`**，只有 GUI 程序才值得动系统代理。

## 动作

脚本：本 skill 目录下的 `scripts/clashctl.ps1`，下文记作 `$s`：

```powershell
$s = '<本 SKILL.md 所在目录>/scripts/clashctl.ps1'
```

```powershell
& $s status                        # 进程/API/mode/系统代理/节点
& $s auto [url]                    # 测直连 vs 代理，给 verdict
& $s mode rule                     # 切分流模式
& $s sysproxy on|off               # 系统代理开关（自动备份并还原原值）
& $s run "curl -sS https://x.com"  # 用代理跑一条命令
& $s nodes / delay <节点> / switch <组> <节点>
& $s start / stop / restart
```

- 加 `-AsJson` 输出 JSON
- `run` 的整条命令**必须用引号包住**（脚本无法转发以 `-` 开头的参数）
- 节点名含中文/emoji/空格，传参用**单引号**：`delay '🇯🇵 日本1 (移动>联通>电信)'`

## 决策流程

**需要访问国外资源时：**

1. `status`：`core_running=False` → `start`；`mode` 不是 `rule` → `mode rule`
2. 按受众选手段：
   - 命令行工具 → `run "<命令>"`
   - GUI 程序 → `sysproxy on`，任务结束 `sysproxy off`
3. 仍失败 → `nodes` + `delay` 找快节点，`switch` 换掉，最多 2~3 次；
   还不行就如实说"节点侧问题"，不要无限重试

**不需要代理时：** 国内站点、内网、本地服务什么都不做，`rule` 模式自动直连。不要为了保险去开系统代理。

## 收尾

1. `start` 只在 Clash 原本未运行时写标记，`stop` 只关带标记的实例，不会关你手动开的
2. `sysproxy on` 会把原值存到 `~/.config/clash/.agent-sysproxy`，`off` 时精确还原；**agent 开的必须关掉**
3. `run` 无需收尾（环境变量自动恢复）
4. 汇报时说清：mode 是什么、走了哪条路、系统代理最后是开是关

## 排障

- `direct_ms` 接近 10000 且 `direct_ok=False` = 超时，不是略慢
- 访问仍失败时先看 `mode` 是否 `rule`，再看节点延迟，最后才怀疑 Clash 本身
