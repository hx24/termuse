# Termuse — a lightweight AI companion for your terminal, powered by OpenCode.

typeset -g TERMUSE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/termuse"
typeset -g TERMUSE_CONFIG_FILE="$TERMUSE_CONFIG_DIR/config.zsh"
typeset -g TERMUSE_MODEL=""
typeset -g TERMUSE_COLOR="${TERMUSE_COLOR:-always}"
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

_termuse_json_escape() {
  emulate -L zsh
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\f'/\\f}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  print -n -r -- "$value"
}

_termuse_json_string_field() {
  emulate -L zsh
  local json="$1" field="$2" marker rest out='' char hex decoded
  local -i i escaped=0 length
  typeset -g REPLY=''

  marker="\"${field}\":\""
  rest="${json#*${marker}}"
  [[ "$rest" != "$json" ]] || return 1
  length=${#rest}

  for (( i = 1; i <= length; i++ )); do
    char="${rest[$i]}"
    if (( escaped )); then
      case "$char" in
        '"') out+='"' ;;
        $'\\') out+=$'\\' ;;
        '/') out+='/' ;;
        b) out+=$'\b' ;;
        f) out+=$'\f' ;;
        n) out+=$'\n' ;;
        r) out+=$'\r' ;;
        t) out+=$'\t' ;;
        u)
          hex="${rest[$(( i + 1 )),$(( i + 4 ))]}"
          [[ "$hex" == [[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]] ]] || return 1
          printf -v decoded "\\u${hex}"
          out+="$decoded"
          (( i += 4 ))
          ;;
        *) out+="$char" ;;
      esac
      escaped=0
    elif [[ "$char" == $'\\' ]]; then
      escaped=1
    elif [[ "$char" == '"' ]]; then
      REPLY="$out"
      return 0
    else
      out+="$char"
    fi
  done

  return 1
}

_termuse_markdown_stream_start() {
  typeset -g TERMUSE_MD_MODE='prefix'
  typeset -g TERMUSE_MD_PENDING=''
  typeset -gi TERMUSE_MD_IN_CODE=0
  typeset -gi TERMUSE_MD_IN_MARKDOWN_FENCE=0
  typeset -gi TERMUSE_MD_RENDER=0
  typeset -gi TERMUSE_MD_USE_COLOR=0
  typeset -gi TERMUSE_MD_WROTE_ANY=0
  typeset -gi TERMUSE_MD_LAST_NEWLINE=1
  typeset -gi TERMUSE_MD_TABLE_ROWS=0
  typeset -g TERMUSE_MD_BLOCK_STYLE=''
  typeset -g TERMUSE_MD_FENCE_INDENT=''
  typeset -g TERMUSE_MD_INLINE_PENDING=''
  typeset -g TERMUSE_MD_INLINE_LAST_CHAR=''
  typeset -gi TERMUSE_MD_INLINE_BOLD=0
  typeset -gi TERMUSE_MD_INLINE_ITALIC=0
  typeset -gi TERMUSE_MD_INLINE_STRIKE=0
  typeset -gi TERMUSE_MD_INLINE_CODE=0
  typeset -gi TERMUSE_MD_INLINE_ESCAPE=0
  typeset -gi TERMUSE_MD_LINK_STATE=0
  typeset -gi TERMUSE_MD_LINK_IMAGE=0
  typeset -gi TERMUSE_MD_IMAGE_PENDING=0
  typeset -g TERMUSE_MD_LINK_LABEL=''
  typeset -g TERMUSE_MD_LINK_URL=''
  typeset -gi TERMUSE_MD_AUTOLINK=0
  typeset -g TERMUSE_MD_AUTOLINK_TEXT=''
  typeset -g TERMUSE_MD_RESET=$'\e[0m'
  typeset -g TERMUSE_MD_BOLD=$'\e[1m'
  typeset -g TERMUSE_MD_DIM=$'\e[2m'
  typeset -g TERMUSE_MD_ITALIC=$'\e[3m'
  typeset -g TERMUSE_MD_UNDERLINE=$'\e[4m'
  typeset -g TERMUSE_MD_STRIKE=$'\e[9m'
  typeset -g TERMUSE_MD_CYAN=$'\e[38;5;45m'
  typeset -g TERMUSE_MD_BLUE=$'\e[38;5;75m'
  typeset -g TERMUSE_MD_YELLOW=$'\e[38;5;221m'
  typeset -g TERMUSE_MD_GREEN=$'\e[38;5;114m'
  typeset -g TERMUSE_MD_MAGENTA=$'\e[38;5;177m'
  typeset -g TERMUSE_MD_RED=$'\e[38;5;203m'
  typeset -g TERMUSE_MD_GRAY=$'\e[38;5;245m'
  typeset -g TERMUSE_MD_CODE=$'\e[38;5;117m'
  typeset -g TERMUSE_MD_H1=$'\e[1;38;5;213m'
  typeset -g TERMUSE_MD_H2=$'\e[1;38;5;81m'
  typeset -g TERMUSE_MD_H3=$'\e[1;38;5;114m'
  typeset -g TERMUSE_MD_H4=$'\e[1;38;5;221m'
  typeset -g TERMUSE_MD_H5=$'\e[1;38;5;177m'
  typeset -g TERMUSE_MD_H6=$'\e[1;38;5;245m'

  [[ -t 1 ]] && TERMUSE_MD_RENDER=1
  if [[ -t 1 ]]; then
    case "${(L)TERMUSE_COLOR}" in
      never|off|0) TERMUSE_MD_USE_COLOR=0 ;;
      auto) [[ "${TERM:-}" != dumb && -z "${NO_COLOR:-}" ]] && TERMUSE_MD_USE_COLOR=1 ;;
      *) TERMUSE_MD_USE_COLOR=1 ;;
    esac
  fi
  if (( ! TERMUSE_MD_USE_COLOR )); then
    TERMUSE_MD_RESET=''
    TERMUSE_MD_BOLD=''
    TERMUSE_MD_DIM=''
    TERMUSE_MD_ITALIC=''
    TERMUSE_MD_UNDERLINE=''
    TERMUSE_MD_STRIKE=''
    TERMUSE_MD_CYAN=''
    TERMUSE_MD_BLUE=''
    TERMUSE_MD_YELLOW=''
    TERMUSE_MD_GREEN=''
    TERMUSE_MD_MAGENTA=''
    TERMUSE_MD_RED=''
    TERMUSE_MD_GRAY=''
    TERMUSE_MD_CODE=''
    TERMUSE_MD_H1=''
    TERMUSE_MD_H2=''
    TERMUSE_MD_H3=''
    TERMUSE_MD_H4=''
    TERMUSE_MD_H5=''
    TERMUSE_MD_H6=''
  fi
}

