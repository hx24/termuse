# Termuse

> Termuse — a lightweight AI companion for your terminal, powered by OpenCode.

[简体中文](README.zh-CN.md)

Termuse adds quick AI question-and-answer commands to macOS/zsh. It is deliberately
small: one sourced zsh file, short in-memory conversation history, and no
autonomous project automation.

Termuse exists for questions that are faster to ask without leaving the terminal:

```console
? What is the difference between git rebase and merge?
?? What if the branch has already been pushed to the remote?
```

## Requirements

- macOS with zsh
- [OpenCode](https://opencode.ai/) installed, authenticated, and configured

OpenCode is the only core external dependency. Termuse does not call model APIs,
store API keys, implement providers, or change OpenCode's default model.
Termuse starts a temporary OpenCode Server bound only to `127.0.0.1`, consumes
its SSE `message.part.delta` events, and renders each text chunk as it arrives.
The server is stopped automatically when the request finishes. A secure temporary
copy is kept only until Termuse has updated the in-memory history and inspected
the first shell block. This uses the `curl` included with macOS and requires no
additional package or persistent service.

Termuse silently injects a temporary, dedicated OpenCode agent for each request.
It requires no additional user configuration and does not change the agents or
defaults used by the OpenCode TUI.

## Install

Quick install from GitHub:

```zsh
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/hx24/termuse/main/install.sh | zsh && source ~/.zshrc
```

Alternatively, clone the repository and inspect the scripts before installing:

```zsh
git clone https://github.com/hx24/termuse.git
cd termuse
chmod +x install.sh uninstall.sh
./install.sh
source ~/.zshrc
```

The installer copies `termuse.zsh` to `~/.termuse/` and adds one marked source
block to `~/.zshrc`. Running it again updates the installed file without adding a
second source line. It also normalizes duplicate, unmarked, or legacy malformed
Termuse entries into one valid three-line block while preserving unrelated zsh
configuration. The remote command downloads the same `termuse.zsh` file over
HTTPS and requires no additional configuration.

## Use

Start a new conversation:

```console
? why is port 8080 already in use
```

Continue it in the same terminal session:

```console
?? show me how to find the process
```

The long forms are equivalent:

```zsh
termuse ask "why is port 8080 already in use"
termuse continue "show me how to find the process"
```

You can also use the short aliases:

```zsh
ta "why is port 8080 already in use"
tc "show me how to find the process"
```

The four entry points map to the same two operations:

| Operation | Symbol | Short alias | Full command |
| --- | --- | --- | --- |
| Start a new conversation | `?` | `ta` | `termuse ask` |
| Continue the conversation | `??` | `tc` | `termuse continue` |

Each `?`, `ta`, or `termuse ask` clears the previous Termuse conversation. Each
`??`, `tc`, or `termuse continue` includes up to the last eight successful
question/answer rounds. History is memory-only and disappears when that zsh
session ends; Termuse never uses OpenCode's global `--continue`.

## Model selection

Choose from the models returned by `opencode models`:

```zsh
termuse model
```

Use the up and down arrow keys to move, then press Enter to select. The model menu
shows a compact scrolling window when many models are available.

View or reset the Termuse-only setting:

```zsh
termuse model current
termuse model reset
```

The selection is stored in `~/.config/termuse/config.zsh` (or under
`$XDG_CONFIG_HOME`). With no selection, Termuse passes no `--model` flag and
OpenCode uses its own default.

## Terminal Markdown

Termuse includes a dependency-free, incremental terminal renderer for:

- headings from H1 through H6;
- nested unordered and ordered lists, plus task lists;
- bold, italic, strikethrough, inline code, links, images, and autolinks;
- nested quotes, tables, separators, and fenced code blocks;
- `markdown` and `md` fences, whose contents are rendered as Markdown instead
  of being shown as raw source.

A 256-color theme is enabled by default. Set `TERMUSE_COLOR` before loading
Termuse to control it:

```zsh
export TERMUSE_COLOR=always  # default
export TERMUSE_COLOR=auto    # respect NO_COLOR and terminal capabilities
export TERMUSE_COLOR=never   # keep formatting, disable ANSI colors
```

When output is piped or redirected, the original Markdown is preserved without
ANSI codes. Rendering stays incremental and does not delay the SSE stream.

## Keyboard navigation

All interactive choices use the same keyboard controls:

- `↑` / `↓` moves between choices.
- `Enter` confirms the highlighted choice.
- `Ctrl+C` cancels.

Potentially destructive actions always highlight the safe choice first. This
applies to model selection, command execution, destructive-command confirmation,
and removal of saved configuration during uninstall.

## Suggested commands and safety

Termuse extracts only the first fenced block labeled `bash`, `sh`, `shell`, or
`zsh`. It prints the complete block and opens a `No` / `Yes` arrow-key menu with
`No` selected by default. The command is displayed in a separate “Suggested
command” section. The command block is separated from the surrounding answer by
blank lines, and each command line starts with `>` for quick recognition. Typical
destructive commands require a second menu, which defaults to `Cancel`.
Confirmed commands are sourced by the current zsh, so commands such as `cd` and
`export` can affect it.

OpenCode is invoked through a temporary `termuse` agent with a dedicated Q&A
prompt, global and agent-level deny-all permissions, and `--agent termuse`.
Unexpected raw tool-call markup is filtered before display and history storage.
These settings apply only to that invocation and do not modify OpenCode
configuration. Termuse never automatically runs AI output, never runs `sudo` on
its own, and never evaluates the full response.

AI suggestions can still be wrong or unsafe. Read every proposed command before
confirming it. The destructive-command check is intentionally small and is not a
complete shell security analyzer.

## Uninstall

```zsh
./uninstall.sh
```

The uninstaller removes `~/.termuse` and the marked `.zshrc` block. An arrow-key
menu defaults to keeping the saved Termuse model configuration. Open a new
terminal afterward.

## Scope

Termuse v0.1 has no GUI, TUI, MCP, plugins, long-term memory, provider management,
file editing, agent tools, or automatic command execution. It uses no Node.js,
Python, npm package, `jq`, or compiled Termuse component.
