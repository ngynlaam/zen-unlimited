# Hướng dẫn vận hành zen-unlimited

Tài liệu này đứng một mình: người đọc chỉ cần file này là hiểu mọi
giá trị, định dạng, bảng và thủ tục. Tên file và đường dẫn trong tài liệu
chỉ là nhãn vị trí (cho biết cái đó nằm ở đâu), không phải yêu cầu mở
file khác. Mọi số liệu dưới đây đã được sao chép vào trong tài liệu.
Không thay đổi hành vi — chỉ ghi lại cái đã đo.

Quy ước hai profile trong toàn tài liệu:

- **tuned** (mặc định, `ZEN_AGGRESSIVE` unset/≠1): giữ giá trị đã tinh chỉnh.
- **aggressive** (`ZEN_AGGRESSIVE=1`): xoay ngay từ 429 đầu tiên, guard ngắn.
  Dòng `daemon start` trong `auto.log` ghi `profile=tuned|aggressive`.

---

## 1. Kiến trúc: 5 module + Seam giữa mỗi cặp

| Module | File | Việc làm | Việc KHÔNG làm |
|---|---|---|---|
| Plugin (Signal Adapter) | `plugins/zen-warp.js` | Hook OpenCode append 1 dòng signal vào log | Không policy, không rotate, không cooldown |
| Plugin retry (fetch router + session retry) | `plugins/zen-quota-retry.js` (cài vào `~/.config/opencode/plugins/`) | Route `opencode.ai/zen/*` qua WARP, gửi signal, lên lịch retry trong session | Không tự cắt tunnel |
| Decision (policy daemon) | `bin/zen auto` (= `lib/auto.sh`) | Đọc signal log + DB fallback, quyết định rotate / hold / park | Không tự probe egress (gọi Actuator) |
| Actuator (rotate) | `bin/zen rotate` (= `lib/rotate.sh`) | Chu kỳ `warp-cli` disconnect/connect + probe egress | Không quyết định chính sách |
| Observer (report) | `bin/zen report` (= `lib/report.sh`) | Chỉ đọc DB + edge timeline + ledger | Không ghi gì ngoài stdout |
| Observer (catch) | `bin/zen catch` (= `lib/catch.sh`) | Gom transport reset thoáng qua từ 3 log vào `$STATE_DIR/catch/` | Không rotate |
| Routing (launcher) | `bin/zen launch` (= `lib/launch.sh`) | Khởi động OpenCode với proxy env đã set | Không filter per-request |

`bin/zen` chỉ dispatch (usage + source + dispatch, không policy).
Thin wrapper `bin/warp-auto`, `bin/warp-rotate`, `bin/warp-report`,
`bin/opencode2-warp` gọi subcommand tương ứng. Systemd service chạy
`bin/warp-auto`. Trạng thái dùng chung và helper nằm ở `lib/state.sh`.

Seam giữa từng cặp (hợp đồng duy nhất hai bên cần giữ):

1. **Plugin → Decision: file signal log**
   `$STATE_DIR/signals/zen-quota.log` (override `SIGNAL_DIR` /
   `ZEN_SIGNAL_FILE` cho test). Append-only, daemon tiến byte-cursor
   từng file, không bao giờ ghi lại. Định dạng dòng đầy đủ:
   `<ISO8601> <model-id> <trigger-text> [retry-after N]`.
   Ví dụ dòng thật: `2026-10-07T19:00:01.123Z
   muse-spark-1.3-contributor-free rate limit exceeded status=429
   source=zen-session-retry-hook retry-after=5`.
   Ví dụ trong test: `2026-10-07T19:00:01 m1 429 rate limit exceeded
   retry-after 5`. Quy tắc từng field: `$1` timestamp ISO8601 đọc được
   bởi `date -d` (cửa sổ hook-dedupe đọc từ đây); `$2` một token model,
   phải thỏa free-tier predicate (xem `lib/auto.sh` `is_free_model`):
   kết thúc `-free` (không phải jev), hoặc là free id suffixless khai báo
   (`big-pickle`, `grok-code`); `ZEN_FREE_MODELS` thêm id phụ thì dòng mới
   được tính;
   phần còn lại (trigger) phải khớp
   `rate limit exceeded|retry-after|status[=: ]+429` (không phân biệt
   hoa thường); hint `retry-after N` (giây) ở bất kỳ đâu trong dòng được
   tôn trọng nhưng bị cap, không có hint thì backoff cố định ngắn.
   Daemon là bên quyết định model:
   dòng có `$2` không thỏa free-tier predicate thì bị bỏ
   (kể cả khi trigger khớp). `seed_cursors` lúc khởi động bỏ qua lịch sử
   cũ — không replay dòng cũ.
2. **Decision → Actuator: một lời gọi rotate nội bộ.**
   `do_rotate` gọi `zen_rotate_main` khi `WARP_ROTATE` là marker nội bộ
   `__zen_internal_rotate` (mặc định); `WARP_ROTATE` trỏ path khác thì
   exec custom rotator. Không tiến trình mới trong đường mặc định.