_termuse_markdown_apply_style() {
  print -n -- "$TERMUSE_MD_RESET$TERMUSE_MD_BLOCK_STYLE"
  (( TERMUSE_MD_INLINE_BOLD )) && print -n -- "$TERMUSE_MD_BOLD"
  (( TERMUSE_MD_INLINE_ITALIC )) && print -n -- "$TERMUSE_MD_ITALIC$TERMUSE_MD_MAGENTA"
  (( TERMUSE_MD_INLINE_STRIKE )) && print -n -- "$TERMUSE_MD_STRIKE$TERMUSE_MD_DIM"
  (( TERMUSE_MD_INLINE_CODE )) && print -n -- "$TERMUSE_MD_CODE"
}

_termuse_markdown_inline_reset() {
  TERMUSE_MD_INLINE_PENDING=''
  TERMUSE_MD_INLINE_LAST_CHAR=''
  TERMUSE_MD_INLINE_BOLD=0
  TERMUSE_MD_INLINE_ITALIC=0
  TERMUSE_MD_INLINE_STRIKE=0
  TERMUSE_MD_INLINE_CODE=0
  TERMUSE_MD_INLINE_ESCAPE=0
  TERMUSE_MD_LINK_STATE=0
  TERMUSE_MD_LINK_IMAGE=0
  TERMUSE_MD_IMAGE_PENDING=0
  TERMUSE_MD_LINK_LABEL=''
  TERMUSE_MD_LINK_URL=''
  TERMUSE_MD_AUTOLINK=0
  TERMUSE_MD_AUTOLINK_TEXT=''
}

_termuse_markdown_inline_feed() {
  emulate -L zsh
  local text="$1" char marker buffered
  local -i i again

  for (( i = 1; i <= ${#text}; i++ )); do
    char="${text[$i]}"
    again=1
    while (( again )); do
      again=0

      if (( TERMUSE_MD_INLINE_ESCAPE )); then
        print -n -r -- "$char"
        TERMUSE_MD_INLINE_LAST_CHAR="$char"
        TERMUSE_MD_INLINE_ESCAPE=0
        continue
      fi

      if (( TERMUSE_MD_INLINE_CODE )); then
        if [[ "$char" == '`' ]]; then
          TERMUSE_MD_INLINE_CODE=0
          _termuse_markdown_apply_style
        else
          print -n -r -- "$char"
          TERMUSE_MD_INLINE_LAST_CHAR="$char"
        fi
        continue
      fi

      if (( TERMUSE_MD_IMAGE_PENDING )); then
        TERMUSE_MD_IMAGE_PENDING=0
        if [[ "$char" == '[' ]]; then
          TERMUSE_MD_LINK_STATE=1
          TERMUSE_MD_LINK_IMAGE=1
          TERMUSE_MD_LINK_LABEL=''
        else
          print -n -r -- '!'
          again=1
        fi
        continue
      fi

      if (( TERMUSE_MD_LINK_STATE == 1 )); then
        if [[ "$char" == ']' ]]; then
          TERMUSE_MD_LINK_STATE=2
        else
          TERMUSE_MD_LINK_LABEL+="$char"
        fi
        continue
      elif (( TERMUSE_MD_LINK_STATE == 2 )); then
        if [[ "$char" == '(' ]]; then
          TERMUSE_MD_LINK_STATE=3
          TERMUSE_MD_LINK_URL=''
        else
          (( TERMUSE_MD_LINK_IMAGE )) && print -n -r -- '!'
          print -n -r -- "[$TERMUSE_MD_LINK_LABEL]"
          TERMUSE_MD_LINK_STATE=0
          TERMUSE_MD_LINK_IMAGE=0
          TERMUSE_MD_LINK_LABEL=''
          again=1
        fi
        continue
      elif (( TERMUSE_MD_LINK_STATE == 3 )); then
        if [[ "$char" == ')' ]]; then
          if (( TERMUSE_MD_LINK_IMAGE )); then
            print -n -- "$TERMUSE_MD_MAGENTA▣ $TERMUSE_MD_RESET"
          fi
          print -n -- "$TERMUSE_MD_BLUE$TERMUSE_MD_UNDERLINE"
          print -n -r -- "$TERMUSE_MD_LINK_LABEL"
          _termuse_markdown_apply_style
          if [[ -n "$TERMUSE_MD_LINK_URL" ]]; then
            print -n -- "$TERMUSE_MD_DIM$TERMUSE_MD_BLUE"
            print -n -r -- " <$TERMUSE_MD_LINK_URL>"
            _termuse_markdown_apply_style
          fi
          TERMUSE_MD_LINK_STATE=0
          TERMUSE_MD_LINK_IMAGE=0
          TERMUSE_MD_LINK_LABEL=''
          TERMUSE_MD_LINK_URL=''
        else
          TERMUSE_MD_LINK_URL+="$char"
        fi
        continue
      fi

      if (( TERMUSE_MD_AUTOLINK )); then
        if [[ "$char" == '>' ]]; then
          if [[ "$TERMUSE_MD_AUTOLINK_TEXT" == (http|https|mailto):* ]]; then
            print -n -- "$TERMUSE_MD_BLUE$TERMUSE_MD_UNDERLINE"
            print -n -r -- "$TERMUSE_MD_AUTOLINK_TEXT"
            _termuse_markdown_apply_style
          else
            print -n -r -- "<$TERMUSE_MD_AUTOLINK_TEXT>"
          fi
          TERMUSE_MD_AUTOLINK=0
          TERMUSE_MD_AUTOLINK_TEXT=''
        else
          TERMUSE_MD_AUTOLINK_TEXT+="$char"
        fi
        continue
      fi

      if [[ -n "$TERMUSE_MD_INLINE_PENDING" ]]; then
        marker="$TERMUSE_MD_INLINE_PENDING"
        TERMUSE_MD_INLINE_PENDING=''
        if [[ "$char" == "$marker" ]]; then
          case "$marker" in
            '*'|'_') (( TERMUSE_MD_INLINE_BOLD = ! TERMUSE_MD_INLINE_BOLD )) ;;
            '~') (( TERMUSE_MD_INLINE_STRIKE = ! TERMUSE_MD_INLINE_STRIKE )) ;;
          esac
          _termuse_markdown_apply_style
        else
          case "$marker" in
            '*'|'_')
              (( TERMUSE_MD_INLINE_ITALIC = ! TERMUSE_MD_INLINE_ITALIC ))
              _termuse_markdown_apply_style
              ;;
            '~') print -n -r -- '~' ;;
          esac
          again=1
        fi
        continue
      fi

      case "$char" in
        $'\\') TERMUSE_MD_INLINE_ESCAPE=1 ;;
        '`')
          TERMUSE_MD_INLINE_CODE=1
          _termuse_markdown_apply_style
          ;;
        '_')
          if (( ! TERMUSE_MD_INLINE_BOLD && ! TERMUSE_MD_INLINE_ITALIC )) &&
              [[ "$TERMUSE_MD_INLINE_LAST_CHAR" == [[:alnum:]] ]]; then
            print -n -r -- '_'
            TERMUSE_MD_INLINE_LAST_CHAR='_'
          else
            TERMUSE_MD_INLINE_PENDING='_'
          fi
          ;;
        '*'|'~') TERMUSE_MD_INLINE_PENDING="$char" ;;
        '[')
          TERMUSE_MD_LINK_STATE=1
          TERMUSE_MD_LINK_LABEL=''
          ;;
        '!') TERMUSE_MD_IMAGE_PENDING=1 ;;
        '<')
          TERMUSE_MD_AUTOLINK=1
          TERMUSE_MD_AUTOLINK_TEXT=''
          ;;
        *)
          print -n -r -- "$char"
          TERMUSE_MD_INLINE_LAST_CHAR="$char"
          ;;
      esac
    done
  done
}

