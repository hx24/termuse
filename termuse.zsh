# Termuse — a lightweight AI companion for your terminal, powered by OpenCode.

typeset -g TERMUSE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/termuse"
typeset -g TERMUSE_CONFIG_FILE="$TERMUSE_CONFIG_DIR/config.zsh"
typeset -g TERMUSE_MODEL=""
typeset -gi TERMUSE_MAX_ROUNDS=8
typeset -gi TERMUSE_SELECTION=0
typeset -ga TERMUSE_HISTORY_USER
typeset -ga TERMUSE_HISTORY_ASSISTANT
typeset -g TERMUSE_OPENCODE_CONFIG='{"permission":{"*":"deny"},"agent":{"termuse":{"description":"Lightweight terminal Q&A assistant","mode":"primary","prompt":"You are Termuse, a lightweight terminal Q&A assistant. You have no access to the filesystem, terminal, tools, or local environment. Never call tools and never emit tool-call markup such as <tool_call>, <function>, or JSON tool calls. Never claim a command has been executed. If a request requires inspecting the user machine, clearly say you cannot inspect it directly, then suggest the minimum necessary command in a fenced bash, sh, shell, or zsh block so Termuse can ask the user whether to run it. Answer concisely and prioritize terminal, development, Linux, macOS, Git, and networking questions. Clearly warn about destructive commands. Do not guess your model identity or runtime configuration.","permission":{"*":"deny"}}}}'

[[ -r "$TERMUSE_CONFIG_FILE" ]] && source "$TERMUSE_CONFIG_FILE"

_termuse_usage() {
  print -r -- 'Usage:
  ? <question>          Start a new conversation
  ?? <follow-up>        Continue the active conversation
  ta <question>         Short for termuse ask
  tc <follow-up>        Short for termuse continue
  termuse model         Select a model
  termuse model current Show the current model
  termuse model reset   Use the OpenCode default model'
}

_termuse_require_opencode() {
  if ! command -v opencode >/dev/null 2>&1; then
    print -u2 -r -- 'Termuse requires OpenCode.

Please install and configure OpenCode first.'
    return 1
  fi
}