3. **Decision ↔ Observer: file state dưới `$STATE_DIR` + ledger.**
   `rotations.tsv` là ledger bền: dòng `R` 9 cột
   (`epoch iso reason before after changed rc path`), dòng `V` 4–5 cột
   (dạng cũ 4 field = cumulative-since, không bao giờ viết lại; dạng mới
   thêm field window). `outcome_queue` là hàng đợi rotate chờ verdict.
   `edge_timeline.tsv` ghi 1 dòng mỗi lần edge ĐỔI (không phải mỗi poll),
   cột `epoch iso ipv6`.
4. **Decision → người dùng: `auto.log` + desktop notification.**
   `notify_rot` cho 3 mốc vòng đời (start/done/failed). `done` không bao
   giờ bị gap-limit (bằng chứng duy nhất rotate xong + địa chỉ mới);
   `start` bị throttle `ROTATE_NOTIFY_GAP=60s` theo từng key. Ghi stamp
   CHỈ SAU khi gửi thành công — gửi hỏng mà ghi stamp trước thì lần sau
   trông như đã báo. Lưu ý: máy bật DND thì `notify sent` trong log chỉ
   chứng minh lệnh gửi chạy, không chứng minh popup hiện.
5. **Routing → mọi tiến trình con: proxy env.**
   `HTTP_PROXY/HTTPS_PROXY/http_proxy/https_proxy` + `NO_PROXY/no_proxy`.
   Xem §3 vì sao env-process thắng per-request.

---

## 2. Toàn bộ thông số: giá trị hai profile + vì sao + bằng chứng

Mặc định tuned ghi trước, aggressive ghi sau (dạng `tuned → aggressive`).
`MAX_STUCK=1`, `STUCK_PARK=10s`, `DOWN_HOLD=2s` giữ nguyên cả hai profile.

### 2.1. Park (quota park / stuck park)

| Knob | tuned | aggressive | Vì sao | Bằng chứng |
|---|---|---|---|---|
| `QUOTA_PARK` (proxy) | 600s | 120s | Proxy xoay thêm vô ích (pool bẩn) nên park dài; aggressive rút ngắn vì storm cap đã chặn tổng số cut | Phép thử A/B tối 2026-10-07 (đo nhiều lần trong tối, không còn là ước lượng): proxy 8 lần xoay liên tiếp vẫn 429, tunnel ≤2 lần là hết. Giải thích: pool egress proxy bẩn (nhiều người dùng chung) và limiter key theo route-identity, không theo suffix IP/IPv4/key thuần — đổi suffix trong proxy không thoát, chỉ đổi cả route (tunnel) mới xong. Proxy nghỉ hưu cho Zen, tunnel là steady-state |
| `TUNNEL_QUOTA_PARK` | 90s | 30s | Tunnel ≤2 lần là hết nên chỉ nghỉ ngắn | Cùng phép thử A/B trên: tunnel ≤2 lần hết 429 |
| `STUCK_PARK` (same-edge) | 10s | 10s (giữ) | Từng là 120s: park daemon 2 phút trong khi 429 tươi vẫn tới → user chờ trên tunnel không ai reset; DND nuốt thông báo nên trông như treo | 2026-10-04: 70 fast-failure (median 12s giữa các 429), 39 cái KHÔNG có rotate nào xen giữa — daemon đang park, không phải xoay dở. 10s vẫn cắt vòng lặp cắt-lặp mà không stall 2 phút |
| Fail-backoff `ROTATE_BACKOFF` (alias `RETRY_BACKOFF`) | 300s | 300s | Chỉ sau rotate FAILED (WARP không lên lại) — tránh reconnect vòng chặt cắt proxy mỗi vài giây mà địa chỉ không đổi | Ghi trong `rotate_blocked`: pool IPv4 kẹt sẽ reconnect vòng lặp nếu không có |

### 2.2. Dedupe (1 rotate mỗi window mỗi key)

| Knob | tuned | aggressive | Vì sao | Bằng chứng |
|---|---|---|---|---|
| `DEDUPE_WINDOW` (proxy) | 90s | 10s | Key = (model, route-label, /48, minute). 429 trong window chỉ backoff, không cắt. 10s aggressive sau fast-retest 2026-10-11 | 11 dedupe hold ngày 10–11 hoãn cut lặp tới 30s mỗi lần (vd hold 18:33:15 → cut 18:34:08, 53s). Storm cap 3/600 đã chặn tổng cut nên MCP chịu cùng 3 cut nhưng retest sớm hơn tới 20s |
| `TUNNEL_DEDUPE_WINDOW` | 25s | 10s | Tunnel xoay là thuốc chữa nên window ngắn | Cùng phép thử A/B trên: tunnel ≤2 lần hết 429 |
| `MAX_WINDOW_FAILS` | 3 | 3 | 3 window liên tiếp vẫn 429 → park `QUOTA_PARK` + notify, thay vì nện tunnel | Hằng số chính sách, được khóa bởi test quy tắc trong `tests/test-rules.sh` (vị trí file; nội dung quy tắc đã ghi ở cột Vì sao) |
| Cơ chế key | route-label + /48, KHÔNG BAO GIỜ /128 đầy đủ, KHÔNG IPv4 | như tuned | /128 đầy xoay ~5 phút; pool IPv4 ~6 địa chỉ kẹt cứng `104.28.219.201` | Đo 2026-10-03: curl -4/-6 qua proxy đều trả cùng 1 IPv6; IPv6 đổi mọi lần đo, IPv4 kẹt |