_termuse_markdown_inline_finish() {
  if [[ -n "$TERMUSE_MD_INLINE_PENDING" ]]; then
    case "$TERMUSE_MD_INLINE_PENDING" in
      '*'|'_')
        if (( TERMUSE_MD_INLINE_ITALIC )); then
          TERMUSE_MD_INLINE_ITALIC=0
          _termuse_markdown_apply_style
        else
          print -n -r -- "$TERMUSE_MD_INLINE_PENDING"
        fi
        ;;
      '~') print -n -r -- '~' ;;
    esac
  fi
  case "$TERMUSE_MD_LINK_STATE" in
    1) print -n -r -- "${${TERMUSE_MD_LINK_IMAGE:#0}:+!}[$TERMUSE_MD_LINK_LABEL" ;;
    2) print -n -r -- "${${TERMUSE_MD_LINK_IMAGE:#0}:+!}[$TERMUSE_MD_LINK_LABEL]" ;;
    3) print -n -r -- "${${TERMUSE_MD_LINK_IMAGE:#0}:+!}[$TERMUSE_MD_LINK_LABEL]($TERMUSE_MD_LINK_URL" ;;
  esac
  (( TERMUSE_MD_IMAGE_PENDING )) && print -n -r -- '!'
  (( TERMUSE_MD_AUTOLINK )) && print -n -r -- "<$TERMUSE_MD_AUTOLINK_TEXT"
  (( TERMUSE_MD_INLINE_ESCAPE )) && print -n -r -- '\'
  _termuse_markdown_inline_reset
}

