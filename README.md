# OpenCode Pocket Kit

<div align="center">

![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)
![Platform](https://img.shields.io/badge/platform-Windows-0078D4.svg)
![PowerShell](https://img.shields.io/badge/powershell-5.1+-5391FE.svg)
![OpenCode](https://img.shields.io/badge/OpenCode-portable-111827.svg)
![OMO](https://img.shields.io/badge/OMO-oh--my--openagent-7C3AED.svg)
![CLI](https://img.shields.io/badge/CLI-opkcode-0F766E.svg)
![License](https://img.shields.io/badge/license-MIT-brightgreen.svg)

一个面向 Windows 的 OpenCode 便携运行包。它把 OpenCode、Oh-My-OpenAgent、TUI 插件、Comment Checker、可选 Skills、配置目录、项目目录和加密密钥库集中在同一个文件夹中，适合放在 U 盘、移动硬盘或任意工作目录中使用。

[快速开始](./docs/快速开始.md) | [命令行启动](./docs/命令行启动.md) | [目录结构](./docs/目录结构.md) | [组件清单](./docs/组件清单.md) | [代理配置](./docs/代理配置.md) | [密钥安全](./docs/密钥安全.md) | [配置说明](./docs/配置说明.md) | [诊断排错](./docs/诊断排错.md) | [发布维护](./docs/发布维护.md)

</div>

---

## 项目定位

OpenCode Pocket Kit 的目标是提供一套可以直接解压、安装、启动、迁移的 OpenCode 便携环境。它尽量减少对系统目录的写入，把运行时需要的配置、依赖、缓存、日志和项目文件都放在包目录下。

适合这些场景：

- 在不同 Windows 电脑之间移动 OpenCode 环境。
- 把 API Key 加密存放在便携目录中。
- 使用 Oh-My-OpenAgent 的 agent、TUI 和 comment-checker 能力。
- 统一管理 GitHub、npm、Git 下载代理。
- 在比赛、机房、实验室或临时电脑上快速搭建 OpenCode 环境。

## 快速开始

```bat
安装.cmd
编辑密钥.cmd
启动.cmd
```

也可以注册独立命令，在任意终端中进入项目目录后运行：

```bat
注册命令.cmd
cd D:\Code\my-project
opkcode
```

首次使用建议：

1. 解压本项目到任意目录，例如 `D:\Tools\opencode-pocket-kit`。
2. 如果需要代理，先编辑根目录 `proxy.conf`。默认代理关闭，端口为空。
3. 双击 `安装.cmd` 安装 OpenCode、OMO、TUI、Comment Checker 和可选 Skills。
4. 双击 `编辑密钥.cmd` 输入 API Key，生成加密密钥库。
5. 双击 `启动.cmd` 启动 OpenCode。
6. 出现问题时运行 `诊断.cmd`。

详细说明见 [快速开始](./docs/快速开始.md)。

## 文档导航

| 文档 | 说明 |
|---|---|
| [快速开始](./docs/快速开始.md) | 从解压到运行的完整流程 |
| [命令行启动](./docs/命令行启动.md) | 注册 `opkcode` 命令，并从当前终端目录启动 OpenCode |
| [目录结构](./docs/目录结构.md) | 根目录、配置目录、缓存目录和运行目录说明 |
| [组件清单](./docs/组件清单.md) | 安装的插件、依赖、Skills 和来源说明 |
| [代理配置](./docs/代理配置.md) | `proxy.conf` 字段、常见代理端口和排错方式 |
| [密钥安全](./docs/密钥安全.md) | `vault/secrets.env.enc` 的加密逻辑和使用方式 |
| [配置说明](./docs/配置说明.md) | OpenCode、OMO、TUI、项目级配置说明 |
| [诊断排错](./docs/诊断排错.md) | 常见问题、日志位置和诊断步骤 |
| [发布维护](./docs/发布维护.md) | 编码规范、打包规则和 GitHub 发布建议 |

## 根目录入口脚本

| 文件 | 作用 |
|---|---|
| `安装.cmd` | 安装 OpenCode 本体、Oh-My-OpenAgent、TUI 插件、Comment Checker，并下载可选 Skills |
| `启动.cmd` | 设置便携运行环境，临时解密密钥库，并启动 `bin/opencode.exe` |
| `注册命令.cmd` | 注册命令行别名，默认命令名为 `opkcode` |
| `注销命令.cmd` | 从当前用户 Path 中移除命令行别名目录 |
| `编辑密钥.cmd` | 创建或覆盖 `vault/secrets.env.enc` 加密密钥库 |
| `更新.cmd` | 更新 OpenCode、OMO、依赖和可选组件 |
| `诊断.cmd` | 检查环境变量、工具链、配置、OMO 和 Comment Checker |

## 默认代理状态

`proxy.conf` 默认不开启代理：

```ini
PROXY_ENABLED=0
PROXY_PORT=
```

需要使用 Clash、Mihomo、v2rayN 等本地代理时，再填写 HTTP 代理端口：

```ini
PROXY_ENABLED=1
PROXY_HOST=127.0.0.1
PROXY_PORT=7897
PROXY_SCHEME=http
```

## 默认安装内容

默认安装内容包括：

- OpenCode 本体：`opencode-ai`
- Oh-My-OpenAgent 插件：`oh-my-openagent`
- OpenCode 插件配置：`plugin: ["oh-my-openagent"]`
- TUI 插件配置：`plugin: ["oh-my-openagent/tui"]`
- Comment Checker：`@code-yeongyu/comment-checker`
- Superpowers 插件和 Skills
- Anthropic 示例 Skills
- Tavily Skills
- Agent Browser Skill
- Refactor Skill
- UI/UX Pro Max Skill
- 本地 tmux Skill

完整清单见 [组件清单](./docs/组件清单.md)。

## 安全说明

`编辑密钥.cmd` 会把你输入的 `KEY=VALUE` 内容加密保存到：

```text
vault\secrets.env.enc
```

`启动.cmd` 只在当前 PowerShell 进程和 OpenCode 子进程中临时注入环境变量，不写入系统环境变量。

详细说明见 [密钥安全](./docs/密钥安全.md)。

## 许可证

本便携包脚本采用 MIT License。OpenCode、Oh-My-OpenAgent、Superpowers、Tavily Skills、Anthropic Skills 以及其他上游组件遵循各自项目许可证。
