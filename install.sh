#!/bin/zsh

emulate -L zsh
setopt errexit nounset pipefail

typeset script_dir="${0:A:h}"
typeset install_dir="$HOME/.termuse"
typeset zshrc="$HOME/.zshrc"
typeset source_file="$script_dir/termuse.zsh"
typeset remote_source_url="${TERMUSE_SOURCE_URL:-https://raw.githubusercontent.com/hx24/termuse/main/termuse.zsh}"
typeset source_line='source "$HOME/.termuse/termuse.zsh"'
typeset marker_start='# >>> Termuse >>>'
typeset marker_end='# <<< Termuse <<<'

command mkdir -p -- "$install_dir"

if [[ -f "$source_file" && "${0:t}" != 'zsh' && "${0:t}" != '-zsh' ]]; then
  command cp -- "$source_file" "$install_dir/termuse.zsh"
else
  if ! command -v curl >/dev/null 2>&1; then
    print -u2 -r -- 'install.sh: curl is required for remote installation.'
    exit 1
  fi

  typeset download_file downloaded_content
  download_file="$(command mktemp "$install_dir/.termuse-download.XXXXXX")"
  trap 'command rm -f -- "$download_file"' EXIT HUP INT TERM

  if ! command curl --proto '=https' --tlsv1.2 -fsSL \
      --connect-timeout 10 --max-time 60 --retry 2 \
      "$remote_source_url" -o "$download_file"; then
    print -u2 -r -- "install.sh: could not download $remote_source_url"
    exit 1
  fi

  downloaded_content="$(<"$download_file")"
  if [[ "$downloaded_content" != '# Termuse'* ||
        "$downloaded_content" != *$'\ntermuse() {'* ]]; then
    print -u2 -r -- 'install.sh: downloaded an invalid Termuse source file.'
    exit 1
  fi

  command chmod 644 "$download_file"
  command mv -- "$download_file" "$install_dir/termuse.zsh"
  trap - EXIT HUP INT TERM
fi

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