_termuse_markdown_fit_cell() {
  emulate -L zsh
  local text="$1" limit="$2" char output=''
  local -i i char_width used=0 total=0

  for (( i = 1; i <= ${#text}; i++ )); do
    char="${text[$i]}"
    [[ "$char" == [[:ascii:]] ]] && char_width=1 || char_width=2
    (( total += char_width ))
  done

  for (( i = 1; i <= ${#text}; i++ )); do
    char="${text[$i]}"
    [[ "$char" == [[:ascii:]] ]] && char_width=1 || char_width=2
    if (( total > limit && used + char_width > limit - 1 )); then
      output+='…'
      (( used++ ))
      break
    fi
    output+="$char"
    (( used += char_width ))
  done

  typeset -g REPLY="$output"
  typeset -gi TERMUSE_MD_CELL_WIDTH_USED=$used
}

_termuse_markdown_table_line() {
  emulate -L zsh
  setopt extendedglob
  local line="$1" leading='' stripped cell cleaned separator=1 output='' display='' padding='' rule=''
  local -a cells
  local -i col_count cell_width available pad j terminal_width=${COLUMNS:-80}

  (( terminal_width > 0 )) || terminal_width=80

  stripped="$line"
  while [[ "$stripped" == ' '* ]]; do
    leading+=' '
    stripped="${stripped[2,-1]}"
  done
  stripped="${stripped#|}"
  stripped="${stripped%|}"
  cells=("${(@s:|:)stripped}")
  col_count=${#cells}
  (( col_count > 0 )) || return 0
  available=$(( terminal_width - ${#leading} - col_count * 3 - 1 ))
  cell_width=$(( available / col_count ))
  (( cell_width < 8 )) && cell_width=8
  (( cell_width > 36 )) && cell_width=36

  for cell in "${cells[@]}"; do
    cleaned="${cell##[[:space:]]#}"
    cleaned="${cleaned%%[[:space:]]#}"
    if [[ ! "$cleaned" =~ '^:?-{3,}:?$' ]]; then
      separator=0
      break
    fi
  done

  print -n -r -- "$leading"
  if (( separator )); then
    print -n -- "$TERMUSE_MD_GRAY"
    rule=''
    for (( j = 0; j < cell_width + 2; j++ )); do
      rule+='─'
    done
    output='├'
    for cell in "${cells[@]}"; do
      output+="$rule┼"
    done
    output="${output%┼}┤"
    print -r -- "$output$TERMUSE_MD_RESET"
  else
    print -n -- "$TERMUSE_MD_GRAY│$TERMUSE_MD_RESET"
    for cell in "${cells[@]}"; do
      cleaned="${cell##[[:space:]]#}"
      cleaned="${cleaned%%[[:space:]]#}"
      _termuse_markdown_fit_cell "$cleaned" "$cell_width"
      display="$REPLY"
      pad=$(( cell_width - TERMUSE_MD_CELL_WIDTH_USED ))
      padding=''
      for (( j = 0; j < pad; j++ )); do
        padding+=' '
      done
      if (( TERMUSE_MD_TABLE_ROWS == 0 )); then
        TERMUSE_MD_BLOCK_STYLE="$TERMUSE_MD_BOLD$TERMUSE_MD_CYAN"
        print -n -- " $TERMUSE_MD_BLOCK_STYLE"
      else
        TERMUSE_MD_BLOCK_STYLE=''
        print -n -- ' '
      fi
      _termuse_markdown_inline_feed "$display"
      _termuse_markdown_inline_finish
      print -n -r -- "$padding"
      print -n -- " $TERMUSE_MD_GRAY│$TERMUSE_MD_RESET"
    done
    TERMUSE_MD_BLOCK_STYLE=''
    print
    (( TERMUSE_MD_TABLE_ROWS++ ))
  fi
}

_termuse_markdown_stream_feed() {
  emulate -L zsh
  setopt extendedglob
  local text="$1" char content stripped leading='' remainder='' marker='' quote_prefix=''
  local -i i quote_count=0
  local -a match

  if (( ! TERMUSE_MD_RENDER )); then
    print -n -r -- "$text"
    [[ -n "$text" ]] && TERMUSE_MD_WROTE_ANY=1
    [[ "$text" == *$'\n' ]] && TERMUSE_MD_LAST_NEWLINE=1 || TERMUSE_MD_LAST_NEWLINE=0
    return 0
  fi

  for (( i = 1; i <= ${#text}; i++ )); do
    char="${text[$i]}"

    if [[ "$TERMUSE_MD_MODE" == 'table' ]]; then
      if [[ "$char" == $'\n' ]]; then
        _termuse_markdown_table_line "$TERMUSE_MD_PENDING"
        TERMUSE_MD_PENDING=''
        TERMUSE_MD_MODE='prefix'
        TERMUSE_MD_WROTE_ANY=1
        TERMUSE_MD_LAST_NEWLINE=1
      else
        TERMUSE_MD_PENDING+="$char"
      fi
      continue
    fi

    if [[ "$TERMUSE_MD_MODE" == 'fence' ]]; then
      if [[ "$char" == $'\n' ]]; then
        if (( TERMUSE_MD_IN_MARKDOWN_FENCE )); then
          TERMUSE_MD_IN_MARKDOWN_FENCE=0
        elif [[ "${(L)TERMUSE_MD_PENDING}" == 'markdown' ||
                "${(L)TERMUSE_MD_PENDING}" == 'md' ]]; then
          TERMUSE_MD_IN_MARKDOWN_FENCE=1
        elif (( TERMUSE_MD_IN_CODE )); then
          print -r -- "${TERMUSE_MD_FENCE_INDENT}${TERMUSE_MD_GRAY}└─${TERMUSE_MD_RESET}"
          TERMUSE_MD_IN_CODE=0
        else
          print -r -- "${TERMUSE_MD_FENCE_INDENT}${TERMUSE_MD_GRAY}┌─ ${TERMUSE_MD_CYAN}${TERMUSE_MD_PENDING:-code}${TERMUSE_MD_RESET}"
          TERMUSE_MD_IN_CODE=1
        fi
        TERMUSE_MD_PENDING=''
        TERMUSE_MD_MODE='prefix'
        TERMUSE_MD_WROTE_ANY=1
        TERMUSE_MD_LAST_NEWLINE=1
      else
        TERMUSE_MD_PENDING+="$char"
      fi
      continue
    fi

    if [[ "$TERMUSE_MD_MODE" == 'text' ]]; then
      if [[ "$char" == $'\n' ]]; then
        if (( TERMUSE_MD_IN_CODE )); then
          print -n -- "$TERMUSE_MD_RESET"
        else
          _termuse_markdown_inline_finish
          print -n -- "$TERMUSE_MD_RESET"
        fi
        print
        TERMUSE_MD_MODE='prefix'
        TERMUSE_MD_PENDING=''
        TERMUSE_MD_BLOCK_STYLE=''
        TERMUSE_MD_LAST_NEWLINE=1
      else
        if (( TERMUSE_MD_IN_CODE )); then
          print -n -r -- "$char"
        else
          _termuse_markdown_inline_feed "$char"
        fi
        TERMUSE_MD_LAST_NEWLINE=0
      fi
      TERMUSE_MD_WROTE_ANY=1
      continue
    fi

    if [[ "$char" == $'\n' ]]; then
      content="$TERMUSE_MD_PENDING"
      stripped="$content"
      leading=''
      while [[ "$stripped" == ' '* ]]; do
        leading+=' '
        stripped="${stripped[2,-1]}"
      done
      if [[ "$stripped" == '---' || "$stripped" == '***' || "$stripped" == '___' ]]; then
        print -r -- "${leading}${TERMUSE_MD_GRAY}────────────────────────────────────────${TERMUSE_MD_RESET}"
      elif [[ "$stripped" =~ '^={3,}$' ]]; then
        print -r -- "${leading}${TERMUSE_MD_MAGENTA}════════════════════════════════════════${TERMUSE_MD_RESET}"
      else
        (( TERMUSE_MD_IN_CODE )) && print -n -- "$TERMUSE_MD_CODE"
        print -r -- "$content$TERMUSE_MD_RESET"
      fi
      TERMUSE_MD_PENDING=''
      TERMUSE_MD_MODE='prefix'
      TERMUSE_MD_TABLE_ROWS=0
      TERMUSE_MD_WROTE_ANY=1
      TERMUSE_MD_LAST_NEWLINE=1
      continue
    fi

    TERMUSE_MD_PENDING+="$char"
    stripped="$TERMUSE_MD_PENDING"
    leading=''
    while [[ "$stripped" == ' '* ]]; do
      leading+=' '
      stripped="${stripped[2,-1]}"
    done
    [[ -z "$stripped" ]] && continue

    if (( TERMUSE_MD_IN_CODE )); then
      if [[ "$stripped" == '```' ]]; then
        TERMUSE_MD_PENDING=''
        TERMUSE_MD_FENCE_INDENT="$leading"
        TERMUSE_MD_MODE='fence'
      elif [[ '```' == "$stripped"* ]]; then
        continue
      else
        print -n -- "$TERMUSE_MD_CODE"
        print -n -r -- "$TERMUSE_MD_PENDING"
        TERMUSE_MD_PENDING=''
        TERMUSE_MD_MODE='text'
        TERMUSE_MD_WROTE_ANY=1
        TERMUSE_MD_LAST_NEWLINE=0
      fi
      continue
    fi

    if [[ "$stripped" == '|' ]]; then
      TERMUSE_MD_MODE='table'
      continue
    fi

    case "$stripped" in
      '# '|'## '|'### '|'#### '|'##### '|'###### ')
        case "$stripped" in
          '# ') TERMUSE_MD_BLOCK_STYLE="$TERMUSE_MD_H1" ;;
          '## ') TERMUSE_MD_BLOCK_STYLE="$TERMUSE_MD_H2" ;;
          '### ') TERMUSE_MD_BLOCK_STYLE="$TERMUSE_MD_H3" ;;
          '#### ') TERMUSE_MD_BLOCK_STYLE="$TERMUSE_MD_H4" ;;
          '##### ') TERMUSE_MD_BLOCK_STYLE="$TERMUSE_MD_H5" ;;
          *) TERMUSE_MD_BLOCK_STYLE="$TERMUSE_MD_H6" ;;
        esac
        print -n -r -- "$leading"
        print -n -- "$TERMUSE_MD_BLOCK_STYLE"
        TERMUSE_MD_PENDING=''
        TERMUSE_MD_MODE='text'
        ;;
      '#'|'##'|'###'|'####'|'#####'|'######')
        continue
        ;;
      '```')
        TERMUSE_MD_PENDING=''
        TERMUSE_MD_FENCE_INDENT="$leading"
        TERMUSE_MD_MODE='fence'
        ;;
      '-'|'*'|'+ '|'- '|'* '|'+'|'- ['|'* ['|'+ ['|'- [ '|'* [ '|'+ [ '|'- [x'|'* [x'|'+ [x'|'- [X'|'* [X'|'+ [X'|'- [ ]'|'* [ ]'|'+ [ ]'|'- [x]'|'* [x]'|'+ [x]'|'- [X]'|'* [X]'|'+ [X]')
        continue
        ;;
      '- [ ] '|'* [ ] '|'+ [ ] ')
        print -n -r -- "$leading"
        print -n -- "$TERMUSE_MD_GRAY☐$TERMUSE_MD_RESET "
        TERMUSE_MD_PENDING=''
        TERMUSE_MD_MODE='text'
        ;;
      '- [x] '|'* [x] '|'+ [x] '|'- [X] '|'* [X] '|'+ [X] ')
        print -n -r -- "$leading"
        print -n -- "$TERMUSE_MD_GREEN☑$TERMUSE_MD_RESET "
        TERMUSE_MD_PENDING=''
        TERMUSE_MD_MODE='text'
        ;;
      '---'|'***'|'___')
        continue
        ;;
      '='|'=='|'==='|'===='|'====='|'======'|'-'|'--'|'**'|'__'|'`'|'``'|'>'|'> ')
        continue
        ;;
      *)
        if [[ "$stripped" =~ '^=+$' ]]; then
          continue
        elif [[ "${stripped[1,2]}" == '- ' || "${stripped[1,2]}" == '* ' ||
                "${stripped[1,2]}" == '+ ' ]]; then
          remainder="${stripped[3,-1]}"
          print -n -r -- "$leading"
          print -n -- "$TERMUSE_MD_CYAN•$TERMUSE_MD_RESET "
          TERMUSE_MD_PENDING=''
          TERMUSE_MD_MODE='text'
          _termuse_markdown_inline_feed "$remainder"
        elif [[ "$stripped" =~ '^([0-9]+)([.)])[[:space:]](.*)$' ]]; then
          marker="$match[1]$match[2]"
          remainder="$match[3]"
          if [[ -z "$remainder" ]]; then
            continue
          fi
          print -n -r -- "$leading"
          print -n -- "$TERMUSE_MD_YELLOW$marker$TERMUSE_MD_RESET "
          TERMUSE_MD_PENDING=''
          TERMUSE_MD_MODE='text'
          _termuse_markdown_inline_feed "$remainder"
        elif [[ "$stripped" =~ '^[0-9]+[.)]?$' ]]; then
          continue
        else
          quote_count=0
          remainder="$stripped"
          while [[ "$remainder" == '> '* ]]; do
            (( quote_count++ ))
            remainder="${remainder[3,-1]}"
          done
          if (( quote_count > 0 )); then
            if [[ -z "$remainder" || "$remainder" =~ '^(>[[:space:]]*)+$' ]]; then
              continue
            fi
            print -n -r -- "$leading"
            quote_prefix=''
            while (( quote_count-- > 0 )); do
              quote_prefix+="${TERMUSE_MD_MAGENTA}│${TERMUSE_MD_RESET} "
            done
            print -n -- "$quote_prefix$TERMUSE_MD_DIM"
            TERMUSE_MD_BLOCK_STYLE="$TERMUSE_MD_DIM"
            TERMUSE_MD_PENDING=''
            TERMUSE_MD_MODE='text'
            _termuse_markdown_inline_feed "$remainder"
          else
            TERMUSE_MD_TABLE_ROWS=0
            TERMUSE_MD_PENDING=''
            TERMUSE_MD_MODE='text'
            _termuse_markdown_inline_feed "$leading$stripped"
          fi
        fi
        TERMUSE_MD_WROTE_ANY=1
        TERMUSE_MD_LAST_NEWLINE=0
        ;;
    esac
  done
}

