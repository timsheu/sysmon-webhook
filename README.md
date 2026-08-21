# sysmon-webhook

Linux 系統資源監控，透過 Discord webhook 定期回報。單一檔案安裝、以 systemd timer 排程、沒有任何外部相依套件。

```
curl -fsSL https://raw.githubusercontent.com/timsheu/sysmon-webhook/94caca3661ad5ce0526bd3cc9bd577aaba4e3e8c/install.sh \
  | sudo bash -s -- --webhook-file /root/webhook.txt --name db-01
```

---

## 這是什麼，以及不是什麼

**是**：資源監控。定期回報 CPU、記憶體、Swap、磁碟用量、inode 用量與系統負載，超過門檻時發紅色告警。

**不是**：服務健康監控。一個服務可以完全死掉，而上述指標全部正常——資料庫拒絕新連線、API 回 500、容器顯示 `Up` 但裡面的行程早已無法工作，這些都不會讓 CPU 或磁碟出現異常。那類事故需要的是 HTTP／TCP 探測或應用層的健康檢查端點，本工具不涵蓋。

把兩者當成互補而非替代，否則會誤以為缺口已經補上。

---

## 安裝

三種方式，安全性由高到低。

### 一、驗證 checksum 後執行（正式機器建議）

```bash
curl -fsSL -o install.sh \
  https://raw.githubusercontent.com/timsheu/sysmon-webhook/94caca3661ad5ce0526bd3cc9bd577aaba4e3e8c/install.sh
echo "56b0830267025377ea368868a529e6afebc61a0fe6a0127330aaca59c094a5b6  install.sh" | sha256sum -c -
sudo bash install.sh --webhook-file /root/webhook.txt --name db-01
```

上面指令裡的 sha256 已對應到所釘的 commit SHA；換釘其他 commit 時，checksum 請自行以
`sha256sum install.sh` 重新計算，不要沿用這個值。

### 二、webhook 從檔案讀（一行安裝，但不外洩 webhook）

```bash
printf '%s\n' 'https://discord.com/api/webhooks/xxx/yyy' > /root/webhook.txt
chmod 600 /root/webhook.txt

curl -fsSL https://raw.githubusercontent.com/timsheu/sysmon-webhook/94caca3661ad5ce0526bd3cc9bd577aaba4e3e8c/install.sh \
  | sudo bash -s -- --webhook-file /root/webhook.txt --name db-01
```

### 三、純參數（最短，僅建議用於測試機）

```bash
curl -fsSL https://raw.githubusercontent.com/timsheu/sysmon-webhook/94caca3661ad5ce0526bd3cc9bd577aaba4e3e8c/install.sh \
  | sudo bash -s -- --webhook "https://discord.com/api/webhooks/xxx/yyy" --name db-01
```

這個寫法會把 webhook URL 留在三個地方：使用者的 shell history、`/var/log/auth.log`（sudo 會記錄完整命令列）、以及安裝當下任何本機使用者都看得到的 `ps` 輸出。Discord webhook 等同一把不需認證就能發文的金鑰，取得的人可以無限量往你的頻道貼東西。安裝器在結束時會提醒這件事。

### 關於網址裡的 `<COMMIT_SHA>`

請釘住 commit SHA，不要用 `main`。`main` 是可變目標——repo 一旦被推入惡意 commit，所有機器下次重裝就會直接以 root 執行它。另外 `raw.githubusercontent.com` 有數分鐘的 CDN 快取，剛推上去的修改不會立即生效，排錯時容易被這點誤導。

---

## 參數

