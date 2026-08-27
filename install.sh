#!/bin/zsh

emulate -L zsh
setopt errexit nounset pipefail

typeset script_dir="${0:A:h}"
typeset install_dir="$HOME/.termuse"
typeset zshrc="$HOME/.zshrc"
typeset source_line='source "$HOME/.termuse/termuse.zsh"'
typeset marker_start='# >>> Termuse >>>'
typeset marker_end='# <<< Termuse <<<'

if [[ ! -f "$script_dir/termuse.zsh" ]]; then
  print -u2 -r -- "install.sh: termuse.zsh not found in $script_dir"
  exit 1
fi

command mkdir -p -- "$install_dir"
command cp -- "$script_dir/termuse.zsh" "$install_dir/termuse.zsh"
[[ -e "$zshrc" ]] || : > "$zshrc"

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

# If a user-edited marker was never closed, preserve everything after it.
if (( in_block )); then
  for line in "${unterminated_block[@]}"; do
    print -r -- "$line" >> "$tmp_file"
  done
fi

print -r -- "$marker_start" >> "$tmp_file"
print -r -- "$source_line" >> "$tmp_file"
print -r -- "$marker_end" >> "$tmp_file"

command chmod "$mode" "$tmp_file"
command mv -- "$tmp_file" "$zshrc"
trap - EXIT HUP INT TERM

print -r -- "Termuse installed in $install_dir

Run:
  source ~/.zshrc

Or open a new terminal."