_termuse_select() {
  emulate -L zsh
  local prompt="$1"
  shift
  local -a choices=("$@")
  local key sequence
  local -i selected=1 start end i rendered=0 max_visible=10

  TERMUSE_SELECTION=0
  (( ${#choices} )) || return 1
  if [[ ! -t 0 || ! -t 1 ]]; then
    print -r -- "$prompt ${choices[1]}"
    return 1
  fi

  while true; do
    if (( rendered )); then
      print -n -- $'\e['"$rendered"'A\r\e[J'
    fi

    start=$(( selected - max_visible / 2 ))
    (( start < 1 )) && start=1
    end=$(( start + max_visible - 1 ))
    if (( end > ${#choices} )); then
      end=${#choices}
      start=$(( end - max_visible + 1 ))
      (( start < 1 )) && start=1
    fi

    print -r -- "$prompt"
    rendered=1
    if (( start > 1 )); then
      print -r -- "  ↑ $(( start - 1 )) more"
      (( rendered++ ))
    fi
    for (( i = start; i <= end; i++ )); do
      if (( i == selected )); then
        print -r -- $'\e[36m❯\e[0m '"${choices[$i]}"
      else
        print -r -- "  ${choices[$i]}"
      fi
      (( rendered++ ))
    done
    if (( end < ${#choices} )); then
      print -r -- "  ↓ $(( ${#choices} - end )) more"
      (( rendered++ ))
    fi

    if ! read -rs -k1 key; then
      print -n -- $'\e['"$rendered"'A\r\e[J'
      print -r -- "$prompt ${choices[1]}"
      return 1
    fi

    case "$key" in
      $'\e')
        sequence=""
        read -rs -k2 sequence || true
        case "$sequence" in
          '[A'|'OA') (( selected > 1 )) && (( selected-- )) ;;
          '[B'|'OB') (( selected < ${#choices} )) && (( selected++ )) ;;
        esac
        ;;
      $'\n'|$'\r'|'')
        print -n -- $'\e['"$rendered"'A\r\e[J'
        print -r -- "$prompt ${choices[$selected]}"
        TERMUSE_SELECTION=$selected
        return 0
        ;;
    esac
  done
}

_termuse_build_prompt() {
  emulate -L zsh
  local question="$1"
  local prompt='Conversation transcript for context:'

  if (( ${#TERMUSE_HISTORY_USER} )); then
    local i
    for (( i = 1; i <= ${#TERMUSE_HISTORY_USER}; i++ )); do
      prompt+=$'\n\nUser:\n'"${TERMUSE_HISTORY_USER[$i]}"
      prompt+=$'\n\nAssistant:\n'"${TERMUSE_HISTORY_ASSISTANT[$i]}"
    done
  fi

  prompt+=$'\n\nNew user question:\n'"$question"
  print -r -- "$prompt"
}

_termuse_sanitize_stream() {
  emulate -L zsh
  local output_file="$1" line
  local -i in_tool_call=0 warned=0
  local warning='> Termuse blocked an attempted OpenCode tool call. No command was executed.'

  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( in_tool_call )); then
      [[ "$line" == *'</tool_call>'* || "$line" == *'\</tool_call>'* ]] && in_tool_call=0
      continue
    fi

    if [[ "$line" == *'<tool_call'* || "$line" == *'\<tool_call'* ||
          "$line" == *'<function='* || "$line" == *'\<function='* ||
          "$line" == *'<parameter='* || "$line" == *'\<parameter='* ]]; then
      if (( ! warned )); then
        print -r -- "$warning"
        print -r -- "$warning" >> "$output_file"
        warned=1
      fi
      [[ "$line" == *'</tool_call>'* || "$line" == *'\</tool_call>'* ]] || in_tool_call=1
      continue
    fi

    print -r -- "$line"
    print -r -- "$line" >> "$output_file"
  done

  return 0
}

_termuse_render_markdown() {
  emulate -L zsh
  setopt extendedglob
  local line trimmed language
  local -i in_code=0 render=0 use_color=0
  local reset=$'\e[0m' bold=$'\e[1m' dim=$'\e[2m'
  local cyan=$'\e[36m' blue=$'\e[34m' yellow=$'\e[33m'
  [[ -t 1 ]] && render=1
  [[ -t 1 && -z "${NO_COLOR:-}" ]] && use_color=1
  if (( ! use_color )); then
    reset='' bold='' dim='' cyan='' blue='' yellow=''
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! render )); then
      print -r -- "$line"
      continue
    fi

    trimmed="${line##[[:space:]]#}"
    if [[ "$trimmed" == '```'* ]]; then
      if (( in_code )); then
        print -r -- "${dim}└─${reset}"
        in_code=0
      else
        language="${trimmed#\`\`\`}"
        print -r -- "${dim}┌─ ${language:-code}${reset}"
        in_code=1
      fi
    elif (( in_code )); then
      print -r -- "${cyan}${line}${reset}"
    elif [[ "$line" == \#\#\#\ * ]]; then
      print -r -- "${bold}${blue}${line#\#\#\# }${reset}"
    elif [[ "$line" == \#\#\ * ]]; then
      print -r -- "${bold}${cyan}${line#\#\# }${reset}"
    elif [[ "$line" == \#\ * ]]; then
      print -r -- "${bold}${yellow}${line#\# }${reset}"
    elif [[ "$line" == '- '* || "$line" == '* '* ]]; then
      print -r -- "${cyan}•${reset} ${line#??}"
    elif [[ "$line" == '> '* ]]; then
      print -r -- "${dim}${line#> }${reset}"
    elif [[ "$line" == '---' || "$line" == '***' ]]; then
      print -r -- "${dim}────────────────────────────────────────${reset}"
    else
      print -r -- "$line"
    fi
  done
  (( in_code )) && print -r -- "${dim}└─${reset}"
  return 0
}

_termuse_extract_shell_block() {
  emulate -L zsh
  local response="$1" line normalized
  local in_block=0 command_text=""

  for line in ${(f)response}; do
    line="${line%$'\r'}"
    normalized="${(L)line}"
    if (( ! in_block )); then
      if [[ "$normalized" =~ '^[[:space:]]*```(bash|sh|shell|zsh)[[:space:]]*$' ]]; then
        in_block=1
      fi
    elif [[ "$line" =~ '^[[:space:]]*```[[:space:]]*$' ]]; then
      print -r -- "$command_text"
      return 0
    elif [[ -n "$command_text" ]]; then
      command_text+=$'\n'"$line"
    else
      command_text="$line"
    fi
  done

  return 1
}

_termuse_is_dangerous() {
  emulate -L zsh
  local command_text="${(L)1}"
  [[ "$command_text" == *'rm -rf'* || "$command_text" == *'rm -fr'* ||
     "$command_text" == *'mkfs'* || "$command_text" == *'dd if='* ||
     "$command_text" == *'shutdown'* || "$command_text" == *'reboot'* ||
     "$command_text" == *'poweroff'* || "$command_text" == *'diskutil erase'* ]]
}

_termuse_offer_command() {
  emulate -L zsh
  local response="$1" command_text

  command_text="$(_termuse_extract_shell_block "$response")" || return 0
  [[ -z "$command_text" ]] && return 0

  print -r -- "
Suggested command:

$command_text
"
  _termuse_select 'Run this command?' 'No' 'Yes' || return 0
  (( TERMUSE_SELECTION == 2 )) || return 0

  if _termuse_is_dangerous "$command_text"; then
    print -u2 -r -- '
WARNING: This command may be destructive.'
    _termuse_select 'Confirm dangerous command:' 'Cancel' 'Execute destructive command' || return 0
    (( TERMUSE_SELECTION == 2 )) || return 0
  fi

  print
  print -r -- 'Running...'
  # Sourcing makes cd/export affect the current interactive zsh.
  builtin source /dev/stdin <<< "$command_text"
}

_termuse_remember() {
  TERMUSE_HISTORY_USER+=("$1")
  TERMUSE_HISTORY_ASSISTANT+=("$2")
  while (( ${#TERMUSE_HISTORY_USER} > TERMUSE_MAX_ROUNDS )); do
    TERMUSE_HISTORY_USER[1]=()
    TERMUSE_HISTORY_ASSISTANT[1]=()
  done
}

_termuse_ask() {
  emulate -L zsh
  local mode="$1"
  shift
  local question="$*" prompt response exit_code stream_code render_code tmp_file
  local -a pipeline_status

  if [[ -z "${question//[[:space:]]/}" ]]; then
    _termuse_usage
    return 1
  fi
  _termuse_require_opencode || return 1

  if [[ "$mode" == 'ask' ]]; then
    TERMUSE_HISTORY_USER=()
    TERMUSE_HISTORY_ASSISTANT=()
  elif (( ! ${#TERMUSE_HISTORY_USER} )); then
    print -u2 -r -- 'No active Termuse conversation.

Start one with:
? your question'
    return 1
  fi

  prompt="$(_termuse_build_prompt "$question")"
  tmp_file="$(command mktemp "${TMPDIR:-/tmp}/termuse-response.XXXXXX")" || {
    print -u2 -r -- 'Termuse: could not create a temporary response file.'
    return 1
  }
  trap "command rm -f -- ${(q)tmp_file}" EXIT

  if [[ -n "$TERMUSE_MODEL" ]]; then
    OPENCODE_CONFIG_CONTENT="$TERMUSE_OPENCODE_CONFIG" \
      opencode run --agent termuse --model "$TERMUSE_MODEL" "$prompt" |
      _termuse_sanitize_stream "$tmp_file" | _termuse_render_markdown
    pipeline_status=("${pipestatus[@]}")
  else
    OPENCODE_CONFIG_CONTENT="$TERMUSE_OPENCODE_CONFIG" \
      opencode run --agent termuse "$prompt" |
      _termuse_sanitize_stream "$tmp_file" | _termuse_render_markdown
    pipeline_status=("${pipestatus[@]}")
  fi
  exit_code="${pipeline_status[1]:-1}"
  stream_code="${pipeline_status[2]:-1}"
  render_code="${pipeline_status[3]:-1}"
  response="$(<"$tmp_file")"

  if (( exit_code != 0 )); then
    print -u2 -r -- "Termuse: OpenCode request failed (exit $exit_code)."
    return "$exit_code"
  fi
  if (( stream_code != 0 || render_code != 0 )); then
    print -u2 -r -- 'Termuse: could not process the OpenCode response.'
    return 1
  fi
  if [[ -z "$response" ]]; then
    print -u2 -r -- 'Termuse: OpenCode returned an empty response.'
    return 1
  fi

  _termuse_remember "$question" "$response"
  _termuse_offer_command "$response"
}

_termuse_model() {
  emulate -L zsh
  local action="${1:-select}"

  case "$action" in
    current)
      print -r -- 'Current model:'
      print -r -- "${TERMUSE_MODEL:-OpenCode default}"
      ;;
    reset)
      TERMUSE_MODEL=""
      command rm -f -- "$TERMUSE_CONFIG_FILE"
      print -r -- 'Termuse model reset. Using OpenCode default.'
      ;;
    select)
      _termuse_require_opencode || return 1
      local output line selected
      local -a models
      output="$(opencode models)" || {
        print -u2 -r -- 'Termuse: could not load OpenCode models.'
        return 1
      }
      for line in ${(f)output}; do
        [[ -n "${line//[[:space:]]/}" ]] && models+=("$line")
      done
      if (( ! ${#models} )); then
        print -u2 -r -- 'Termuse: OpenCode returned no models.'
        return 1
      fi

      _termuse_select 'Select model (↑/↓, Enter):' "${models[@]}" || return 1
      selected="${models[$TERMUSE_SELECTION]}"
      command mkdir -p -- "$TERMUSE_CONFIG_DIR" || return 1
      print -r -- "TERMUSE_MODEL=${(q)selected}" >| "$TERMUSE_CONFIG_FILE" || return 1
      command chmod 600 "$TERMUSE_CONFIG_FILE"
      TERMUSE_MODEL="$selected"
      print -r -- 'Current model:'
      print -r -- "$TERMUSE_MODEL"
      ;;
    *)
      print -u2 -r -- 'Usage: termuse model [current|reset]'
      return 1
      ;;
  esac
}

termuse() {
  emulate -L zsh
  local command_name="${1:-help}"
  (( $# )) && shift

  case "$command_name" in
    ask)      _termuse_ask ask "$@" ;;
    continue) _termuse_ask continue "$@" ;;
    model)    _termuse_model "$@" ;;
    help|-h|--help) _termuse_usage ;;
    *)
      print -u2 -r -- "Unknown command: $command_name"
      _termuse_usage
      return 1
      ;;
  esac
}

alias '?'='termuse ask'
alias '??'='termuse continue'
alias 'ta'='termuse ask'
alias 'tc'='termuse continue'
