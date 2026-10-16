#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
script_path="${BASH_SOURCE[0]}"
while [ -L "$script_path" ]; do
  script_dir="$(cd "$(dirname "$script_path")" && pwd)"
  script_path="$(readlink "$script_path")"
  case "$script_path" in /*) ;; *) script_path="$script_dir/$script_path" ;; esac
done
cd "$(dirname "$script_path")"
APP="$PWD/macos/build/keyboardless.app"
if [ ! -x "$APP/Contents/MacOS/DexVoice" ]; then
  bash macos/scripts/build.sh
fi
if [ ! -d node_modules ]; then npm ci; fi
if [ ! -f public/client.js ]; then npm run build; fi
umask 077
mkdir -p .local
service_ready() {
  curl -fsS --max-time 2 http://127.0.0.1:3018/api/config | node -e '
    let input=""; process.stdin.on("data", c=>input+=c);
    process.stdin.on("end",()=>{try {const c=JSON.parse(input);process.exit(c.app==="dex-voice-pilot" && c.nativeProtocol===1 && typeof c.keySource==="string" ? 0 : 1)} catch {process.exit(1)}});'
}
if ! service_ready 2>/dev/null; then
  nohup node --import tsx src/server.ts --port 3018 >> .local/mac-service.log 2>&1 < /dev/null &
  launcher_pid=$!
  printf '%s\n' "$launcher_pid" > .local/launcher-service.pid
  for attempt in {1..30}; do
    service_ready 2>/dev/null && break
    kill -0 "$launcher_pid" 2>/dev/null || break
    sleep 0.5
  done
  if ! service_ready 2>/dev/null; then
    echo '本機服務尚未就緒，請檢查 3018 是否被其他程式占用及 .local/mac-service.log。'
    exit 1
  fi
fi
if [ "${1:-}" != "--service-only" ]; then open "$APP"; fi