### 2.3. Burst guard (lone-429 vs burst)

| Knob | tuned | aggressive | Vì sao | Bằng chứng |
|---|---|---|---|---|
| `BURST_COUNT` / `BURST_WINDOW` | 3 / 120s | **1** / 120s | Tuned: 429 đầu trong window chỉ backoff + latch (`single-429 backoff`), chờ signal thứ 2 mới xoay — 429 lẻ thường tự hết ở retry của client, xoay tốn ~7s blip. Aggressive: `eff_single_guard`=0, xoay ngay | Đo: 12:46:58, 13:29:33, 13:34:59 có 429 trong DB mà 0 dòng trong `opencode.log` — daemon chỉ quét log sẽ bỏ lọt (nay có `detect_429_db`) |
| `HOOK_DEDUPE_WINDOW` | 45s | 45s | DB fallback thấy quota row trong 45s sau hook signal thì coi là cùng 1 429, không cộng dồn | Hook ghi trước, DB row tới sau — cộng dồn sẽ xoay 2 lần cho 1 429 |
| `COOLDOWN` | 0 | 0 | Yêu cầu user: thấy 429 là xoay ngay, không hold. Trần tự nhiên là thời gian 1 lần xoay (~7s), `MAX_STUCK` chặn edge không đổi | Đo 93s chờ vô ích thời COOLDOWN=20 |

### 2.4. Backoff cap / fallback

| Knob | Giá trị | Vì sao | Bằng chứng |
|---|---|---|---|
| `RETRY_AFTER_CAP` | 10s | Hint `retry-after` của server được tôn trọng nhưng cap — không sleep dài chặn thuốc chữa | Policy khóa trong `retry_after_secs` |
| No-hint fallback `wait_hint` | 1s (từng 3s) | 0 hint trong 326 dòng signal + 0 trong plugin log → fallback `|| ra=1` chạy gần như mọi backoff; 17 lần sleep 3s không hint ngày 10–11, mỗi lần bịt event loop tới 3s | Fast-retest 2026-10-11; quota-park duration ở nơi khác giữ nguyên |
| Quota-text backoff (proxy) | `retry_after` capped, else 3s | Proxy: quota-text = hết budget → backoff, KHÔNG BAO GIỜ rotate | `QUOTA_TEXT` mirror upstream; tunnel là ngoại lệ (dưới) |
| `ROTATE_NOTIFY_GAP` | 60s/key | Start/done cách nhau vài giây; 1 timestamp chung sẽ nuốt `done` | Đo 2 rotate cách 24s, lần 2 xoay xong nhưng im lặng vì gap chung |
| `FREE403_NOTIFY_GAP` | 1800s | 403 tự hết, chỉ log + notify tối đa 1 lần/30 phút | A transient 403 can occur between successful requests without a route change. |

### 2.5. Hold / drain (không cắt giữa stream)

| Knob | Giá trị | Vì sao | Bằng chứng |
|---|---|---|---|
| `ZEN_DRAIN_S` | 1s (từng 30s → 10s → 3s → 1s) | Rotate không bao giờ cắt giữa stream: stream mở thì đợi tối đa drain rồi xoay sau drain/timeout. Nhưng wait KHÔNG BAO GIỜ tránh được cut giữa stream (xoay vẫn chạy sau timeout) — chỉ hoãn thuốc chữa | 13 deferred rotate 2026-10-07..11, 13/13 drain timeout, 0 clean drain — qua cả 3 era 30s/10s/3s (riêng 3s đã 3/3 timeout ngày 11). Hình defer-then-timeout giữ nguyên, chỉ rút wait chết |
| Stream-open signal | file `$STATE_DIR/stream_open` + `db_stream_open` (row assistant mới nhất: recent <300s, không `finish`, không `error.type`) | Row chỉ ghi khi hoàn tất luôn mang finish/error nên không false-positive; bound 300s chống orphan treo rotate mãi | Ghi trong `db_stream_open` |
| `FALLBACK_POLL` | 30s | Lưới an toàn nếu `inotifywait` chết; park expiry cũng rút ngắn wakeup | `wait_for_event` |

### 2.6. Storm cap

| Knob | tuned | aggressive | Vì sao | Bằng chứng |
|---|---|---|---|---|
| `ZEN_STORM_MAX` / `ZEN_STORM_WINDOW` | 0/600 (OFF — tuned byte-identical) | 3/600 | 6 rotate trong 2 phút (aggressive BURST=1 không single guard, 2026-10-11) cắt proxy ~7s mỗi lần; mọi MCP remote cưỡi proxy đó nên chết hàng loạt. Lone-429 xoay thưa là chủ ý; storm là bệnh | Quá cap: latch + log `storm-park`, không cắt, tới khi window trượt. Check cuối cùng trước cut nên hold không ăn storm budget |
| `STORM_FILE` | per-model (`bind_model`) | như tuned | Model nóng park một mình, model lặng vẫn xoay | `bind_model` scope mọi key backoff |

### 2.7. Choreography pacing (chỉ aggressive path; tuned không đọc)

