#!/usr/bin/env bash
#
# sysmon-webhook 端到端測試
#
#   sudo bash tests/e2e.sh
#
# 會實際寫入 /etc/sysmon-webhook、/usr/local/bin 與 /etc/systemd/system，
# 因此只該在容器或 CI runner 裡執行，不要在正式機器上跑。
#
# systemctl 會被同名的假腳本覆蓋（PATH 中 /usr/local/bin 優先），
# 所以不會真的 enable 任何 timer；安裝流程本身仍完整跑過一遍。
#
# 在本機以容器執行：
#   podman run --rm -v "$PWD":/w:ro debian:bookworm bash /w/tests/e2e.sh
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_DIR}/install.sh"
MON="/usr/local/bin/sysmon-webhook.sh"
CONFIG="/etc/sysmon-webhook/config.env"
SERVICE="/etc/systemd/system/sysmon-webhook.service"
TIMER="/etc/systemd/system/sysmon-webhook.timer"
WEBHOOK="https://discord.com/api/webhooks/123456789/abcDEF-_token123"

PASS=0
FAIL=0

ok()   { PASS=$(( PASS + 1 )); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf '  [FAIL] %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; }
head2() { printf '\n=== %s ===\n' "$1"; }

assert_contains() {  # 檔案 樣式 說明
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"
  else bad "$3" "在 $1 中找不到：$2"; fi
}

assert_not_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3" "$1 中不該出現：$2"
  else ok "$3"; fi
}

assert_fails() {  # 說明 指令...
  local desc="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    bad "$desc" "指令應該失敗卻成功了：${out: -120}"
  else
    ok "$desc"
  fi
}

