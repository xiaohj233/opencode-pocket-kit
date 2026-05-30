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

[快速开始](./docs/快速开始.md) |
[命令行启动](./docs/命令行启动.md) |
[目录结构](./docs/目录结构.md) |
[组件清单](./docs/组件清单.md) |
[代理配置](./docs/代理配置.md) |
[密钥安全](./docs/密钥安全.md) |
[配置说明](./docs/配置说明.md) |
[手动拓展](./docs/手动拓展.md) |
[诊断排错](./docs/诊断排错.md) |
[发布维护](./docs/发布维护.md) |
[参考资料](./docs/参考资料.md)

</div>

---

## 项目定位

OpenCode Pocket Kit 的目标是提供一套可以直接解压、安装、启动、迁移的 OpenCode 便携环境。它尽量减少对系统用户目录的依赖，把运行所需的配置、依赖、缓存、日志、项目文件和密钥库集中在包目录下。

适合这些场景：

- 在不同 Windows 电脑之间移动 OpenCode 环境。
- 在临时电脑、机房电脑或比赛电脑上快速搭建 OpenCode 环境。
- 把 API Key 加密存放在便携目录中，而不是写入系统环境变量。
- 使用 Oh-My-OpenAgent 的 agent、TUI 和 comment-checker 能力。
- 统一配置 GitHub、npm、Git 下载代理。
- 通过 `opkcode` 在任意项目目录中启动 OpenCode。

## 快速开始

### 标准流程

```bat
安装.cmd
编辑密钥.cmd
启动.cmd
```

这三个脚本分别负责：

1. `安装.cmd`：安装 OpenCode、Oh-My-OpenAgent、TUI 插件、Comment Checker 和可选 Skills。
2. `编辑密钥.cmd`：创建 `vault\secrets.env.enc` 加密密钥库。
3. `启动.cmd`：设置便携环境、临时解密密钥库并启动 OpenCode。

详细步骤见 [快速开始](./docs/快速开始.md)。

### 命令行当前目录启动

如果希望像输入普通命令一样使用便携版 OpenCode，可以注册命令行入口：

```bat
注册命令.cmd
```

默认注册命令名为：

```bat
opkcode
```

之后重新打开终端，在任意项目目录中运行：

```bat
cd D:\Code\my-project
opkcode
```

此时 OpenCode 的工作目录就是当前终端所在目录。详细说明见 [命令行启动](./docs/命令行启动.md)。

## 文档导航

| 文档 | 说明 |
|---|---|
| [快速开始](./docs/快速开始.md) | 从解压到启动的完整流程 |
| [命令行启动](./docs/命令行启动.md) | 注册 `opkcode` 命令，并从当前终端目录启动 OpenCode |
| [目录结构](./docs/目录结构.md) | 根目录、配置目录、缓存目录和运行目录说明 |
| [组件清单](./docs/组件清单.md) | 安装的插件、依赖、Skills 和来源说明 |
| [代理配置](./docs/代理配置.md) | `proxy.conf` 字段、常见代理端口和排错方式 |
| [密钥安全](./docs/密钥安全.md) | `vault\secrets.env.enc` 的加密逻辑和使用方式 |
| [配置说明](./docs/配置说明.md) | OpenCode、OMO、TUI、项目级配置说明 |
| [手动拓展](./docs/手动拓展.md) | 手动配置 Tavily、环境变量、Skills 和插件 |
| [诊断排错](./docs/诊断排错.md) | 常见问题、日志位置和诊断步骤 |
| [发布维护](./docs/发布维护.md) | 编码规范、打包规则和 GitHub 发布建议 |
| [参考资料](./docs/参考资料.md) | 相关官方文档和上游项目入口 |

## 根目录入口脚本

| 文件 | 作用 |
|---|---|
| `安装.cmd` | 安装 OpenCode 本体、Oh-My-OpenAgent、TUI 插件、Comment Checker，并下载可选 Skills |
| `启动.cmd` | 设置便携运行环境，临时解密密钥库，并启动 `bin\opencode.exe` |
| `注册命令.cmd` | 注册命令行别名，默认生成 `opkcode` 命令 |
| `注销命令.cmd` | 从当前用户 `Path` 中移除命令行别名目录 |
| `编辑密钥.cmd` | 创建或覆盖 `vault\secrets.env.enc` 加密密钥库 |
| `更新.cmd` | 更新 OpenCode、OMO、依赖和可选组件 |
| `诊断.cmd` | 检查环境变量、工具链、配置、OMO 和 Comment Checker |