| Bước | Giá trị | Vì sao | Bằng chứng |
|---|---|---|---|
| Hold-new-requests pause | drain có bound `ZEN_DRAIN_S` 1s (đã trong `do_rotate`, không sleep mới) | Không cut mới giữa stream | §2.5 |
| Warp down | `DOWN_HOLD` 2s (có sẵn, trong `reconnect`) | Floor do user chọn: tạo cửa sổ downtime để client retry thay vì nhận 429. Đính chính đã đo 2026-10-04 17:02: OpenCode đã tự retry sẵn (`⚠ Retry due · attempt 2`) — kéo dài lỗi chỉ khiến retry ăn `ECONNREFUSED`, nên down PHẢI ngắn, không kéo dài | Cơ chế gốc làm tay: tắt WARP → chờ ~2s → bật lại để request chết ở tầng TCP; điều kiện xong là proxy thật sự phục vụ HTTP 200 (`wait_down` + `wait_ready`), không chỉ `warp-cli status` báo Connected |
| Warp up | probe có sẵn (`wait_connected` + `wait_ready`, giữ nguyên) | Route có thể trả lời trước khi WARP chở traffic | `reconnect` |
| Post-up wait `ZEN_CHOREO_POST_UP_S` | cap 2s, readiness-gated (từng sleep cứng 2s) | Poll probe mỗi 0.2s, qua là đi tiếp — không bao giờ chậm hơn sleep cũ. Log `ready-by-probe` vs `ready-by-cap` | Ledger đã đo: up-window 204×4s + 254×5s (lượng tử poll 2s); hành vi được khóa: probe qua sớm thì kết thúc wait 3s trong ≤2s, probe không qua thì đợi đủ cap, không hơn |
| Settle window `ZEN_CHOREO_SETTLE_S` | cap 3s, success-gated (từng sleep cứng 3s) | Dừng sớm khi 429 đầu (repeat ngay) hoặc khi sạch + có dòng Zen OK mới trong DB; không quan sát được success (mất DB/bảng) thì fallback first-429-or-cap và nói rõ. Log `stopped-by-success` vs `stopped-by-cap` vs `repeat-on-429` | Hành vi được khóa: OK row mới dừng watch 4s trong ≤3s |
| Escape `ZEN_CHOREO_MAX` | 3 | Sau 3 cycle fruitless liên tiếp (mỗi cycle xong vẫn 429 trong window) thì fallback quota-park path (`quota_until = now + per-mode park`, giữ latch), thay vì cắt nữa. Storm cap 3/600 là bound ngoài, check mỗi cycle | Hành vi được khóa: đúng 3 cut rồi park + giữ latch. Công khai trong log + README, không bao giờ im lặng |

### 2.8. Plugin retry waits (bảng knob đầy đủ của plugin retry — giá trị đã sao chép vào đây, không cần mở file plugin)

| Knob (`zen-quota-retry.js`) | Giá trị | Nghĩa |
|---|---|---|
| `RETRY_INTERVAL_MS` (fixed-10s) | 10s | Retry mặc định khi không có rotation-ready và không có server hint |
| `POST_ROTATION_RETRY_MS` (post-rotation) | 3s | Retry nhanh sau khi rotate xong |
| `FRESH_DONE_MS` (fresh-done) | 20s | `rotate done` trong 20s gần nhất → bỏ qua chờ rotation, retry nhanh (`timing=fresh-done`, quét 400 dòng cuối `auto.log`) |
| `RETRY_AFTER_MAX_MS` | 10s | `retry-after` của server lấy precedence nhưng cap 10s |
| `ROTATE_WAIT_MS` | 100s | Chờ rotate yên (park expiry + WARP connect tới 60s + serve 20s + settle 2s) |
| `SETTLE_MS` / `POLL_MS` | 2s / 250ms | Settle sau done trước khi coi là yên |
| `PROXY_WAIT_MS` | 15s | Fail-closed bound: Zen traffic không bao giờ rò ra system-route; timeout thì fetch layer ném lỗi retryable |
| `MAX_SESSION_RETRIES` | 10 | Quá thì `quota retry skipped reason=limit` |

### 2.9. Guard khác (đọc log sẽ gặp)

- `MAX_STUCK=1`: rotate về cùng IPv6 thì park `STUCK_PARK`, không cắt nữa.
  Phán bằng IPv6 (gia đình duy nhất chở traffic), KHÔNG bằng IPv4.
- `OUTCOME_WAIT=120s`, `OUTCOME_WINDOW_S=600s`: verdict `V` đếm 429 trong
  `[rotate, rotate+600s]`, đáo hạn khi window xong hoặc 120s qua (lấy max).
  Hàng `R` cũ thiếu `path` vẫn đọc được (reader index cột cố định, bỏ trailing).
- `MODE_TTL=30s`: cache `mode_cache` để 1 round nhiều decision log probe
  tối đa 1 lần TCP connect (`proxy_alive` mặc định) hoặc HTTP probe
  (`proxy_alive http` cho rotate path).
- `EDGE_POLL=60s`, `EDGE_PROBE_TIMEOUT=5s` (từng 8s): probe egress qua proxy
  trước, fallback system-tunnel (`--noproxy '*'` + check `warp=on|plus|gateway=on`).
  Knob từng khai báo nhưng không dùng → probe mỗi vòng inotify tốn ~774ms/lần;
  nay có `edge_probed` floor 60s.
