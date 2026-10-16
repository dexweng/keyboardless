#!/bin/bash
set -euo pipefail
script_path="${BASH_SOURCE[0]}"
while [ -L "$script_path" ]; do
  script_dir="$(cd "$(dirname "$script_path")" && pwd)"
  script_path="$(readlink "$script_path")"
  case "$script_path" in /*) ;; *) script_path="$script_dir/$script_path" ;; esac
done
cd "$(dirname "$script_path")"
echo '請在 keyboardless 的設定頁輸入自己的金鑰；金鑰會存入 macOS Keychain。'
bash start-mac.command