| 參數 | 預設 | 說明 |
|------|------|------|
| `--webhook <url>` | — | Discord webhook URL |
| `--webhook-file <path>` | — | 從檔案第一行讀取 webhook URL |
| `--webhook-stdin` | — | 從標準輸入讀取（僅適用「先下載再執行」，`curl \| bash` 的 stdin 是腳本本身） |
| `--name <name>` | hostname | 訊息標題顯示的系統名稱 |
| `--interval <分鐘>` | 60 | 回報間隔 |
| `--cpu-threshold <%>` | 90 | CPU 告警門檻 |
| `--mem-threshold <%>` | 90 | 記憶體告警門檻 |
| `--swap-threshold <%>` | 0 | Swap 告警門檻，`0` 表示只顯示不告警 |
| `--disk-threshold <%>` | 90 | 磁碟告警門檻 |
| `--inode-threshold <%>` | 90 | inode 告警門檻，`0` 表示只顯示不告警 |
| `--disk-path <paths>` | `/` | 監控的掛載點，逗號分隔 |
| `--recovery-margin <%>` | 5 | 遲滯範圍，見下方說明 |
| `--report-mode <mode>` | `always` | `always` 每次都回報，`alert_only` 僅在異常與恢復時回報 |
| `--heartbeat-url <url>` | — | 每次執行成功後 ping 一次的 URL |
| `--no-test` | — | 安裝後不發送測試訊息 |
| `--uninstall` | — | 移除 timer、service 與腳本，保留設定檔 |
| `--uninstall --purge` | — | 連設定檔與狀態一併移除 |
| `--print-monitor` | — | 印出將被安裝的監控腳本（安裝前審閱用） |
| `--print-failure` | — | 印出將被安裝的失敗通報腳本 |

環境變數 `WEBHOOK_URL`、`SYS_NAME`、`HEARTBEAT_URL` 亦可使用。

優先序：**CLI 參數 > 環境變數 > 既有設定檔 > 內建預設**。

### inode 值得單獨監控

磁碟空間還很充裕、inode 卻用盡，是相當常見的靜默事故——大量小檔案（容器 log、session 檔、郵件佇列）會先耗盡 inode，此時任何寫入都會失敗，而 `df -h` 看起來一切正常。

### 多掛載點

```bash
--disk-path "/,/var/lib/docker,/home"
```

各掛載點分別判斷門檻，任一超標即整體轉為告警。像 `/var/lib/docker` 這種容易單獨膨脹的位置，值得從根目錄拆出來獨立監控。

---

## 升級

重跑同一行安裝指令即可。**未帶到的參數會沿用既有設定，不會被重置回預設值**：

```bash
# 第一次
sudo bash install.sh --webhook-file /root/webhook.txt --name db-01 --interval 15

# 之後升級腳本版本，沒帶 --interval，間隔仍然是 15
curl -fsSL .../install.sh | sudo bash -s -- --webhook-file /root/webhook.txt
```

要清除 `--heartbeat-url`，帶入 `none` 或空字串。

---

## 監控自己掛掉的時候

這是最容易被忽略的失效模式：監控腳本靜默死亡，Discord 從此安靜，而「安靜」和「一切正常」在畫面上看起來一模一樣。本工具用三層處理：

**第一層，監控腳本本身容錯。** 每項量測各自處理失敗並回傳 `N/A`，單一指標取不到不會讓整份報告發不出去。掛載點被卸載、`hostname -I` 在該發行版不存在、舊 kernel 沒有 `MemAvailable`——這些都只會讓對應欄位顯示 N/A，其餘照常回報。

**第二層，`OnFailure=`。** 監控腳本若真的以非零狀態結束（例如 webhook 連續五次送不出去），systemd 會觸發 `sysmon-webhook-failure.service`，它會把最近 20 行 journal 內容發到同一個 webhook。

**第三層，`--heartbeat-url`。** 前兩層都需要這台機器還活著、還能對外連線。整台機器斷線、timer 被停用、systemd 沒能啟動這個 unit——這些情況下不會有任何訊息送出。唯一能發現的方法是讓外部服務盯著「該來的心跳沒來」：

```bash
--heartbeat-url "https://hc-ping.com/your-uuid"
```

healthchecks.io、Uptime Kuma 的 push monitor 都適用。**強烈建議設定**，沒設定的話安裝器會在結束時提醒一次。

---