- Đếm 429 chuẩn: `error.type='provider.quota'` (+ `'provider.rate-limit'`
  cho DB detect), KHÔNG `LIKE '%Rate limit exceeded%'`. LIKE thô đếm 657 dòng
  mà chỉ 393 là rate limit thật (264 dòng là log nhúng trong user/synthetic/system);
  24h mẫu: 96 vs 79. Tệ hơn: cursor `max(time_created)` tiến theo dòng không phải
  rate limit → 429 thật sau đó rơi sau cursor, không bao giờ được đếm.
- 403 `free tier can only be used from within OpenCode` / `provider.auth` /
  `UnsupportedProxyProtocol`: **log-only, không xoay**, cả hai mode. Xoay IP vô ích.
- jev / `jev-*`: KHÔNG BAO GIỜ route (`model_path` → `off`), bị chặn ở
  free-tier predicate và SQL gate, ở match, và ở
  `handle_signal`/`handle_latch` (double lock).
  `model_path`: `muse-spark*|gpt-*|grok-*` → `responses`, còn lại → `chat`.

---

## 3. Đường đi traffic: bảng route, mode-aware launch, vì sao env-process thắng

### 3.1. Bảng route (hiện tại — splitter cũ đã xóa, một đường cho mọi model)

| Đường | Ai dùng |
|---|---|
| WARP qua `127.0.0.1:44444` | Zen + HTTPS khác của OpenCode, trừ `NO_PROXY` |
| Direct (không proxy) | `localhost,127.0.0.1,::1,192.168.99.44` + các host MCP (`mcp.cloudflare.com`, `mcp.context7.com`, `mcp.grep.app`) — override `ZEN_LAUNCH_NO_PROXY` |

Host MCP nằm ngoài `:44444`: bun đọc `NO_PROXY` lúc process khởi động và khớp
suffix domain, nên vòng xoay cắt `:44444` ~7s không đụng MCP (đo 2026-10-17:
conn MCP trên `:44444` 15 → 0; chi tiết WARP-AUTO.md Mục 15).

Lịch sử: từng có host-split (`opencode.ai/zen/v1/*` qua WARP, còn lại direct)
vì phép thử A/B đã chứng minh limiter theo route-identity (proxy 8 lần xoay
vẫn 429, tunnel ≤2 lần hết). Nay một cổng `127.0.0.1:44444` phục vụ mọi model;
`NO_PROXY` là ngoại lệ duy nhất.

### 3.2. Mode-aware launch (`bin/zen launch`)

```sh
ZEN_LAUNCH_PROXY=auto  # mặc định: proxy mode -> proxy local, tunnel mode -> direct
ZEN_LAUNCH_PROXY=off   # chạy direct, bỏ proxy
```

Logic `auto`: `mode_now` = `proxy` (listener `:44444` reachable) thì set
`HTTP_PROXY/HTTPS_PROXY=http://127.0.0.1:44444` + `NO_PROXY`
(mặc định `localhost,127.0.0.1,::1,192.168.99.44` + host MCP: `mcp.cloudflare.com`,
`mcp.context7.com`, `mcp.grep.app`); `tunnel` (listener chết,
system tunnel đang phục vụ) thì **unset toàn bộ proxy env** — vì tunnel
ĐÃ là egress sạch, còn `:44444` stale không listener sẽ refuse mọi connection.
Đây là lý do bắt buộc restart OpenCode sau khi đổi mode (§5.1).

### 3.3. Vì sao env-process thắng per-request

OpenCode background service dựng `FetchHttpClient` effect **trước khi plugin
load**, nên plugin không reroute được nó. Seam duy nhất hiệu quả là proxy env
của tiến trình (logic này nằm ở file vị trí `lib/launch.sh`). Plugin retry ở tầng fetch chỉ
quyết định retry/signal, không thay được route của client đã dựng.

Bổ sung đo 2026-10-17: `proxy: false` per-request bị bun **bỏ qua** (false/null/rỗng
đều rơi về env proxy; `delete process.env` trong process cũng vô hiệu vì fetch dùng env
**lúc process start**). Cách ép direct đã kiểm chứng: `NO_PROXY` **lúc start**, khớp
suffix — xem WARP-AUTO.md Mục 15.

---

## 4. Vòng retry 429 end-to-end theo thời gian

Ví dụ tuned, tunnel mode, burst-429 (số giây tương đối, T0 = 429 đầu):

```
T+0.0s  provider trả 429 (error.type=provider.quota)
T+0.0s  plugin retry hook: append signal line vào zen-quota.log
        + lên lịch session retry (fixed-10s, hoặc retry-after capped 10s)
T+~0s   daemon thức (inotify modify trên SIGNAL_DIR, fallback poll 30s)
        check_once: signal_model_counts peek (không tiến cursor) →
        detect_429_new tiến cursor → burst>=2 (hoặc aggressive: ngay)
T+~0s   do_rotate: stream_drain_wait ≤1s → log "route path" → "rotate start"
        → notify start → warp-cli disconnect
T+~0s   wait_down xác nhận route down → DOWN_HOLD 2s → warp-cli connect
        → wait_connected (poll 1s, ≤60) → wait_ready (READY_TRIES=20)
        → "up-window: Ns" (~4–5s theo ledger: 204×4s + 254×5s)
T+~7s   probe after-edge → ledger R row + outcome_queue entry
        → dedupe_stamp/key + storm_record → "rotate done" + notify done
        (aggressive: post-up readiness-gated ≤2s → "choreo: ready"
        → settle success-gated ≤3s; 429 trong window → repeat NGAY,
        không dedupe/backoff; sạch → dừng)
T+10s   session retry của client bắn (post-rotation 3s nếu fresh-done ≤20s)
T+120–600s  resolve_outcomes: V row = số 429 trong [rotate, rotate+600s]
        → 0 = rotate chữa được; nhiều = 7s outage mua về không gì
```

