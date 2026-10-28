#!/bin/sh
# 隔离回归：用固定夹具验证菜单栏程序的解析与口径，不读真实账号数据。
#
# 可用环境变量：
#   APP_PATH  已构建的 .app 路径，默认 $HOME/Applications/My Metric.app
#   BIN_NAME  可执行文件名，默认 MyMetric
#   FIXTURE   夹具路径，默认本脚本同目录 template_fixture.json
#
# 用法：sh template_test.sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_PATH="${APP_PATH:-$HOME/Applications/My Metric.app}"
BIN_NAME="${BIN_NAME:-MyMetric}"
BIN="$APP_PATH/Contents/MacOS/$BIN_NAME"
FIXTURE="${FIXTURE:-$ROOT/template_fixture.json}"

if [ ! -x "$BIN" ]; then
    echo "FAIL 未找到已构建的二进制：$BIN（先运行 template_build_app.sh）" >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/menu-bar-metric-test.XXXXXX")"
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

TODAY="$(date +%Y-%m-%d)"
mkdir -p "$WORK/api"
sed "s/__TODAY__/$TODAY/g" "$FIXTURE" > "$WORK/api/token-stats"

PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

(cd "$WORK" && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl --noproxy '*' -sf -o /dev/null "http://127.0.0.1:$PORT/api/token-stats"; then break; fi
    sleep 0.2
done

OUT="$(WB_TOKEN_API="http://127.0.0.1:$PORT/api/token-stats" "$BIN" --print-once)"

printf '%s' "$OUT" | python3 -c '
import json, sys
data = json.load(sys.stdin)
expected = {
    "workbuddy": 12345678,
    "codebuddy-cli": 900000,
    "codebuddy-ide": 0,
}
failures = []
for name, total in expected.items():
    actual = data["sources"][name]["total"]
    if actual != total:
        failures.append(f"{name} 今日总量应为 {total}，实际 {actual}")
all_total = data["all"]
if all_total != 13245678:
    failures.append(f"合计应为 13245678，实际 {all_total}")
if data["sources"]["workbuddy"]["input"] != 12000000:
    failures.append("workbuddy 输入应为 12000000")
if abs(data["sources"]["workbuddy"]["cacheHitRate"] - 0.9166666666666666) > 1e-9:
    failures.append("workbuddy 缓存命中率解析错误")
if data["sources"]["codebuddy-ide"]["cacheHitRate"] is not None:
    failures.append("空缓存命中率应为 null")
if failures:
    print("FAIL 夹具解析")
    for item in failures:
        print(" -", item)
    sys.exit(1)
print("PASS 夹具解析：三产品今日总量、合计、输入、缓存命中率均正确")
'

set +e
WB_TOKEN_API="http://127.0.0.1:1/api/token-stats" "$BIN" --print-once >/dev/null 2>"$WORK/err.txt"
CODE=$?
set -e
if [ "$CODE" -eq 0 ]; then
    echo "FAIL 后端不可达时应返回非零退出码" >&2
    exit 1
fi
echo "PASS 后端不可达：退出码 $CODE，错误信息=$(cat "$WORK/err.txt")"