# ---------------------------------------------------------------------------
# 環境準備
# ---------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "請以 root 執行：sudo bash tests/e2e.sh" >&2; exit 1; }
[[ -r "$INSTALL" ]] || { echo "找不到 $INSTALL" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
if ! command -v curl >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl >/dev/null 2>&1
fi
command -v curl >/dev/null 2>&1 || { echo "測試需要 curl" >&2; exit 1; }

# 讓測試訊息連到本機而不是真的打 Discord
grep -q 'discord.com' /etc/hosts || echo "127.0.0.1 discord.com" >> /etc/hosts

mkdir -p /run/systemd/system
FAKE_LOG=/tmp/systemctl-calls.log
: > "$FAKE_LOG"
cat > /usr/local/bin/systemctl <<'FAKE'
#!/bin/sh
echo "systemctl $*" >> /tmp/systemctl-calls.log
[ "$1" = "--version" ] && echo "systemd 252 (fake-for-tests)"
exit 0
FAKE
chmod +x /usr/local/bin/systemctl
hash -r

cleanup_install() { rm -rf /etc/sysmon-webhook /var/lib/sysmon-webhook; }

# ---------------------------------------------------------------------------

head2 "0. 靜態檢查"
bash -n "$INSTALL" && ok "install.sh 語法" || bad "install.sh 語法"
bash "$INSTALL" --print-monitor > /tmp/mon-check.sh 2>/dev/null
bash -n /tmp/mon-check.sh && ok "內嵌監控腳本語法" || bad "內嵌監控腳本語法"
bash "$INSTALL" --print-failure > /tmp/fail-check.sh 2>/dev/null
bash -n /tmp/fail-check.sh && ok "內嵌失敗通報腳本語法" || bad "內嵌失敗通報腳本語法"
bash "$INSTALL" --version >/dev/null 2>&1 && ok "--version 不需 root 也不報錯" || bad "--version"
bash "$INSTALL" --help >/dev/null 2>&1 && ok "--help 不需 root 也不報錯" || bad "--help"

# ---------------------------------------------------------------------------

head2 "1. 首次安裝"
cleanup_install
bash "$INSTALL" --no-test --webhook "$WEBHOOK" --name "db-01" \
  --interval 15 --disk-path "/,/tmp" --swap-threshold 80 \
  --heartbeat-url "https://hc-ping.example/abc" >/tmp/install1.log 2>&1 \
  && ok "安裝流程結束碼為 0" || bad "安裝流程" "$(tail -3 /tmp/install1.log)"

[[ -f "$CONFIG" ]] && ok "設定檔已建立" || bad "設定檔未建立"
[[ "$(stat -c '%a' "$CONFIG" 2>/dev/null)" == "600" ]] \
  && ok "設定檔權限為 600" || bad "設定檔權限" "實際為 $(stat -c '%a' "$CONFIG" 2>/dev/null)"
[[ -x "$MON" ]] && ok "監控腳本已安裝且可執行" || bad "監控腳本"
[[ -x /usr/local/bin/sysmon-webhook-failure.sh ]] && ok "失敗通報腳本已安裝" || bad "失敗通報腳本"

assert_contains "$CONFIG" "INTERVAL_MIN=15" "INTERVAL_MIN 有寫入設定檔（升級時要靠它還原間隔）"
assert_contains "$CONFIG" "SWAP_THRESHOLD=80" "swap 門檻寫入正確"
assert_contains "$TIMER"   "OnUnitActiveSec=15min" "timer 間隔正確"
assert_contains "$TIMER"   "RandomizedDelaySec=225" "多機分散偏移為間隔的四分之一"
assert_not_contains "$TIMER" "Persistent=" "未寫入對 OnUnitActiveSec 無效的 Persistent="
assert_contains "$SERVICE" "OnFailure=sysmon-webhook-failure.service" "service 有 OnFailure（監控自己掛掉才有人知道）"
assert_contains "$SERVICE" "NoNewPrivileges=yes" "service 有基本硬化"

# ---------------------------------------------------------------------------

head2 "2. 重跑＝升級，未帶的參數要沿用"
bash "$INSTALL" --no-test --name "db-01-renamed" >/tmp/install2.log 2>&1 \
  && ok "升級流程結束碼為 0" || bad "升級流程" "$(tail -3 /tmp/install2.log)"
assert_contains /tmp/install2.log "升級完成" "識別為升級而非全新安裝"
assert_contains "$TIMER"  "OnUnitActiveSec=15min" "未帶 --interval 時保留 15（不重置為 60）"
assert_contains "$CONFIG" "SWAP_THRESHOLD=80"     "未帶 --swap-threshold 時保留 80"
assert_contains "$CONFIG" "SYS_NAME=db-01-renamed" "本次帶入的 --name 有生效"
assert_not_contains /tmp/install2.log "bash_history" "升級沿用既有 webhook 時不重複提醒 history 風險"

head2 "3. CLI 參數必須蓋過設定檔"
bash "$INSTALL" --no-test --report-mode alert_only --interval 30 >/dev/null 2>&1
assert_contains "$CONFIG" "REPORT_MODE=alert_only" "--report-mode 沒有被 source 進來的舊值蓋掉"
assert_contains "$TIMER"  "OnUnitActiveSec=30min"  "--interval 沒有被舊值蓋掉"

# ---------------------------------------------------------------------------

head2 "4. payload 正確性"
if "$MON" --dry-run > /tmp/payload.json 2>/tmp/payload.err && [[ -s /tmp/payload.json ]]; then
  ok "--dry-run 結束碼為 0 且有輸出"
else
  bad "--dry-run" "$(cat /tmp/payload.err)"
fi

if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' && ok "payload 是合法 JSON 且欄位齊全" || bad "payload JSON"
import json, sys
d = json.load(open('/tmp/payload.json'))
e = d['embeds'][0]
names = [f['name'] for f in e['fields']]
for want in ('Host', 'IP', 'CPU', 'Memory', 'Swap', 'Disk', 'Load Avg'):
    assert want in names, f'缺少欄位 {want}'
assert len(e['description']) <= 4096, 'description 超過 Discord 上限'
for f in e['fields']:
    assert len(f['value']) <= 1024, f"欄位 {f['name']} 超過 Discord 上限"
PY
else
  printf '  [SKIP] JSON 驗證（此環境沒有 python3）\n'
fi

head2 "5. 單一量測失效不該讓整份報告發不出去"
sed -i 's#^DISK_PATHS=.*#DISK_PATHS=/,/definitely-not-a-real-path#' "$CONFIG"
if "$MON" --dry-run > /tmp/payload2.json 2>&1; then
  ok "掛載點不存在時仍正常結束"
else
  bad "掛載點不存在時整支腳本死掉" "$(tail -2 /tmp/payload2.json)"
fi
assert_contains /tmp/payload2.json "N/A" "取不到的掛載點顯示為 N/A"
assert_contains /tmp/payload2.json '"name": "CPU"' "其餘指標照常回報"

head2 "6. 遲滯與恢復通知"
sed -i 's#^DISK_PATHS=.*#DISK_PATHS=/#' "$CONFIG"
sed -i 's/^REPORT_MODE=.*/REPORT_MODE=alert_only/' "$CONFIG"
mkdir -p /var/lib/sysmon-webhook
echo alert > /var/lib/sysmon-webhook/state
"$MON" --dry-run > /tmp/payload3.json 2>&1
assert_contains /tmp/payload3.json "已恢復正常" "前次為 alert 時，alert_only 模式仍送出恢復通知"

# ---------------------------------------------------------------------------

head2 "7. 輸入驗證"
rm -f /tmp/PWNED
out="$(bash "$INSTALL" --no-test --webhook '"; touch /tmp/PWNED; "' 2>&1)"
if [[ -e /tmp/PWNED ]]; then bad "webhook 注入防護" "/tmp/PWNED 被建立，注入成功"
else ok "webhook 注入被格式驗證擋下"; fi

assert_fails "--name 含引號被拒絕"        bash "$INSTALL" --no-test --name 'a"b'
assert_fails "--interval 非數字被拒絕"     bash "$INSTALL" --no-test --interval abc
assert_fails "--interval 0 被拒絕"         bash "$INSTALL" --no-test --interval 0
assert_fails "--cpu-threshold 超出範圍被拒絕" bash "$INSTALL" --no-test --cpu-threshold 150
assert_fails "--report-mode 值域被檢查"    bash "$INSTALL" --no-test --report-mode nope
assert_fails "--disk-path 不存在被拒絕"    bash "$INSTALL" --no-test --disk-path /no-such-dir-xyz
assert_fails "未知參數被拒絕"              bash "$INSTALL" --no-test --nonsense

head2 "8. Discord 長度上限截斷"
mkdir -p /mnt/e2e-p{1..60}
paths="$(for i in $(seq 1 60); do printf '/mnt/e2e-p%s,' "$i"; done)"
bash "$INSTALL" --no-test --disk-path "${paths%,}" --disk-threshold 1 >/dev/null 2>&1
"$MON" --dry-run > /tmp/payload4.json 2>&1
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' && ok "60 個掛載點截斷後 JSON 仍有效且不超過上限" || bad "長度截斷"
import json
e = json.load(open('/tmp/payload4.json'))['embeds'][0]
disk = [f for f in e['fields'] if f['name'] == 'Disk'][0]['value']
assert len(disk) <= 1024, f'Disk 欄位 {len(disk)} 字元，超過 1024'
assert len(e['description']) <= 4096
assert '截斷' in disk, '應該有截斷標記'
PY
else
  printf '  [SKIP] 截斷驗證（此環境沒有 python3）\n'
fi
rmdir /mnt/e2e-p{1..60} 2>/dev/null

head2 "9. 失敗通報腳本"
timeout 90 /usr/local/bin/sysmon-webhook-failure.sh >/tmp/failnotify.log 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok "失敗通報腳本正常結束（webhook 連不上時也不該壞）" \
  || bad "失敗通報腳本結束碼 $rc" "$(tail -3 /tmp/failnotify.log)"
if [[ -s /tmp/failnotify.log ]] && grep -q 'command not found' /tmp/failnotify.log; then
  bad "失敗通報腳本有 shell 錯誤" "$(head -3 /tmp/failnotify.log)"
else
  ok "失敗通報腳本無 shell 錯誤輸出"
fi

head2 "10. 解除安裝"
bash "$INSTALL" --uninstall >/dev/null 2>&1
[[ ! -e "$MON" && ! -e "$TIMER" && ! -e "$SERVICE" ]] \
  && ok "腳本與 unit 已移除" || bad "解除安裝未清乾淨"
[[ -f "$CONFIG" ]] && ok "設定檔預設保留" || bad "設定檔不該被刪除"
bash "$INSTALL" --uninstall --purge >/dev/null 2>&1
[[ ! -d /etc/sysmon-webhook ]] && ok "--purge 一併移除設定檔" || bad "--purge 未移除設定檔"

# ---------------------------------------------------------------------------

printf '\n===========================================\n'
printf '通過 %d 項，失敗 %d 項\n' "$PASS" "$FAIL"
printf '===========================================\n'
[[ $FAIL -eq 0 ]]
