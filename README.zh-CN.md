# Termuse

> Termuse —— 由 OpenCode 驱动的轻量级终端 AI 助手。

[English](README.md)

Termuse 为 macOS/zsh 提供快捷的 AI 问答命令。它刻意保持轻量：一个通过
`source` 加载的 zsh 文件、少量内存对话历史，不包含自主项目级自动化。

当你希望不离开终端就快速提问时，可以使用 Termuse：

```console
? git rebase 和 merge 有什么区别？
?? 如果分支已经推送到远程了呢？
```

## 环境要求

- 使用 zsh 的 macOS
- 已安装、登录并配置好 [OpenCode](https://opencode.ai/)

OpenCode 是唯一核心外部依赖。Termuse 不直接调用模型 API、不保存 API Key、
不实现 Provider，也不修改 OpenCode 的默认模型。

Termuse 会临时启动一个仅监听 `127.0.0.1` 的 OpenCode Server，消费 SSE 中的
`message.part.delta` 事件，并在每个文本增量到达时立即渲染。请求结束后 Server
会自动关闭。Termuse 只会短暂保留一份安全副本，用于更新内存历史和检查第一个
shell 代码块。该实现使用 macOS 自带的 `curl`，不需要安装额外软件或运行常驻服务。

Termuse 会为每次请求静默注入一个临时、专用的 OpenCode Agent。用户不需要执行
额外配置，它也不会改变 OpenCode TUI 使用的 Agent 或默认设置。

## 安装

从 GitHub 快速安装：

```zsh
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/hx24/termuse/main/install.sh | zsh && source ~/.zshrc
```

也可以先克隆仓库、检查脚本内容，再进行安装：

```zsh
git clone https://github.com/hx24/termuse.git
cd termuse
chmod +x install.sh uninstall.sh
./install.sh
source ~/.zshrc
```

安装器会把 `termuse.zsh` 复制到 `~/.termuse/`，并在 `~/.zshrc` 中加入一个
带标记的 source 区块。重复安装只会更新文件，不会重复添加 source 行。安装器
还会把重复、无标记或旧版格式错误的 Termuse 配置规范化为唯一的三行区块，
同时保留其他 zsh 配置。远程安装命令通过 HTTPS 下载同一份 `termuse.zsh`，
不需要额外配置。

## 使用方法

开始新对话：

```console
? 为什么 8080 端口已被占用？
```

在当前终端 Session 中继续追问：

```console
?? 告诉我怎么找到对应进程
```

完整命令与之等价：

```zsh
termuse ask "为什么 8080 端口已被占用？"
termuse continue "告诉我怎么找到对应进程"
```

也可以使用简写：

```zsh
ta "为什么 8080 端口已被占用？"
tc "告诉我怎么找到对应进程"
```

四种入口对应相同的两个操作：

| 操作 | 符号 | 简写 | 完整命令 |
| --- | --- | --- | --- |
| 开始新对话 | `?` | `ta` | `termuse ask` |
| 继续当前对话 | `??` | `tc` | `termuse continue` |

每次使用 `?`、`ta` 或 `termuse ask` 都会清空之前的 Termuse 对话。使用 `??`、
`tc` 或 `termuse continue` 时，会携带最近最多 8 轮成功的问答记录。历史只存在于
当前 zsh Session 的内存中，关闭终端后消失；Termuse 不使用 OpenCode 全局的
`--continue`。

## 模型选择

从 `opencode models` 返回的模型中选择：

```zsh
termuse model
```

使用上下方向键移动，按 Enter 确认。模型较多时，菜单会使用紧凑的滚动窗口。

查看或重置 Termuse 自己的模型设置：

```zsh
termuse model current
termuse model reset
```

选择结果保存在 `~/.config/termuse/config.zsh`，设置了 `$XDG_CONFIG_HOME` 时则
保存在对应目录。未选择模型时，Termuse 不传递 `--model`，由 OpenCode 使用其
默认模型。

## 终端 Markdown 展示

Termuse 内置了一个无依赖、支持增量输出的终端 Markdown 渲染器，可以识别：

- H1 到 H6 多级标题；
- 嵌套的无序列表、有序列表和任务列表；
- 粗体、斜体、删除线、行内代码、链接、图片和自动链接；
- 多级引用、表格、分隔线和 fenced code block；
- `markdown` 与 `md` 围栏，其内部会继续按 Markdown 渲染，而不是显示原始源码。

默认启用 256 色主题。可以在加载 Termuse 前通过 `TERMUSE_COLOR` 调整：

```zsh
export TERMUSE_COLOR=always  # 默认，始终启用颜色
export TERMUSE_COLOR=auto    # 遵循 NO_COLOR 和终端能力
export TERMUSE_COLOR=never   # 保留排版，但关闭 ANSI 颜色
```

输出被管道或重定向时会保留不含 ANSI 控制符的原始 Markdown。渲染过程保持增量，
不会等待完整回答后再统一展示。

## 键盘选择

所有交互式选择采用相同的键盘操作：

- `↑` / `↓`：在选项之间移动。
- `Enter`：确认高亮选项。
- `Ctrl+C`：取消。

涉及风险的操作始终默认高亮安全选项，包括模型选择、命令执行、危险命令二次
确认，以及卸载时是否删除已保存配置。

## 建议命令与安全机制

Termuse 只提取第一个标记为 `bash`、`sh`、`shell` 或 `zsh` 的 fenced code
block。它会完整显示命令并打开 `No` / `Yes` 方向键菜单，默认选择 `No`。
命令会显示在独立的“Suggested command”区域中，命令上下各空一行，并以 `>` 开头，
与上方回答清晰分开，不再使用额外边框文案。典型危险命令还需要通过第二个确认菜单，
默认选择 `Cancel`。

用户确认后的命令会由当前 zsh source，因此 `cd` 和 `export` 等命令可以影响
当前 shell。

Termuse 通过临时 `termuse` Agent 调用 OpenCode：该 Agent 使用专属问答 prompt、
全局与 Agent 两层 deny-all 权限，以及 `--agent termuse`。意外出现的原始
tool-call 标记会在显示和写入历史前被过滤。这些设置仅作用于本次调用，不会修改
OpenCode 配置。Termuse 不会自动执行 AI 输出、不会自行添加 `sudo`，也不会对
完整回答进行 `eval`。

AI 建议仍可能错误或不安全。确认前务必阅读完整命令。危险命令检测刻意保持
简单，它不是完整的 shell 安全分析器。

## 卸载

```zsh
./uninstall.sh
```

卸载器会删除 `~/.termuse` 和 `.zshrc` 中带标记的区块。方向键菜单默认保留已
保存的 Termuse 模型配置。卸载后请重新打开终端。

## 功能边界

Termuse v0.1 不包含 GUI、TUI、MCP、插件、长期记忆、Provider 管理、文件编辑、
Agent 工具或自动命令执行。Termuse 本身不使用 Node.js、Python、npm 包、`jq`
或任何需要编译的组件。
