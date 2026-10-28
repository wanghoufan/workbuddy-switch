#!/bin/sh
# 隔离回归：用固定夹具验证菜单栏程序的解析与口径，不读真实账号数据。
# 用法：sh menubar/test.sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BIN="$HOME/Applications/WorkBuddy Token.app/Contents/MacOS/WorkBuddyToken"
FIXTURE="$ROOT/menubar/fixtures/token-stats.json"
ACCOUNTS_FIXTURE="$ROOT/menubar/fixtures/accounts-fixture.json"
SESSIONS_FIXTURE="$ROOT/menubar/fixtures/sessions-account.json"
LOG_MAIN_FIXTURE="$ROOT/menubar/fixtures/workbuddy-main.jsonl"
LOG_SUBAGENT_FIXTURE="$ROOT/menubar/fixtures/workbuddy-subagent.jsonl"
LOG_OTHER_FIXTURE="$ROOT/menubar/fixtures/workbuddy-other-account.jsonl"

if [ ! -x "$BIN" ]; then
    echo "FAIL 未找到已构建的二进制：$BIN（先运行 sh menubar/build.sh）" >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wb-token-menu-test.XXXXXX")"
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
TODAY_MS="$(python3 -c 'import time; print(int(time.time() * 1000))')"
mkdir -p "$WORK/api/sessions"
sed "s/__TODAY__/$TODAY/g" "$FIXTURE" > "$WORK/api/token-stats"
cp "$ACCOUNTS_FIXTURE" "$WORK/api/accounts"
cp "$SESSIONS_FIXTURE" "$WORK/api/sessions/account"

# 本地 WorkBuddy 日志夹具：session-fixture-1 属于当前账号（含一个子代理文件），
# session-fixture-2 属于别的账号，必须被过滤掉。
LOG_ROOT="$WORK/workbuddy"
PROJECT="$LOG_ROOT/projects/fixture-project"
mkdir -p "$PROJECT/session-fixture-1/subagents"
sed "s/__TODAY_MS__/$TODAY_MS/g" "$LOG_MAIN_FIXTURE" > "$PROJECT/session-fixture-1.jsonl"
sed "s/__TODAY_MS__/$TODAY_MS/g" "$LOG_SUBAGENT_FIXTURE" > "$PROJECT/session-fixture-1/subagents/agent-fixture-1.jsonl"
sed "s/__TODAY_MS__/$TODAY_MS/g" "$LOG_OTHER_FIXTURE" > "$PROJECT/session-fixture-2.jsonl"

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

OUT="$(WB_TOKEN_API="http://127.0.0.1:$PORT/api/token-stats" WB_WORKBUDDY_ROOT="$LOG_ROOT" "$BIN" --print-once)"

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
    failures.append(f"合计应为 13245678（不含 WorkBuddy 国际版），实际 {all_total}")
if data["sources"]["workbuddy-ai"]["total"] != 5000000:
    failures.append("WorkBuddy 国际版应单独统计为 5000000")
if data["thresholdChoices"] != [0, 30, 50, 90, 120, 150, 180, 300, 500]:
    failures.append(f"提醒阈值候选错误：{data['thresholdChoices']}")
if data["scope"] != "workbuddy-all-accounts":
    failures.append(f"统计口径应为 workbuddy-all-accounts，实际 {data['scope']}")
if data["workbuddy"] != 12345678:
    failures.append(f"接口汇总 workbuddy 应为 12345678，实际 {data['workbuddy']}")
if data["localWorkbuddy"] != 11000000:
    failures.append(f"三账号本地日志应为 11000000（含子代理与其他账号），实际 {data['localWorkbuddy']}")
if data["title"] != "work-总额度-11.0M":
    failures.append(f"标题应为 work-总额度-11.0M，实际 {data['title']}")
if data["compactTitle"] != "work-11m":
    failures.append(f"紧凑标题应为 work-11m，实际 {data['compactTitle']}")
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
print("PASS 夹具解析：三产品总量、三账号本地合计、常规/紧凑标题格式、缓存命中率均正确")
'

set +e
WB_TOKEN_API="http://127.0.0.1:1/api/token-stats" "$BIN" --print-once >/dev/null 2>"$WORK/err.txt"
CODE=$?
set -e
if [ "$CODE" -eq 0 ]; then
    echo "FAIL 后端不可达时应返回非零退出码" >&2
    exit 1
fi
echo "PASS 后端不可达：退出码 ${CODE}，错误信息=$(cat "$WORK/err.txt")"