_termuse_markdown_stream_finish() {
  emulate -L zsh

  if [[ "$TERMUSE_MD_MODE" == 'fence' ]]; then
    if (( TERMUSE_MD_IN_MARKDOWN_FENCE )); then
      TERMUSE_MD_IN_MARKDOWN_FENCE=0
    elif [[ "${(L)TERMUSE_MD_PENDING}" == 'markdown' ||
            "${(L)TERMUSE_MD_PENDING}" == 'md' ]]; then
      TERMUSE_MD_IN_MARKDOWN_FENCE=1
    elif (( TERMUSE_MD_IN_CODE )); then
      print -r -- "${TERMUSE_MD_FENCE_INDENT}${TERMUSE_MD_GRAY}└─${TERMUSE_MD_RESET}"
      TERMUSE_MD_IN_CODE=0
    else
      print -r -- "${TERMUSE_MD_FENCE_INDENT}${TERMUSE_MD_GRAY}┌─ ${TERMUSE_MD_CYAN}${TERMUSE_MD_PENDING:-code}${TERMUSE_MD_RESET}"
      TERMUSE_MD_IN_CODE=1
    fi
    TERMUSE_MD_PENDING=''
    TERMUSE_MD_LAST_NEWLINE=1
  elif [[ "$TERMUSE_MD_MODE" == 'table' ]]; then
    _termuse_markdown_table_line "$TERMUSE_MD_PENDING"
    TERMUSE_MD_PENDING=''
    TERMUSE_MD_LAST_NEWLINE=1
  elif [[ -n "$TERMUSE_MD_PENDING" ]]; then
    if (( TERMUSE_MD_IN_CODE )); then
      print -n -- "$TERMUSE_MD_CODE"
      print -n -r -- "$TERMUSE_MD_PENDING"
    else
      _termuse_markdown_inline_feed "$TERMUSE_MD_PENDING"
      _termuse_markdown_inline_finish
    fi
    TERMUSE_MD_PENDING=''
    TERMUSE_MD_LAST_NEWLINE=0
  fi

  [[ "$TERMUSE_MD_MODE" == 'text' && $TERMUSE_MD_IN_CODE -eq 0 ]] && _termuse_markdown_inline_finish
  print -n -- "$TERMUSE_MD_RESET"
  (( TERMUSE_MD_IN_CODE )) && print -r -- "${TERMUSE_MD_FENCE_INDENT}${TERMUSE_MD_GRAY}└─${TERMUSE_MD_RESET}"
  (( TERMUSE_MD_WROTE_ANY && ! TERMUSE_MD_LAST_NEWLINE )) && print
  return 0
}