Tổng một cycle aggressive ≈ 7s outage WARP-path + overhead rotate
(drain 1s + down 2s + up ~4–5s + post-up ≤2s + settle ≤3s, smart-wait
cắt ngắn khi probe/success qua sớm).

---

## 5. Tip/trick vận hành

### 5.1. Restart opencode2 sau khi đổi mode

`bin/zen launch` đọc mode **lúc khởi động** rồi exec OpenCode. Đổi mode sau đó
(proxy listener sống/chết) không tự lan vào tiến trình đang chạy — env đã
chốt. Đổi mode → restart OpenCode background service → check `api get /api/info`.
Cùng lý do: restart daemon (`systemctl --user restart warp-auto.service`) thì
tự do (không đụng tunnel, chỉ nạp code mới) nhưng daemon mới sẽ xoay ngay nếu
đang có 429 — kiểm tra `tail -2 auto.log` sau restart.

### 5.2. Park nghĩa là gì khi đọc log

- `holding: quota park until <epoch>`: quota backoff/park còn hiệu lực —
  429 chỉ latch (`need_rotate`), không cắt. Đợi tới epoch.
- `saw N rate-limit line(s) during same-edge park (until <epoch>) — latched,
  park kept`: signal tươi trong stuck-park — park KHÔNG bị xóa (xóa là lỗi cũ
  biến park 10s thành vô nghĩa và gây rotate storm với COOLDOWN=0).
- `latched rate limit inside dedupe window … (fail k/3)`: latch bắn trong
  window sau rotate — backoff, tính 1 failed window; đủ 3 → `quota-window …
  parking Ns instead of hammering`.
- `storm-park: N rotates in 600s window >= max 3 — holding Ns … no rotate`:
  quá storm cap — không cắt tới khi window trượt.
- `rotate stopped: IPv6 edge stuck on <ip> — parked 10s`: cùng edge lần 2
  (MAX_STUCK=1) — dừng có chủ ý, latch đã xóa (không ghi lại).
- `latched single-429 expired with no 2nd signal in 120s — clearing, no rotate`:
  latch 429 lẻ hết hạn yên lặng — đúng thiết kế, không phải bỏ sót.
- `choreo: escape hatch after 3 consecutive fruitless cycles … falling back
  to quota-park`: aggressive thua 3 cycle liên tiếp — park, giữ latch cho sau park.

### 5.3. Đọc report §11–16 (`bin/zen report`, chỉ đọc DB + state file)

| § | Nguồn | Đọc gì |
|---|---|---|
| §11 rotate latency | cặp start→done, down/up window, stream drain | up-window 4–5s là bình thường; down-window 2s = DOWN_HOLD |
| §12 holds | dedupe/single-guard/quota-park/same-edge/cooldown/fail-backoff per model + signal per model | Model nào ăn hold nhiều nhất; single-guard hold nhiều = 429 lẻ nhiều, hệ khỏe |
| §13 verdict latency + pending queue | V row grading delay bucket + `outcome_queue` | V=0 nhiều = rotate chữa được; pending tồn = window chưa đáo hạn |
| §14 proxy-listener health | `mode=proxy/tunnel` per day + route mention + mode_cache hiện tại | Proxy ngày càng ít = đúng steady-state tunnel |
| §15 route decision per model | responses/chat/off refusal | jev off là đúng, không phải lỗi |
| §16 transport-error timeline | DB per day + auto.log mention | Đối chiếu ±30s quanh rotate: 26/98 (27%, kỳ vọng ngẫu nhiên 7.0, p<0.001) — có quan hệ thật nhưng KHÔNG phải 100% (đính chính này sửa kết luận cũ cho rằng mọi transport error đều do rotate gây ra) |

Các § khác: §1 quota rate theo ngày; §2–3 attribution theo edge
(edge_timeline join); §4 hiệu quả từng rotate (R+V); §5–10 request toàn bộ,
latency/token/model/retry-chain/dead session (§10: session ≥3 fail nối tiếp —
payload dính session, `/fork` hoặc `/compact` mới cứu, không phải lỗi tunnel).

### 5.4. Bẫy thường gặp

1. **Stale env (mode đổi, tiến trình không):** OpenCode chạy từ trước giữ proxy
   env cũ → tunnel mode mà vẫn đâm vào `:44444` chết = `ECONNREFUSED` hàng loạt.
   Chữa: restart OpenCode sau mọi lần đổi mode (§5.1).
