#!/bin/bash
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
script_path="${BASH_SOURCE[0]}"
while [ -L "$script_path" ]; do
  script_dir="$(cd "$(dirname "$script_path")" && pwd)"
  script_path="$(readlink "$script_path")"
  case "$script_path" in /*) ;; *) script_path="$script_dir/$script_path" ;; esac
done
cd "$(dirname "$script_path")"
if curl -fsS --max-time 2 http://127.0.0.1:3018/api/config | /usr/bin/grep -q '"provider":"OpenAI"'; then
 open http://127.0.0.1:3018
 exit 0
fi
command -v ffmpeg >/dev/null || { echo '缺少 ffmpeg，請先安裝後再啟動。'; read -r; exit 1; }
[ -d node_modules ] || npm ci
npm run build
echo '語音實驗室 → http://127.0.0.1:3018'
echo '關閉此視窗可停止服務。'
(sleep 2; open http://127.0.0.1:3018) &
npm start
