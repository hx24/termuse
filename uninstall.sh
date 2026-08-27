#!/bin/zsh

emulate -L zsh
setopt errexit nounset pipefail

typeset install_dir="$HOME/.termuse"
typeset config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/termuse"
typeset zshrc="$HOME/.zshrc"
typeset source_line='source "$HOME/.termuse/termuse.zsh"'
typeset marker_start='# >>> Termuse >>>'
typeset marker_end='# <<< Termuse <<<'

_termuse_choose_config_removal() {
  emulate -L zsh
  local key sequence
  local -i selected=1 rendered=3
  local -a choices=('Keep configuration' 'Remove configuration')

  if [[ ! -t 0 || ! -t 1 ]]; then
    print -r -- "Remove saved model configuration? ${choices[1]}"
    return 1
  fi

  while true; do
    print -r -- 'Remove saved model configuration? (↑/↓, Enter)'
    if (( selected == 1 )); then
      print -r -- $'\e[36m❯\e[0m '"${choices[1]}"
      print -r -- "  ${choices[2]}"
    else
      print -r -- "  ${choices[1]}"
      print -r -- $'\e[36m❯\e[0m '"${choices[2]}"
    fi

    if ! read -rs -k1 key; then
      print -n -- $'\e['"$rendered"'A\r\e[J'
      print -r -- "Remove saved model configuration? ${choices[1]}"
      return 1
    fi
    case "$key" in
      $'\e')
        sequence=""
        read -rs -k2 sequence || true
        case "$sequence" in
          '[A'|'OA'|'[B'|'OB') (( selected = 3 - selected )) ;;
        esac
        print -n -- $'\e['"$rendered"'A\r\e[J'
        ;;
      $'\n'|$'\r'|'')
        print -n -- $'\e['"$rendered"'A\r\e[J'
        print -r -- "Remove saved model configuration? ${choices[$selected]}"
        (( selected == 2 ))
        return
        ;;
      *)
        print -n -- $'\e['"$rendered"'A\r\e[J'
        ;;
    esac
  done
}

if [[ "$install_dir" == "$HOME/.termuse" && -e "$install_dir" ]]; then
  command rm -rf -- "$install_dir"
fi

if [[ -f "$zshrc" ]]; then
  typeset tmp_file mode line
  typeset -i in_block=0
  typeset -a unterminated_block
  tmp_file="$(command mktemp "${zshrc:h}/.termuse-zshrc.XXXXXX")"
  trap 'command rm -f -- "$tmp_file"' EXIT HUP INT TERM
  mode="$(command stat -f '%Lp' "$zshrc")"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( in_block )); then
      if [[ "$line" == *"$marker_end"* ]]; then
        in_block=0
        unterminated_block=()
      else
        unterminated_block+=("$line")
      fi
      continue
    fi

    if [[ "$line" == *"$marker_start"* && "$line" == *"$marker_end"* ]]; then
      continue
    fi
    if [[ "$line" == *"$marker_start"* ]]; then
      in_block=1
      unterminated_block=()
      continue
    fi
    if [[ "$line" == *"$source_line"* || "$line" == *'source ~/.termuse/termuse.zsh'* ]]; then
      continue
    fi
    print -r -- "$line" >> "$tmp_file"
  done < "$zshrc"

  if (( in_block )); then
    for line in "${unterminated_block[@]}"; do
      print -r -- "$line" >> "$tmp_file"
    done
  fi

  command chmod "$mode" "$tmp_file"
  command mv -- "$tmp_file" "$zshrc"
  trap - EXIT HUP INT TERM
fi

if [[ -d "$config_dir" ]]; then
  if _termuse_choose_config_removal; then
    if [[ "$config_dir" == "${XDG_CONFIG_HOME:-$HOME/.config}/termuse" ]]; then
      command rm -rf -- "$config_dir"
    fi
  fi
fi

print -r -- 'Termuse uninstalled. Open a new terminal to finish cleanup.'