_termuse_stream_emit() {
  local text="$1"
  [[ -n "$text" ]] || return 0
  print -n -r -- "$text" >> "$TERMUSE_STREAM_OUTPUT_FILE"
  _termuse_markdown_stream_feed "$text"
  TERMUSE_STREAM_AT_START=0
  [[ "$text" == *$'\n' ]] && TERMUSE_STREAM_LAST_NEWLINE=1 || TERMUSE_STREAM_LAST_NEWLINE=0
}

_termuse_stream_warning() {
  (( TERMUSE_STREAM_WARNED )) && return 0
  local warning='> Termuse blocked an attempted OpenCode tool call. No command was executed.'
  (( ! TERMUSE_STREAM_AT_START && ! TERMUSE_STREAM_LAST_NEWLINE )) && _termuse_stream_emit $'\n'
  _termuse_stream_emit "$warning"$'\n'
  TERMUSE_STREAM_WARNED=1
}

_termuse_stream_filter_start() {
  typeset -g TERMUSE_STREAM_OUTPUT_FILE="$1"
  typeset -g TERMUSE_STREAM_BUFFER=''
  typeset -g TERMUSE_STREAM_BLOCK_KIND=''
  typeset -gi TERMUSE_STREAM_WARNED=0
  typeset -gi TERMUSE_STREAM_AT_START=1
  typeset -gi TERMUSE_STREAM_LAST_NEWLINE=1
  : >| "$TERMUSE_STREAM_OUTPUT_FILE"
  _termuse_markdown_stream_start
}