这些 `.cmd` 文件是入口脚本。为避免 Windows CMD 解析中文时出现乱码，入口脚本本身保持 ASCII、CRLF、无 BOM；中文输出主要由 `scripts\` 下的 PowerShell 脚本完成。

## 默认代理状态

`proxy.conf` 默认不开启代理，端口为空：

```ini
PROXY_ENABLED=0
PROXY_HOST=127.0.0.1
PROXY_PORT=
PROXY_SCHEME=http
PROXY_URL=
```

如果需要使用 Clash、Mihomo、v2rayN 等本地代理，可以修改为：

```ini
PROXY_ENABLED=1
PROXY_HOST=127.0.0.1
PROXY_PORT=7897
PROXY_SCHEME=http
```

也可以直接填写完整代理地址：

```ini
PROXY_ENABLED=1
PROXY_URL=http://127.0.0.1:7897
```

详细说明见 [代理配置](./docs/代理配置.md)。

## 默认安装内容

默认安装内容包括：

- OpenCode 本体：`opencode-ai`
- Oh-My-OpenAgent：`oh-my-openagent`
- OpenCode 插件项：`plugin: ["oh-my-openagent"]`
- TUI 插件项：`plugin: ["oh-my-openagent/tui"]`
- Comment Checker：`@code-yeongyu/comment-checker`
- Superpowers 插件和 Skills
- Anthropic 示例 Skills
- Tavily Skills
- Agent Browser Skill
- Refactor Skill
- UI/UX Pro Max Skill
- 本地 tmux Skill

完整清单见 [组件清单](./docs/组件清单.md)。

## 密钥和环境变量

`编辑密钥.cmd` 会把你输入的 `KEY=VALUE` 内容加密保存到：

```text
vault\secrets.env.enc
```

示例：

```env
DEEPSEEK_API_KEY=sk-xxxx
OPENROUTER_API_KEY=sk-or-v1-xxxx
TAVILY_API_KEY=tvly-xxxx
```

`启动.cmd` 和 `opkcode` 启动时会检测是否存在密钥库。如果存在，会要求输入密钥库密码；解密成功后，脚本只会在当前 PowerShell 进程和 OpenCode 子进程中临时注入环境变量，不写入系统环境变量。

Tavily 这类工具密钥不需要写入 `opencode.json` 的 provider，只需要放入密钥库，例如：

```env
TAVILY_API_KEY=tvly-xxxx
```

更多说明见 [密钥安全](./docs/密钥安全.md) 和 [手动拓展](./docs/手动拓展.md)。

## 配置文件位置

主要配置文件位于：

```text
config\opencode\
```

常见文件包括：

| 文件 | 作用 |
|---|---|
| `opencode.json` | OpenCode 主配置，默认启用 OMO 插件 |
| `tui.json` | OpenCode TUI 配置，默认启用 OMO TUI 插件 |
| `oh-my-openagent.json` | OMO 官方安装器生成的路由配置 |
| `package.json` | 便携配置目录下的 Node 依赖声明 |
| `node_modules\` | OMO、Comment Checker 和插件依赖 |
| `skills\` | 全局 OpenCode Skills 目录 |
| `plugins\` | OpenCode 插件文件目录 |

项目级配置可以放在项目目录：

```text
项目目录\.opencode\
```

详细说明见 [配置说明](./docs/配置说明.md)。

## 手动拓展

后续可以手动添加：

- Tavily API Key。
- 任意工具所需的环境变量。
- 全局 Skills。
- 项目级 Skills。
- npm 插件。
- 项目级 OMO 路由配置。

详见 [手动拓展](./docs/手动拓展.md)。

## 编码规范

| 文件类型 | 编码规则 |
|---|---|
| `.cmd` | ASCII、CRLF、无 BOM |
| `.ps1` | UTF-8 with BOM |
| `.md` | UTF-8 |
| `.conf` | UTF-8 或 ASCII |
| `.json` / `.jsonc` | UTF-8 |

如果手动编辑脚本，请尽量保持上述编码规则，避免 Windows CMD 或 PowerShell 5.1 读取异常。

## 许可证

本便携包脚本采用 MIT License。OpenCode、Oh-My-OpenAgent、Superpowers、Tavily Skills、Anthropic Skills 以及其他上游组件遵循各自项目许可证。