2. **Resume-xhigh / replay lịch sử:** restart daemon không seed cursor sẽ quét
   lại toàn bộ log — từng gây 1 rotate oan 09:06:16 (`burst (50 signals in 120s)`
   toàn 429 cũ) sau khi dọn 152 cursor `off.*` rác (cursor cho log đã xóa,
   `scan_new` fallback `off=0`). Nay `seed_cursors` + DB cursor `max(time_created)`
   lúc cold start. Triệu chứng: burst count bất thường ngay sau restart.
3. **Verdict mù (log trim):** `auto.log` trim 2MB chỉ giữ ~1.5 ngày rotate
   trong khi DB giữ 30 ngày 429 → không join được nhân quả "xoay có chữa không".
   Chữa đã có: `rotations.tsv` + `resolve_outcomes` (R+V). Đừng kết luận hiệu quả
   từ `auto.log` một mình.
4. **Lone-429 (tuned):** 1 429 lẻ → `single-429 backoff` + latch, KHÔNG xoay.
   Đây là chủ ý (tiết kiệm 7s blip), không phải daemon chết. Chỉ aggressive mới
   xoay ngay. Đừng "sửa" guard này nếu chưa đọc §2.3.
5. **IPv4 mù:** pool IPv4 ~6 địa chỉ kẹt `104.28.219.201` — phán rotate bằng IPv4
   sẽ đánh dấu rotate hữu ích thành vô ích và chặn chúng. Chỉ phán bằng IPv6.
6. **403 tưởng 429:** `free tier can only be used from within OpenCode` tự hết,
   xoay IP vô ích — daemon log-only + notify ≤1 lần/30 phút. Đừng xoay tay.
7. **DND nuốt thông báo:** máy bật DND theo ý user — đừng tự tắt. Không popup
   ≠ daemon chết; check `systemctl --user status warp-auto` →
   `grep notify auto.log | tail` → `notifications.json` `"dnd": true`.
8. **Quota-text ở tunnel mode:** proxy thì quota-text = hết budget (không xoay);
   tunnel thì quota-text CŨNG xoay (đo ≤2 lần hết) — rule "quota never rotates"
   của upstream-v2 SAI ở tunnel mode. Đừng port rule đó mù quáng.
9. **/128 xoay ~5 phút:** dedupe key dùng /48 — key /128 đầy sẽ miss liên tục.

---

## 6. Công thức áp dụng cho hệ quota-IP tương tự (checklist port)

1. **Tách 5 module + seam file trước khi viết policy.** Plugin chỉ append dòng
   `<ts> <id> <trigger>`; daemon giữ cursor; rotate tách riêng; report chỉ đọc.
   Không policy trong plugin, không quyết định trong actuator.
2. **Đo gia đình IP nào chở traffic trước khi chọn key.** `curl -4` vs `-6` qua
   egress có trả cùng địa chỉ không? Pool nào kẹt (như IPv4 kẹt 6 địa chỉ)?
   Key dedupe/stuck PHẢI là prefix ổn định (/48), không bao giờ full address
   hay pool kẹt.
3. **Chạy verdict A/B theo route trước khi tune số.** Câu hỏi: xoay IP có chữa
   quota không, theo từng route? Nếu một route xoay 8 lần vẫn 429 (proxy ở đây)
   → park dài + dedupe dài cho route đó; route chữa được (tunnel ≤2 lần) →
   park/dedupe ngắn. Đừng tune guard khi chưa biết route nào chữa được.
4. **Ledger R+V từ ngày đầu.** Log narrative sẽ bị trim; không có ledger bền thì
   câu "xoay có chữa không" mãi không trả lời được. Verdict window (600s ở đây)
   phải dài hơn chu kỳ 429 tự nhiên của hệ mới.
5. **Lone-signal guard mặc định BẬT.** 1 signal lẻ → backoff + latch, chờ bằng
   chứng bền (signal thứ 2 / latch còn burst sau window) mới cắt. Giá 1 cut
   (outage giây + retry hàng loạt) luôn đắt hơn giá 1 backoff.
6. **Same-edge park + storm cap là hai bound khác nhau, cần cả hai.**
   Same-edge (MAX_STUCK=1, park giây) chặn "cắt lặp vào cùng edge";
   storm cap (N rotate / window trượt) chặn "cắt quá nhiều nói chung".
   Quá cap thì latch + nói rõ trong log, không cắt im lặng.
7. **Smart-wait thay sleep cứng ở mọi pacing mới.** Mỗi wait phải có
   readiness-gate (probe qua là đi) + cap (không bao giờ chậm hơn sleep cũ)
   + log phân biệt `by-probe` vs `by-cap`. Escape hatch công khai sau N cycle
   fruitless (3 ở đây), fallback park path, giữ latch.
8. **DB/lịch sử là fallback bắt buộc + cursor seed lúc cold start.**
   Log có thể thiếu sự kiện đã hiện trên màn hình (3/3 429 DB-có-log-không
   ở đây). Cursor DB tính bằng ms nếu column là ms. Cold start seed "now",
   không replay lịch sử.
9. **Đếm bằng typed field, không LIKE thô.** LIKE thô ở đây thừa 264/657 dòng
   và làm cursor tiến sai. Tìm field có type của hệ mới trước khi viết detector.