_termuse_stream_filter_feed() {
  emulate -L zsh
  local delta="$1" pattern found='' emitted='' ending
  local -a patterns=('<tool_call' '\<tool_call' '<function=' '\<function=' '<parameter=' '\<parameter=')
  local -a endings
  local -i partial

  TERMUSE_STREAM_BUFFER+="$delta"
  while [[ -n "$TERMUSE_STREAM_BUFFER" ]]; do
    if [[ -n "$TERMUSE_STREAM_BLOCK_KIND" ]]; then
      case "$TERMUSE_STREAM_BLOCK_KIND" in
        tool) endings=('</tool_call>' '\</tool_call>') ;;
        function) endings=('</function>' '\</function>' '</tool_call>' '\</tool_call>') ;;
        parameter) endings=('</parameter>' '\</parameter>' '</tool_call>' '\</tool_call>') ;;
      esac
      found=''
      for ending in "${endings[@]}"; do
        if [[ "$TERMUSE_STREAM_BUFFER" == *"$ending"* ]]; then
          found="$ending"
          break
        fi
      done
      if [[ -n "$found" ]]; then
        TERMUSE_STREAM_BUFFER="${TERMUSE_STREAM_BUFFER#*"$found"}"
        TERMUSE_STREAM_BLOCK_KIND=''
        continue
      fi
      if (( ${#TERMUSE_STREAM_BUFFER} > 20 )); then
        TERMUSE_STREAM_BUFFER="${TERMUSE_STREAM_BUFFER[-20,-1]}"
      fi
      break
    fi

    found=''
    for pattern in "${patterns[@]}"; do
      if [[ "$TERMUSE_STREAM_BUFFER" == "$pattern"* ]]; then
        found="$pattern"
        break
      fi
    done
    if [[ -n "$found" ]]; then
      [[ -n "$emitted" ]] && _termuse_stream_emit "$emitted"
      emitted=''
      TERMUSE_STREAM_BUFFER="${TERMUSE_STREAM_BUFFER#"$found"}"
      case "$found" in
        *tool_call) TERMUSE_STREAM_BLOCK_KIND='tool' ;;
        *function=) TERMUSE_STREAM_BLOCK_KIND='function' ;;
        *) TERMUSE_STREAM_BLOCK_KIND='parameter' ;;
      esac
      _termuse_stream_warning
      continue
    fi

    partial=0
    for pattern in "${patterns[@]}"; do
      if [[ "$pattern" == "$TERMUSE_STREAM_BUFFER"* ]]; then
        partial=1
        break
      fi
    done
    (( partial )) && break

    emitted+="${TERMUSE_STREAM_BUFFER[1]}"
    TERMUSE_STREAM_BUFFER="${TERMUSE_STREAM_BUFFER[2,-1]}"
  done

  [[ -n "$emitted" ]] && _termuse_stream_emit "$emitted"
  return 0
}

_termuse_stream_filter_finish() {
  if [[ -z "$TERMUSE_STREAM_BLOCK_KIND" && -n "$TERMUSE_STREAM_BUFFER" ]]; then
    _termuse_stream_emit "$TERMUSE_STREAM_BUFFER"
  fi
  TERMUSE_STREAM_BUFFER=''
  _termuse_markdown_stream_finish
}