## 遲滯（`--recovery-margin`）

指標剛好在門檻附近抖動時，每個週期都會 alert／ok 交替，很快就沒有人會認真看。加上遲滯後，進入告警的條件是「達到門檻」，但解除告警需要回落到「門檻 − margin」以下：

門檻 90%、margin 5 時，93% → 告警；回落到 87% 才會解除，88%～92% 之間維持告警狀態不重複翻轉。

---

## systemd 硬化與它的副作用

service 會依目標機器的 systemd 版本套用對應的硬化選項（v232 以上用 `ProtectSystem=strict`，較舊版本退回 `ProtectSystem=full`）。舊版 systemd 對不認識的設定鍵只會警告並忽略，但那些警告每次觸發都會刷 journal，所以安裝器會先偵測版本再決定寫入哪些。

**`PrivateTmp=yes` 會影響 `/tmp` 的量測。** 這個選項讓 service 看到的是私有的 tmpfs，而不是真實的 `/tmp`。若你需要監控真實 `/tmp` 的用量，請改監控它所在的檔案系統（通常是 `/`），或自行移除 service 檔中的該行後 `systemctl daemon-reload`。其餘掛載點（含 `/home`、`/var/lib/docker`）不受影響——`ProtectHome=read-only` 保留掛載點可見，`df` 讀到的仍是真實數據。

---

## 安全性

- **設定檔** `/etc/sysmon-webhook/config.env` 權限 `600`、root 擁有，先建檔收權限再寫入內容，webhook URL 不會有以寬鬆權限落地的空窗。
- **webhook URL 會被格式驗證。** 設定檔由 shell `source` 讀取，未經驗證的值等同一條 root 權限的命令注入路徑；值另以 `printf %q` 跳脫後寫入，構成第二道防線。
- **`--name` 限定安全字元集**，避免產生無效 JSON（Discord 會回 400，而重試五次都不會變好，等於靜默失去這次告警）。
- **暫存檔用 `mktemp`**，不使用可預測的 `/tmp/xxx.$$` 檔名，避免 symlink 攻擊。

---

## 疑難排解

```bash
systemctl status sysmon-webhook.timer      # timer 是否啟用
systemctl list-timers sysmon-webhook.timer # 下次觸發時間
journalctl -u sysmon-webhook.service -n 50 # 執行紀錄
sudo /usr/local/bin/sysmon-webhook.sh --dry-run   # 印出 payload，不送出
```

`--dry-run` 會組出完整的 JSON payload 印到 stdout 就結束，不送出、不寫狀態、不 ping heartbeat，是排查「數字對不對」「JSON 有沒有壞」最快的方法。

安裝前想先看要裝什麼：

```bash
bash install.sh --print-monitor   # 監控腳本
bash install.sh --print-failure   # 失敗通報腳本
```

---

## 已驗證環境

| 項目 | 範圍 |
|------|------|
| bash | 4.2（CentOS 7）、4.4（Debian stretch）、5.2（Debian bookworm） |
| systemd | 安裝器的版本分層邏輯已於 219／232／247 三種情境驗證 |
| 檔案結構 | 完整安裝、升級（保留既有設定）、解除安裝、purge 皆已驗證 |
| payload | OK／ALERT／掛載點消失／60 個掛載點觸發截斷等情境的 JSON 皆驗證有效 |

---

## 檔案位置

| 路徑 | 內容 |
|------|------|
| `/etc/sysmon-webhook/config.env` | 設定檔（600） |
| `/usr/local/bin/sysmon-webhook.sh` | 監控腳本 |
| `/usr/local/bin/sysmon-webhook-failure.sh` | 失敗通報腳本 |
| `/var/lib/sysmon-webhook/state` | 前次狀態（遲滯與恢復通知用） |
| `/etc/systemd/system/sysmon-webhook.{service,timer}` | systemd unit |
| `/etc/systemd/system/sysmon-webhook-failure.service` | `OnFailure=` 的目標 |

---

## 授權

MIT