10. **Phân loại lỗi không xoay được (403 ở đây) thành log-only từ đầu.**
    Kèm fingerprint (UA/session/tools/stream) để lần sau phân biệt mode hỏng mới
    với cái cũ, và notify throttle riêng.
11. **Launcher đọc mode lúc start + tài liệu hóa "restart sau đổi mode".**
    Env-process thắng vì client dựng sớm hơn plugin; mọi đổi route phải đi kèm
    restart tiến trình con.
12. **Test seam, không test tunnel.** Mọi test ở đây: fake STATE_DIR, fake
    rotator (`WARP_ROTATE=/bin/true` hoặc script ghi `rot.log`), fake mode_cache,
    fake signal log — `warp-cli` không bao giờ chạy. Timing assert bằng bound
    (range), không bằng số tuyệt đối. Giữ shape ledger (R 9 cột) bằng test khóa.

---

## 7. Phụ lục tự chứa (mọi giá trị gốc đã sao chép vào đây)

### 7.1. Khối trích nguyên văn knob plugin retry (vị trí file: `~/.config/opencode/plugins/zen-quota-retry.js`)

```js
const ROTATE_WAIT_MS = 100_000;
const SETTLE_MS = 2_000;
const POLL_MS = 250;
const PROXY_WAIT_MS = 15_000;
const MAX_SESSION_RETRIES = 10;
const RETRY_INTERVAL_MS = 10_000;
const POST_ROTATION_RETRY_MS = 3_000;
const FRESH_DONE_MS = 20_000;
const RETRY_AFTER_MAX_MS = 10_000;
```

Ngữ nghĩa từng knob đã ghi đầy đủ ở §2.8 — bảng đó là đủ, không cần mở file plugin.

### 7.2. Đường dẫn state và service (nhãn vị trí, giá trị mặc định đi kèm)

- State dir mặc định: `~/.local/share/warp-rotate/` (override `STATE_DIR` cho test).
- Signal log: `$STATE_DIR/signals/zen-quota.log` (override `SIGNAL_DIR` / `ZEN_SIGNAL_FILE`).
- Ledger bền: `$STATE_DIR/rotations.tsv` — dòng `R` 9 cột
  (`epoch iso reason before after changed rc path`), dòng `V` 4–5 cột
  (dạng cũ 4 field = cumulative-since; dạng mới thêm field window).
- Hàng đợi verdict: `$STATE_DIR/outcome_queue`; timeline edge:
  `$STATE_DIR/edge_timeline.tsv` (cột `epoch iso ipv6`, 1 dòng mỗi lần edge ĐỔI).
- Daemon log: `$STATE_DIR/auto.log` (trim 2MB, giữ ~1.5 ngày rotate; DB giữ 30 ngày).
- Systemd unit: `warp-auto.service` (user service) chạy `bin/warp-auto`.
- Plugin live trong repo: `plugins/zen-warp.js`; bản copy chạy thật ở
  `~/.config/opencode/plugins/` (hai bản giống nhau).
- OpenCode DB fallback: bảng `session_message`, cột `time_created` tính bằng
  mili giây; đếm 429 chuẩn bằng `error.type='provider.quota'`
  (+ `'provider.rate-limit'` cho DB detect), không dùng `LIKE`.

### 7.3. Tồn kho test (vị trí file trong `tests/`, nội dung kiểm đã tóm ở đây)

- `tests/test-rules.sh`: khóa quy tắc dedupe/window/park (`MAX_WINDOW_FAILS=3`,
  window fail → park thay vì nện tunnel).
- `tests/test-choreo.sh`: khóa choreography — probe qua sớm thì kết thúc wait
  sớm (≤2s), probe không qua thì đợi đủ cap, OK row mới dừng watch 4s trong ≤3s,
  đúng 3 cut fruitless rồi park + giữ latch.
- `tests/test-aggressive.sh`, `test-speedup.sh`, `test-review-fixes.sh`,
  `test-observability.sh`: khóa profile aggressive, bound thời gian, và các sửa
  đã review (timing assert bằng range).
- `tests/test-issue-*.sh`, `test-catch.sh`, `policy.bats`, `helper.sh`,
  `timing-probe.sh`: test hồi quy từng issue + harness phụ trợ.
- Quy ước chung mọi test: `STATE_DIR` giả, `WARP_ROTATE=/bin/true` hoặc script
  ghi `rot.log`, `mode_cache` giả, signal log giả — `warp-cli` không bao giờ chạy.

### 7.4. Lệnh vận hành chép sẵn (không cần tra file khác)

```sh
systemctl --user restart warp-auto.service   # nạp code daemon mới, không đụng tunnel
tail -2 ~/.local/share/warp-rotate/auto.log # kiểm tra sau restart: daemon mới xoay ngay nếu đang có 429
systemctl --user status warp-auto            # daemon còn sống không
grep notify ~/.local/share/warp-rotate/auto.log | tail  # sent / FAILED
cat ~/.local/state/omarchy/notifications.json  # kiểm tra "dnd": true → popup bị giấu, không phải daemon chết
ZEN_AGGRESSIVE=1 bin/zen auto                # chạy profile aggressive một lần
bin/zen report                               # báo cáo chỉ đọc (§5.3)
bin/zen launch                               # khởi động OpenCode với proxy env theo mode
```