_termuse_stream_request() {
  emulate -L zsh
  unsetopt monitor notify
  setopt localtraps
  local prompt="$1" output_file="$2"
  local request_dir server_log event_fifo base line data session_json session_id body escaped_prompt
  local part_json part_id part_type delta full_text actual_model provider_id model_id error_message=''
  local -i server_pid=0 event_pid=0 event_fd=-1 ready=0 connected=0 completed=0 request_ok=0
  local -i attempt i started=$SECONDS got_assistant=0
  local -A text_parts received_parts

  request_dir="$(command mktemp -d "${TMPDIR:-/tmp}/termuse-request.XXXXXX")" || return 1
  server_log="$request_dir/server.log"
  event_fifo="$request_dir/events"
  command mkfifo "$event_fifo" || return 1

  {
    for (( attempt = 1; attempt <= 4; attempt++ )); do
      local -i port=$(( 30000 + RANDOM % 20000 ))
      base="http://127.0.0.1:$port"
      OPENCODE_SERVER_PASSWORD='' OPENCODE_SERVER_USERNAME='' \
        OPENCODE_CONFIG_CONTENT="$TERMUSE_OPENCODE_CONFIG" \
        opencode serve --hostname 127.0.0.1 --port "$port" >| "$server_log" 2>&1 &
      server_pid=$!
      ready=0
      for (( i = 1; i <= 60; i++ )); do
        if command curl --noproxy '*' -fsS --max-time 1 "$base/global/health" >/dev/null 2>&1; then
          ready=1
          break
        fi
        kill -0 "$server_pid" 2>/dev/null || break
        sleep 0.1
      done
      (( ready )) && break
      kill "$server_pid" 2>/dev/null || true
      wait "$server_pid" 2>/dev/null || true
      server_pid=0
    done

    if (( ! ready )); then
      print -u2 -r -- 'Termuse: could not start the OpenCode streaming server.'
      [[ -s "$server_log" ]] && command sed -n '1,5p' "$server_log" >&2
    else
      command curl --noproxy '*' -NsS --no-buffer "$base/event" > "$event_fifo" 2>/dev/null &
      event_pid=$!
      exec {event_fd}<"$event_fifo"

      for (( i = 1; i <= 100; i++ )); do
        if IFS= read -r -t 0.1 line <&$event_fd; then
          if [[ "$line" == data:*'"type":"server.connected"'* ]]; then
            connected=1
            break
          fi
        elif ! kill -0 "$event_pid" 2>/dev/null; then
          break
        fi
      done

      if (( ! connected )); then
        print -u2 -r -- 'Termuse: could not connect to the OpenCode event stream.'
      else
        session_json="$(command curl --noproxy '*' -fsS --max-time 15 \
          -H 'content-type: application/json' -d '{}' "$base/session")" || session_json=''
        if _termuse_json_string_field "$session_json" id; then
          session_id="$REPLY"
        else
          session_id=''
        fi

        if [[ -z "$session_id" ]]; then
          print -u2 -r -- 'Termuse: could not create an OpenCode session.'
        else
          escaped_prompt="$(_termuse_json_escape "$prompt")"
          body='{"agent":"termuse"'
          if [[ -n "$TERMUSE_MODEL" && "$TERMUSE_MODEL" == */* ]]; then
            provider_id="${TERMUSE_MODEL%%/*}"
            model_id="${TERMUSE_MODEL#*/}"
            body+=',"model":{"providerID":"'"$(_termuse_json_escape "$provider_id")"'","modelID":"'"$(_termuse_json_escape "$model_id")"'"}'
          fi
          body+=',"parts":[{"type":"text","text":"'"$escaped_prompt"'"}]}'

          _termuse_stream_filter_start "$output_file"
          if command curl --noproxy '*' -fsS --max-time 30 -o /dev/null \
              -H 'content-type: application/json' -d "$body" \
              "$base/session/$session_id/prompt_async"; then
            request_ok=1
          else
            print -u2 -r -- 'Termuse: could not send the OpenCode request.'
          fi

          while (( request_ok && ! completed && SECONDS - started < 600 )); do
            if ! IFS= read -r -t 30 line <&$event_fd; then
              kill -0 "$event_pid" 2>/dev/null || break
              continue
            fi
            [[ "$line" == data:* ]] || continue
            data="${line#data: }"
            [[ "$data" == *"\"sessionID\":\"$session_id\""* ]] || continue

            if [[ "$data" == *'"type":"message.updated"'* &&
                  "$data" == *'"role":"assistant"'* && $got_assistant -eq 0 ]]; then
              _termuse_json_string_field "$data" providerID && provider_id="$REPLY" || provider_id=''
              _termuse_json_string_field "$data" modelID && model_id="$REPLY" || model_id=''
              actual_model="${provider_id:+$provider_id/}${model_id:-unknown}"
              if [[ -t 1 ]]; then
                print
                print -r -- "> termuse · $actual_model"
                print
              fi
              got_assistant=1
            elif [[ "$data" == *'"type":"message.part.updated"'* ]]; then
              part_json="${data#*\"part\":\{}"
              _termuse_json_string_field "$part_json" id && part_id="$REPLY" || part_id=''
              _termuse_json_string_field "$part_json" type && part_type="$REPLY" || part_type=''
              if [[ "$part_type" == 'text' && -n "$part_id" ]]; then
                text_parts[$part_id]=1
                if [[ "$part_json" == *'"end":'* && -z "${received_parts[$part_id]:-}" ]]; then
                  _termuse_json_string_field "$part_json" text && full_text="$REPLY" || full_text=''
                  [[ -n "$full_text" ]] && _termuse_stream_filter_feed "$full_text"
                fi
              elif [[ "$part_type" == 'tool' ]]; then
                _termuse_stream_warning
              fi
            elif [[ "$data" == *'"type":"message.part.delta"'* ]]; then
              _termuse_json_string_field "$data" partID && part_id="$REPLY" || part_id=''
              if [[ -n "$part_id" && -n "${text_parts[$part_id]:-}" ]]; then
                _termuse_json_string_field "$data" delta && delta="$REPLY" || delta=''
                if [[ -n "$delta" ]]; then
                  received_parts[$part_id]=1
                  _termuse_stream_filter_feed "$delta"
                fi
              fi
            elif [[ "$data" == *'"type":"session.error"'* ]]; then
              _termuse_json_string_field "$data" message && error_message="$REPLY" || error_message='OpenCode session error'
              completed=1
              request_ok=0
            elif [[ "$data" == *'"type":"session.status"'*'"status":{"type":"idle"'* ||
                    "$data" == *'"type":"session.idle"'* ]]; then
              completed=1
            fi
          done

          _termuse_stream_filter_finish
          if [[ -n "$error_message" ]]; then
            print -u2 -r -- "Termuse: $error_message"
          elif (( request_ok && ! completed )); then
            print -u2 -r -- 'Termuse: the OpenCode stream ended before completion.'
            request_ok=0
          fi
        fi
      fi
    fi
  } always {
    if (( event_fd >= 0 )); then
      exec {event_fd}<&-
    fi
    (( event_pid > 0 )) && kill "$event_pid" 2>/dev/null || true
    (( server_pid > 0 )) && kill "$server_pid" 2>/dev/null || true
    (( event_pid > 0 )) && wait "$event_pid" 2>/dev/null || true
    (( server_pid > 0 )) && wait "$server_pid" 2>/dev/null || true
    command rm -f -- "$event_fifo" "$server_log"
    command rmdir "$request_dir" 2>/dev/null || true
  }

  (( request_ok && completed ))
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

_termuse_print_command_preview() {
  emulate -L zsh
  local command_text="$1" line

  print
  print -r -- "${TERMUSE_MD_CYAN}Suggested command (review before running):${TERMUSE_MD_RESET}"
  print
  for line in ${(f)command_text}; do
    print -r -- "${TERMUSE_MD_CYAN}>${TERMUSE_MD_RESET} ${TERMUSE_MD_CODE}${line}${TERMUSE_MD_RESET}"
  done
  print
}

_termuse_offer_command() {
  emulate -L zsh
  local response="$1" command_text

  command_text="$(_termuse_extract_shell_block "$response")" || return 0
  [[ -z "$command_text" ]] && return 0

  _termuse_print_command_preview "$command_text"
  _termuse_select 'Run the command shown above?' 'No' 'Yes' || return 0
  (( TERMUSE_SELECTION == 2 )) || return 0

  if _termuse_is_dangerous "$command_text"; then
    print
    print -u2 -r -- "${TERMUSE_MD_RED}⚠ Warning: this command may be destructive.${TERMUSE_MD_RESET}"
    _termuse_select 'Execute the destructive command?' 'Cancel' 'Execute' || return 0
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
  local question="$*" prompt response exit_code tmp_file

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

  _termuse_stream_request "$prompt" "$tmp_file"
  exit_code=$?
  response="$(<"$tmp_file")"

  if (( exit_code != 0 )); then
    print -u2 -r -- 'Termuse: OpenCode streaming request failed.'
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
