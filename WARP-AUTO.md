# warp-auto / warp-rotate — triết lý, cấu trúc, và những chỗ đã sai

Tài liệu này ghi lại **toàn bộ** quá trình dựng `warp-auto` (daemon) +
`warp-rotate` (actuator), từ bản đầu tiên đến hiện tại. Mục tiêu không chỉ là
mô tả code đang chạy, mà là ghi lại **những chỗ đã sai** — vì phần lớn công việc
thật trong dự án này là sửa lại những kết luận sai, không phải viết code mới.

Người đọc nên đọc **Mục 7 (Sai lầm)** trước. Phần còn lại là để tra cứu.

---

## 1. Vấn đề gốc

OpenCode chạy qua Cloudflare WARP local proxy (`:40000`). Provider `opencode`
(model `muse-spark-1.3-contributor-free`) thỉnh thoảng trả:

```
Error: Error from provider (Console): Rate limit exceeded. Please try again later.
```

Bài toán ban đầu: **xoay WARP tự động ngay khi gặp 429**, mà không làm gián
đoạn request đang chạy.

Bài toán thực tế sau nhiều vòng đo: **429 có phải do IP không?** Câu trả lời
chưa chốt được, và đây là phần chưa xong của dự án. Xem Mục 8.

---

## 2. Triết lý thiết kế

### 2.1. Event-driven, không phải polling

Bản đầu tiên xoay theo interval cố định. Sai, vì:

- Rotate có chi phí thật: ~6 giây `:40000` không phù hợn, và mọi request
  đang bay bị cắt.
- Interval cố định không biết khi nào thực sự cần.

Đổi sang `inotifywait -e modify` trên thư mục log. Độ trễ đo được: **2.000ms**
(biến mất luôn 30 giây chờ poll). `FALLBACK_POLL=30` giữ làm lưới an toàn phòng
khi inotify chết — nhưng chỉ là lưới, không phải cơ chế chính.

Một hệ quả ít ngời: **daemon không có "nhịp"**. Nó im lặng khi không có việc,
và điều đó dễ bị nhầm là treo. Nhiều lần trong quá trình này đã phải dừng lại
kiểm tra "daemon có sống không" trong khi nó sống hoàn toàn bình thường.

### 2.2. Tín hiệu không bằng hành động — phải có latch

`429` được nhìn thấy không có nghĩa nên xoay ngay. Ba mức leo thang:

| Tình huống | Hành động |
|---|---|
| 1 tín hiệu, rảnh tay | xoay ngay |
| 1 tín hiệu, đang bận | **ghim** (`need_rotate`), xoay khi traffic dừng |
| ≥3 tín hiệu / 120s | xoay ngay, kể cả đang bận (user bấm retry liên tục) |

Nhánh burst là **cố ý** cắt qua request đang chạy. Lý do: người dùng đang bị
429 ở *mọi* lần thử, chờ idle thì cũng sẽ chết. Sau này daemon bị giới hạn lại
bởi `IDLE_HOLD` và chờ-idle — xem Mục 7.4; cả hai đã bị xoá (Mục 7.16), giờ
mọi tín hiệu đều xoay ngay.

### 2.3. Thứ tự cổng chặn: cooldown và backoff phải phổ quát

`COOLDOWN` từng là cổng chung cho **mọi** nhánh, để chúng không tranh nhau và tạo ra
hiệu ứng "xoay 3 lần liên tiếp". Nay mặc định `COOLDOWN=0` nên cổng này tắt —
xoay ngay mỗi tín hiệu. Xoay liên tiếp vẫn được chặn bởi `MAX_STUCK`, và mỗi lần
xoay tự mất ~7s nên không thể lặp vô hạn.

Rotate thất bại → `last_failed` + `RETRY_BACKOFF=300`. Latch **được giữ**, không
bị xoá, nên khi hết backoff daemon tự thử lại thay vì im.

### 2.4. Định nghĩa thành công

Ban đầu: "xoay thành công = IP đổi". Đây là định nghĩa sai và nó đã dẫn tới
nhiều kết luận sai (Mục 7.2).

Hiện tại: **thành công = WARP kết nối lại được.** IP có đổi hay không là *thông
tin báo cáo*, không phải tiêu chí. Lý do: pool IPv4 chỉ ~6 địa chỉ, nên nó
kẹt gần như luôn; dùng nó làm tiêu chí khiến daemon báo "vô ích" cho những
lần xoay thực sự đổi edge.

### 2.5. "Có vẻ đúng" không phải bằng chứng

Nguyên tắc này bị vi phạm nhiều lần bởi chính người viết tài liệu này, và là
bài học quan trọng nhất của cả dự án:

- Đo một lần → không kết luận về hành vi lặp lại.
- Đo bằng tiêu chí không đúng đối tượng → kết luận sai hoàn toàn.
- Đo trong điều kiện không đại diện (ví dụ: 3 request liên tiếp không nghỉ) →
  kết luận sai.
- Chạy test hỏng rồi tin kết quả test → tệ hơn không test.

Chi tiết ở Mục 7.

### 2.6. Ưu tiên: quan sát > can thiệp

Bất kỳ lần nào daemon im lặng, cách đúng là **đọc log và đo**, không phải sửa
code. Trong chuỗi này đã có ít nhất 2 lần sửa code khi vấn đề thật ra là ở chỗ
khác.

---

## 3. Kiến trúc

```
opencode.log + oh-my-opencode-slim.*.log + Zen hook signal
        │
        │ inotifywait (modify/create/moved_to) trên THƯ MỤC
        ▼
   ┌─────────────┐
   │  warp-auto  │  quyết định: có xoay không, khi nào xoay
   │  (daemon)   │  state trong ~/.local/share/warp-rotate/
   └──────┬──────┘
          │ exec
          ▼
   ┌─────────────┐
   │ warp-rotate │  warp-cli disconnect → connect, chờ Connected
   │  (actuator) │  đo IPv6, trả rc
   └─────────────┘
```

Ranh giới hai chương trình rất rõ: **`warp-auto` quyết định, `warp-rotate`
hành động.** `warp-rotate` không biết gì về 429, không đọc log, không kiểm tra
idle. Nó chỉ "xoay" và báo cáo thành/bại. Điều này làm nó test được độc lập
và không nguy hiểm khi gọi tay.

OpenCode2 Zen có thêm một đường tín hiệu hẹp: plugin
`~/.config/opencode/plugins/zen-quota-retry.js` dùng
`ctx.aisdk.hook("sdk", ...)` để đặt proxy trên từng request Bun chỉ khi
provider là `opencode`, URL là `opencode.ai/zen/v1`, và body chọn model
`muse-spark-1.3-contributor-free`. Request model khác dùng `proxy: false`.
Launcher và service không đặt proxy toàn tiến trình; MCP, tool, subprocess và
provider khác đi trực tiếp. Nếu kết nối tới listener local `:40000` trả
`ECONNREFUSED`, plugin gửi lại đúng request Zen qua đường direct. Fallback này
chỉ áp dụng cho body có thể gửi lại an toàn; lỗi provider, HTTP 429 và lỗi reset
ở upstream không kích hoạt fallback.

The plugin state log records the route selected for each Zen API request and
the returned HTTP status. It records only route, request sequence, and status;
it does not record prompts, headers, or tokens. Use these entries to check
whether a request used `local-proxy-listener`, `system-route`, or
`direct-fallback`.

The retry hook handles only `opencode/muse-spark-1.3-contributor-free` 429
errors. Each failed attempt requests a WARP reset. Concurrent 429 hooks share
one active reset because WARP is system-wide. After a confirmed reset, the hook
waits 10 seconds before retrying. A later 429 requests another reset. If a reset
does not become ready, the hook also waits 10 seconds. A provider
`Retry-After` value takes precedence, capped at 10 seconds. Other models and
errors keep OpenCode's original decision. The plugin does not create prompts
or send `Continue`.

### 3.1. State (`~/.local/share/warp-rotate/`)

| File | Ý nghĩa |
|---|---|
| `auto.log` | nhật ký daemon, tự trim ở 2MB |
| `signals/zen-quota.log` | tín hiệu 429 riêng từ plugin Zen; không sửa log hoặc DB OpenCode |
| `last_rotate` | epoch lần xoay thành công gần nhất |
| `last_failed` | epoch lần xoay thất bại gần nhất → backoff |
| `backoff_logged` | stamp để không spam log khi đang chờ backoff |
| `need_rotate` | **latch**: đã thấy 429 nhưng chưa xoay được (cổng thời gian chặn) |
| `burst` | danh sách epoch của tín hiệu 429 gần đây |
| `stuck_edge` | số lần xoay liên tiếp rơi vào cùng một IPv6 edge |
| `off.<tên>.429` / `off.<tên>.403` | **cursor riêng từng file log** (thực tế là `off.opencode.429`, `off.oh-my-opencode-slim.<ts>.429`, …) |
| `lock` | flock chống chạy 2 instance |

Lưu ý: `log.offset` và `log.offset.403` (bản cursor dùng chung cũ) **đã thành
rác** từ lúc đổi sang cursor từng file. Chưa xoá vì daemon đang chạy.

---

## 4. Cấu trúc `warp-auto` (~545 dòng)

Hàm theo thứ tự trong file:

| Hàm | Việc |
|---|---|
| `log` / `trim_log` | ghi + giới hạn 2MB |
| `matches_429` | regex phân loại 429 |
| `record_signal` / `burst_count` / `clear_burst` | sổ đếm burst |
| `active_logs` / `offset_name` / `scan_new` | quét OpenCode logs và Zen signal file |
| `detect_429_db` | nguồn tín hiệu thứ hai: `opencode.db` (Mục 7.12) |
| `notify_rot` | desktop notification (Mục 5.3, 5.3.1) |
| `note_403_new` / `report_403` | ghi nhận 403, **không** xoay |
| `cooling_down` / `retry_blocked` | hai cổng thời gian |
| `do_rotate` | gọi rotator, kiểm rc, cập nhật state, báo 3 mốc |
| `handle_signal` | ghi tín hiệu vào burst, quyết định xoay |
| `check_once` | một vòng: 403 → 429 (log + DB) → latch → rotate |
| `wait_for_event` | vòng lặp daemon, inotify trên log OpenCode và Zen signal + fallback |
| `seed_cursors` | khởi động: bỏ qua lịch sử, chỉ đọc byte mới |

Khối `case "${1:-}"` xử lý argv nằn **cuối file**, sau mọi định nghĩa (Mục 7.14).
Cờ lệnh: `--once`, `--detect-test`, `--wait-test`, `-h|--help`.

### Tham số env

```
LOG_DIR=~/.local/share/opencode/log   LOG_FILE=$LOG_DIR/opencode.log
STATE_DIR                 WARP_ROTATE          ACTIVE_PLUGIN_LOGS=3
BURST_COUNT=3             BURST_WINDOW=120
COOLDOWN=0                RETRY_BACKOFF=300    MAX_STUCK=2
FALLBACK_POLL=30
DB_FILE                   DB_OVERLAP=0
ROTATE_NOTIFY=1           0 = tắt desktop notification
ROTATE_NOTIFY_GAP=60      giây, chỉ áp cho `start`; `done` luôn báo
```

`IMMEDIATE` là knob quan trọng nhất, giải thích ở Mục 5.1.

### Pattern

```
PATTERN='rate limit exceeded|retry-after|status[=: ]+429'
```

Đã loại `http.span=429` (trace span id) và `requires a login` (MCP) — cả hai
không phải 429.

Pattern 403 (`free tier can only be used|provider\.auth|UnsupportedProxyProtocol`)
chỉ để ghi log + notify, giới hạn 1 lần/30 phút.

---

## 5. Cấu trúc `warp-rotate` (~150 dòng)

```bash
CURL=(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY ... curl)   # bỏ proxy kế thừa
wait_connected()   # chờ WARP báo Connected
wait_down()        # chờ proxy thực sự chết (http_code=000)
wait_ready()       # chờ proxy thực sự phục vụ (http_code=200)
reconnect()        # off → wait_down → giữ DOWN_HOLD → on → wait_connected → wait_ready
```

- `MAX_ATTEMPTS=3`  `DOWN_HOLD=2`  `READY_TRIES=20`
- `exit 1` **chỉ** khi WARP không Connected lại được
- Đo IPv6 là tiêu chí thay đổi; IPv4 chỉ in ra để tham khảo
- Curl phải `env -u` proxy, nếu không sẽ đi qua proxy hai lần

### 5.0. Sự thật mới 2026-10-04 17:02: OpenCode **đã tự retry sẵn**

Yêu cầu ban đầu của người dùng là “xoay WARP theo cách tôi làm tay: tắt → chờ 2s →
bật lại, cố ý làm hỏng request đang bay để OpenCode **retry**”. Cơ chế ở Mục 5.1
xây trên giả định client **không** tự retry.

**Giả định đó sai.** Người dùng bắt được màn hình:

```
⚠ Retry due · attempt 2 · ECONNRESET: The socket connection was closed unexpectedly.
Fixer · Muse Spark 1.3 Free · 46.5s · 86.7 tok/s
Error: Rate limit exceeded. Please try again later.
```

Client tự retry theo backoff của AI SDK. Trong binary `opencode` (Bun, v1.18.31):
format `Retrying (attempt ${U}) · ${message}`, backoff theo `backoffFactor` /
`exponentialBackoffDelay`, có `retry-after` header và `session.retry.scheduled`
với mốc `at` là thời điểm thử lại.

Chuỗi thời gian đọc lại từ `opencode.db` + `auto.log`:

| Giờ | Sự kiện |
|---|---|
| 17:02:02 | `ECONNRESET` — do daemon cắt tunnel (lần xoay trước) |
| +15s | im lặng, client tự retry theo backoff |
| 17:02:17 | **429** — retry vẫn bị rate limit |
| 17:02:18 | rotate #1 → IPv6 **đã đổi** sang `…d444:16c8::245:52` |
| 17:02:28 | **429 lần nữa**, chỉ 3s sau khi xoay xong |
| 17:02:28 | rotate #2 → IPv6 **không đổi**, cùng một edge |

**Hệ quả trực tiếp — yêu cầu “kéo dài lỗi để retry không bị 429” là ngược hướng.**
Nếu giữ tunnel down lâu hơn, retry của client rơi vào giữa cửa sổ down và ăn
`ECONNREFUSED` thay vì 429: vẫn hỏng, chỉ đổi loại lỗi. Muốn retry **thành công**
thì tunnel phải **lên** đúng lúc client thử — tức là **rút ngắn** gián đoạn.

Vì vậy `DOWN_HOLD` (xem Mục 5.1) không nên kéo dài. Phần sửa lượt này tập trung vào
thứ đo được: **xoay vô ích** (Mục 5.5).

### 5.1. Cơ chế cốt lõi: cố ý làm hỏng request đang bay

> **Phần “chỉ khi request chết ở tầng TCP thì client mới retry” dưới đây là
> GIẢ ĐỊNH CŨ, đã bị bác bằng bằng chứng 17:02.** Client retry sẵn cả khi gặp
> 429 (Mục 5.0). Đo lại trước khi tin phần này. Giữ lại vì người dùng đã làm tay
> theo đúng thao tác đó, và nó vẫn giải thích vì sao `warp-rotate` chờ proxy
> thật sự phục vụ HTTP 200.

Đây là toàn bộ lý do tồn tại của chương trình. Người dùng làm thủ công ba bước:

```
tắt WARP  →  đợi ~2 giây  →  bật lại
```

Bước giữa **không phải** cho vui. Nó tạo ra một **cửa sổ downtime** đủ dài để
request đang bay gặp lỗi ở tầng TCP (`ECONNRESET` / connection refused). Chỉ
khi request chết ở tầng TCP, OpenCode mới **retry** — thay vì nhận HTTP 429 và
báo lỗi ra UI. Nếu daemon bật lại WARP quá nhanh, TCP không bao giờ gãy, client
giữ nguyên 429, và lần xoay đó **vô dụng** dù IP đã đổi.

Vì vậy `warp-rotate` **không** báo xong khi `warp-cli status` nói `Connected`.
Ba điều kiện phải đồng thời đúng:

| Bước | Hàm | Ý nghĩa |
|---|---|---|
| 1 | `warp-cli disconnect` | bắt đầu cửa sổ |
| 2 | `wait_down()` | `Disconnected` **và** `curl -x :40000` trả `http_code=000`. Nếu proxy vẫn trả lời → in cảnh báo "client will not see an error" và **bỏ qua** `DOWN_HOLD` |
| 3 | `sleep DOWN_HOLD` | giữ tunnel tắt đúng 2 giây như tay người |
| 4 | `warp-cli connect` | đóng cửa sổ |
| 5 | `wait_connected` + `wait_ready()` | chỉ tới khi proxy trả HTTP **200**. Retry của client rơi vào khoảng "socket đã mở nhưng chưa phục vụ" sẽ hỏng lần nữa và đốt mất IP mới |

Hai hàm kiểm chứng này (`wait_down`, `wait_ready`) là phần mà bản cũ thiếu, và
là phần làm cho bản mới khác bản cũ về **hành vi**, không chỉ về code.

`reconnect()` in ra **độ dài thật của hai cửa sổ**, để `auto.log` trả lời được
câu hỏi duy nhất quan trọng: lần xoay này có thực sự tạo ra down-window không.

```
down-window: 4s (proxy refused, held 2s — client saw a TCP error and will retry)
up-window:   9s (Connected at 5s, proxy serving HTTP 200)
```

Nếu thấy `down-window: NO` → lần xoay đó **vô dụng** với 429: client không bao
giờ thấy lỗi TCP nên vẫn giữ nguyên 429. Đừng quy kết cả 429 còn lại là do
`wait_down` hỏng mà không đọc dòng này.

### 5.2. Bỏ vòng lặp tắt/bật lại lần thứ hai

Bản cũ, khi IPv6 trùng, lặp lại `disconnect → connect` tới `MAX_ATTEMPTS`. Sai:
mỗi vòng thêm là thêm **một** cửa sổ downtime nữa giữa lúc client đang retry —
một lần fail thứ hai tệ hơn là rơi lại cùng edge. Nay `break` và báo trung thực.
`MAX_ATTEMPTS` chỉ còn dùng khi tunnel **vẫn down** sau vòng đầu (trường hợp
hiếm, đáng thử lại).

### 5.3. Thông báo desktop cho vòng đời xoay

Đo ngày 2026-10-04 15:07–15:10: daemon **có** phản ứng đúng, nhưng 429 vẫn nằm
trên màn hình ~93 giây vì `COOLDOWN` giữ nó. Không có tín hiệu nào cho user biết
đang chờ gì, nên biểu hiện y hệt daemon chết. Nay `notify_rot` báo **3 mốc**:

| key | Khi nào | Urgency |
|---|---|---|
| `start` | ngay trước khi gọi rotator | `low` |
| `done` | xoay xong (kèm IPv6 mới) hoặc **dừng vì IPv6 kẹt** | `normal` / `critical` |
| `failed` | WARP không kết nối lại được | `critical` |

Hai quyết định thiết kế đáng ghi:

- **`done` không bao giờ bị gap chặn; `start` mới chịu gap.** `done` là thứ duy
  nhất chứng minh lần xoay đã xong và nó mang địa chỉ mới. Đo được lúc
  15:57:40 / 15:58:04 (cách nhau 24s): lần thứ hai **đã xoay nhưng không báo
  gì**, vì stamp `done` của lần trước chưa hết 60s. Gap dùng chung cho mọi key
  là sai ở đây — nó chặn đúng thông tin cần nhất.
- **Stamp chỉ ghi sau khi gửi thành công.** Ghi trước thì một lần gửi lỗi trông
  y hệt lần gửi thành công ở vòng sau, và lần xoay đó biến mất không dấu vết.
  Giờ `notify FAILED (key): rc=...` ghi rõ trong `auto.log`.

`ROTATE_NOTIFY=0` để tắt hẳn, `ROTATE_NOTIFY_GAP` (mặc định 60) chỉnh độ thưa
của `start`.

Đừng thêm thông báo cho nhánh "bị cooldown giữ lại": nó sẽ dồn mỗi lần log event.

### 5.3.1. Notification không hiện popup? Kiểm tra DND trước

Đo 2026-10-04 16:14: `notify sent` trong log, `notify-send` rc=0, nhưng người
dùng không thấy gì. **Không phải lỗi của daemon.** Bằng chứng:

```
~/.local/state/omarchy/notifications.json  ->  { "version": 3, "dnd": true }
```

Notification daemon là Omarchy shell (quickshell, `GetCapabilities` trả
`persistence, body, actions…`). Nó chấp nhận và **ghi vào lịch sử** nhưng không
bật toast:

```qml
// /usr/share/omarchy/shell/plugins/notifications/Service.qml:173
if (service.doNotDisturb && !shouldBypassDnd(notification)) {
  if (!isEphemeral(notification)) { /* chỉ ghi history */ }
```

Cách xác nhận chắc chắn mà không cần đoán: đọc
`~/.local/state/omarchy/notifications/history/*.json`. Ở lần đo này có
`{"app":"warp-auto","summary":"WARP đã xoay xong","body":"IP mới: 2a09:bac5…"}`
— nghĩa là thông báo **đã tới đích**, chỉ bị giấu.

Cách tắt DND trên máy này: bấm chỉ báo DND trên thanh trạng thái
(`plugins/bar/indicators/Dnd.qml`), **hoặc** sửa `dnd: false` trong file trên rồi
restart quickshell. Người dùng 2026-10-04 chọn **giữ nguyên DND** — đừng tự tắt.

Hệ quả cho người sau: `notify sent` trong `auto.log` chỉ chứng minh lệnh gửi
chạy, **không** chứng minh người dùng thấy. Muốn xác nhận hiển thị thật thì
phải đọc file history ở trên.

### 5.4. `COOLDOWN=0` — xoay ngay, không hold

Yêu cầu của người dùng: thấy 429 thì xoay **ngay**, không chờ. Đo được lý do
làm vậy là có thật — `COOLDOWN=90` giữ một 429 trên màn hình **93 giây**, đúng
triệu chứng "lỗi treo gần 1 phút mà Continue không chạy".

`cooling_down()` tự tắt khi `COOLDOWN<=0`, nên mọi call site giữ nguyên hình
dạng. `COOLDOWN=0` **không** gây xoay liên tục: mỗi lần xoay tự nó mất ~7s
(2s down + 5s up), đó là trần tự nhiên. Lớp bảo vệ còn lại là `MAX_STUCK` + park
(Mục 5.5).

### 5.5. Dừng thật khi WARP trả lại cùng một IP (`stuck_until`)

Đo 17:02:28: rotate #2 trả về **đúng** IPv6 của rotate #1. Tổng của 30 lần xoay
gần nhất: **3/30 (10%)** không đổi IPv6. Mỗi lần đó là một vòng gián đoạn 7s hoàn
toàn vô ích — cắt tunnel để rồi vẫn ở đúng edge đang bị rate limit.

Sửa gồm hai phần, và **phần thứ hai mới là phần quan trọng**:

1. `MAX_STUCK=1` — dừng ngay ở lần trùng đầu tiên.
2. **`stuck_until` (park)** — khi dừng, ghi `now + STUCK_PARK` (**mặc định10s**,
   xuất 120s ngày 04/10/2026 — xem Mục 5.6) thay vì chỉ xoá latch.

Lý do phải có phần 2: bản đầu chỉ làm `rm -f "$PENDING_FILE"`. Đo lại:

```
MAX_STUCK=1, 6 lần 429 liên tiếp với IPv6 kẹt → cắt tunnel 6 lần  ← FAIL
```

Vì 429 mới 1 giây sau lại vô hiệu hoá `handle_signal`, daemon xoay tiếp, rơi vào
cùng edge, lặp lại. “Xoá latch” ≠ “dừng”. Muốn dừng thật thì phải có thời gian
chờ. `stuck_until` được kiểm tra **đầu** `handle_signal`, trước cả cổng cooldown
và trước khi latch có cơ hội vũ trang lại:

```
6 lần 429 liên tiếp, IPv6 kẹt  →  1 lần gián đoạn  ← PASS
hết park (120s)                →  xoay lại được    ← PASS
IPv6 đổi bình thường           →  xoay bình thường, park không chặn  ← PASS
```

Khi park hết, `stuck_edge` phải reset về 0 — nếu không, bộ đếm vẫn kẹt ở
`MAX_STUCK` và lần 429 kế tiếp dừng ngay mà chưa từng thử. Đo được lỗi này.

### 5.6. `STUCK_PARK` 120s → 10s (2026-10-04 22:12)

Park ở Mục 5.5 chống đúng chuyện nó sinh ra, nhưng với giá trị 120s nó **lặp lại
đúng triệu chứng mà nó sinh ra**: người dùng bị 429, daemon nhìn thấy 429 và
từ chối xoay trong 2 phút.

Đo được trong `auto.log` ngày 04/10, 21:50–21:51:

```
21:50:42  rotate stopped: IPv6 edge stuck on 2a09:bac5:d444:e6::17:32d
          — parked 120s, no more tunnel cuts for this edge
21:51:02  saw 1 rate-limit line(s) but parked (100s left)
21:51:05  saw 1 rate-limit line(s) but parked (97s left)
21:51:24  saw 1 rate-limit line(s) but parked (78s left)
21:51:37  ← 429 vẫn tiếp tục
```

23 giây đó có **6 lần daemon thấy 429 và 6 lần từ chối xoay**. Người dùng
thấy animation "vừa bật xong" (đó là lần xoay trước, lúc 21:50:28→35) rồi
im lặng 120s — trông y hệt daemon treo.

Park cũng **có báo** (notification critical *"WARP không xoay được IP…429 có
thể phải tự hết"*), nhưng `~/.local/state/omarchy/notifications.json` là
`{"dnd": true}` nên chỉ ghi history, không popup — xem Mục 5.3.1. Vì vậy quyết
định "tôi sẽ dừng" không bao giờ tới được người dùng.

Hậu quả đo được trên 2.5 ngày (~171 lần xoay có dữ liệu 429):

| Kết quả sau một lần xoay | n | median |
|---|---|---|
| Egress mới sống được | 107 | 346s |
| Egress mới hỏng lại | 70 | **12s** |

Và trong 70 lần hỏng nhanh đó, **39 lần không hề có lần xoay nào ở giữa** —
daemon đứng yên do park, **không phải** xoay dở rồi thất bại. Đây là lý do
giảm còn 10s: vẫn cắt vòng lặp "xoay lặp vô ích" mà Mục 5.5 cần, nhưng không
biến một rate limit đang sống thành 2 phút chết.

**Đã xác minh bằng quan sát runtime.** Ngày 04/10 lúc22:15:14, đúng một ca
park xảy ra sau khi đổi, và nó dừng ở 10s như cấu hình mới:

```
22:15:14  rotate stopped: IPv6 edge stuck on 2a09:bac1:7aa0:48::498:6a
          — parked 10s, no more tunnel cuts for this edge
```

Chưa làm, vẫn để ngỏ: cho phép **phá park khi 429 vẫn tiếp tục tới** — đó mới
là thứ triệt tiêu "chờ lâu" triệt để.

**Lỗi liên quan phát hiện cùng lúc, chưa sửa:** nếu `warp-rotate` in ra
`before  IPv6: unknown` (proxy đang down lúc probe), thì điều kiện so sánh ở
`warp-auto` không kích hoạt vì cần `-n "$ip6_before"` — daemon không ghi nhận
trùng edge, không park, và xoay lại ngay. Đo 22:33–22:35: 6 lần xoay trong 2
phút, trong đó lần 22:33:46 trả về `2a09:bac1:7a80:48::498:68` và lần kế tiếp
(22:33:56) lại xuất phát từ đúng địa chỉ đó — tức nó quay về đúng edge, đúng
thứ `MAX_STUCK` sinh ra để chặn.

---

### 5.7. Đo kết quả thật của mỗi lần xoay (`rotations.tsv`) — 2026-10-06 09:06

**Vấn đề:** suốt 5 ngày, *không có bất kỳ số liệu nào* chứng minh lần xoay có ích
hay không. `auto.log` ghi `rotate done` cho mọi lần xoay trả về rc=0 — kể cả
lần cắt tunnel 2 giây rồi 429 vẫn về đúng như cũ. "Thành công về mặt kỹ thuật"
không phải "chữa được rate limit".

**Vì sao không đo được trước đây:** `auto.log` trim ở `MAX_LOG_BYTES` (2MB) nên
chỉ giữ được:

| Nguồn | Khoảng thời gian còn lại |
|---|---|
| `auto.log` (lịch sử xoay) | 148 lần xoay, 2026-10-04 22:15 → 10-06 06:07 (~1.5 ngày) |
| `opencode.db` (429) | 657 sự kiện, 2026-09-04 → 10-06 (~30 ngày) |

Không giao được 2 nguồn này với nhau → **217 episode 429 thì chỉ 54 rơi vào vùng
log còn lại**. Không có cohort đối chứng nào đủ tin cậy.

**Đo lại trên vùng còn lại** (429 đầu mỗi episode, `gap > 120s`, chỉ lần xoay có
đổi edge):

| | Sau lần xoay (n=61) | Không xoay (n=17) |
|---|---|---|
| Không có 429 nữa trong 30s | 77% | 100% |
| ... 120s | 66% | 35% |
| ... 600s | 36% | 0% |
| **Còn 429 trong 15 phút** | **75%** | — |

Con số 75% là câu trả lời cho "xoay có hiệu quả không": phần lớn lần xoay **không
chữa được** rate limit. Nhưng cohort đối chứng chỉ n=17 và bị lẫn nhau, nên đây
mới là **ước lượng**, chưa phải kết luận. Số liệu chắc chắn sẽ tích luỹ trong
ledger mới.

**Đã cài:** `~/.local/share/warp-rotate/rotations.tsv` — TSV bền vững, không bị
trim kiểu `auto.log` (giữ 5000 dòng / 512KB):

```
R<TAB>epoch<TAB>giờ<TAB>lý do<TAB>IPv6 trước<TAB>IPv6 sau<TAB>đổi edge?<TAB>rc
V<TAB>epoch<TAB>số giây đã chờ<TAB>số 429 đếm được sau đó
```

`V` do `resolve_outcomes()` ghi mỗi vòng daemon: đợi `OUTCOME_WAIT` (mặc định
120s) rồi đếm số dòng `Rate limit exceeded` trong `opencode.db` có
`time_created > epoch`. `V … 0` = lần xoay ăn; `V … N` (N>0) = **đã cắt tunnel
vô ích**. Hàng `R` được ghi *trước mọi early-return*, nên ca dừng do trùng edge
cũng được chấm điểm — đúng những ca trước đây trông như thành công.

Biến: `LEDGER`, `OUTCOME_WAIT`, `OUTCOME_ENABLE=0` để tắt.

**Kiểm chứng:** hộp cát (`STATE_DIR`/`LOG_DIR`/`WARP_ROTATE`/`DB_FILE` riêng, rotator
giả) chứng minh cả hai chiều — `V … 0` khi không có 429, `V … 3` khi có 3 429
sau xoay. Trên máy thật: rotate 09:06:23 → `V 1791252383 122 0`.

**Còn thiếu, chưa giải quyết được:** không có tín hiệu nào cho biết 429 hết lúc
nào. Probe thử:
- `GET /zen/v1/models` → **200**, không cần key, không rate-limit → vô dụng để dò
- `POST /zen/v1/chat/completions` với key sai → **401 `Invalid API key`**, tức
  auth kiểm tra **trước** rate-limit → không dò được 429 bằng key giả
- Không có header `Retry-After` hay `rate-limit-reset` nào trong log server
  (lần chữ `Retry-After` duy nhất là *tên task* "Fix 429 Retry-After IPv4")

Nên `OUTCOME_WAIT=120` là **đo theo kinh nghiệm**, không lấy từ server. Muốn
chính xác hơn thì phải có `opencode/zen` key hợp lệ trong `auth.json` — hiệnchỉ có provider `bai`.

---

### 5.8. Chuẩn 429 chính xác + mảnh ghép IP (`edge_timeline.tsv`, `warp-report`) — 2026-10-06 09:15

**1. Đang đếm 429 sai. Tìm được cách đếm đúng.**

> **Đã áp dụng vào daemon.** Ban đầu việc này chỉ sửa phân tích. Sau đó kiểm tra lại
> thì phát hiện `detect_429_db()` — chỗ **quyết định có xoay hay không** — vẫn dùng
> `LIKE`. Đo trên 24h gần nhất: `LIKE` ra **96**, `error.type` ra **79**.
>
> Lỗi nặng nhất không phải đếm thừa mà là cursor: `hi = max(time_created)` được tính
> trên cùng điều kiện `LIKE`, nên nó **tiến cả khi gặp dòng chỉ nhắc chuỗi trong
> log**. Một rate limit thật xuất hiện sau đó sẽ nằm **dưới** cursor và không bao
> giờ được đếm — tức daemon im lặng đúng lúc cần xoay nhất.
>
> Đã sửa cả `detect_429_db()` và `resolve_outcomes()` sang `error.type`. Timeline #34.

Mọi phân tích trước đây dùng `data LIKE '%Rate limit exceeded%'`. Nhưng mỗi dòng
`assistant` trong DB có trường `error.type` có sẵn. So sánh:

| Cách đếm | Số dòng |
|---|---|
| `LIKE '%Rate limit exceeded%'` | 657 |
| `error.type = 'provider.quota'` | **393** |

Chênh 264 dòng là **false positive**: chuỗi đó xuất hiện trong `user` (16),
`synthetic` (61), `system` (9) — tức log được nhúng lại vào nội dung message, hoặc
lỗi được ghi ở nhiều tầng. Chỉ `assistant` + `error.type` mới là một rate limit
thật. Từ giờ dùng `error.type`, không dùng `LIKE`.

**Phân loại đầy đủ lỗi** (`assistant` rows, toàn bộ lịch sử):

| `error.type` | Số | Nghĩa là |
|---|---|---|
| `provider.quota` | 393 | **rate limit — đây là thứ ta xoay** |
| `provider.transport` | 270 | `ECONNRESET` |
| `aborted` | 134 | huỷ giữa chừng |
| `provider.auth` | 31 | 403 free tier |
| `provider.error` / `internal` / `invalid-output` | 28 / 10 / 6 | lỗi provider khác |

**2. Tỉ lệ rate limit thật** (quota ÷ (quota + request thành công)):

| Ngày | quota | ok | tỉ lệ |
|---|---|---|---|
| 10-06 | 2 | 745 | **0.27%** |
| 10-05 | 88 | 3860 | 2.23% |
| 10-04 | 132 | 7675 | 1.69% |
| 10-03 | 53 | 5375 | 0.98% |
| 10-02 | 14 | 5063 | 0.28% |
| 10-01 | 21 | 3536 | 0.59% |
| 10-04→06 | 334 | 30908 | **1.07%** |

Trước đây chỉ nhìn *số lượng* 429 nên tưởng là “nhiều vấn đề”. Tính trên lưu
lượng thật thì **1.07%** — và biến động lớn theo giờ: `10-05 21:00` là 6/164
(3.7%), `10-06 08:00` là **0/564 (0%)**.

**3. Lỗ hổng gốc: không có bản ghi IP nào ngoài lúc xoay.**

Đo trực tiếp: `journalctl --user` có 136206 dòng liên quan WARP nhưng **0 địa chỉ
IPv6**. `auto.log` chỉ có IP trong khối output của `warp-rotate`. Hệ quả: một 429
đến lúc không có rotate nào chạy thì **không biết nó gắn với IP nào** — dữ liệu
tồn tại nhưng không ghép được. Đó là lý do mọi phân tích trước đều dừng ở mức
ước lượng.

Đã cài `edge_timeline.tsv`: `epoch<TAB>giờ<TAB>IPv6`, chỉ ghi khi IP **đổi**
(không phải mỗi lần poll), nên một edge giữ nguyên 6 tiếng = 1 dòng.

Probe bị giới hạn bởi `EDGE_POLL` (mặc định 60s). Đo được: một lần probe mất
**774ms** (curl blocking qua proxy), mà daemon thức dậy theo inotify — tức mỗi
lần OpenCode ghi log. Nếu probe mỗi vòng thì đó là hàng trăm ms mỗi phút chỉ để
đọc một giá trị gần như không đổi. Lần đầu `EDGE_POLL` chỉ được khai báo mà
không dùng — đã sửa, nay có `edge_probed` làm mốc thời gian.

**Bằng chứng nó bắt được thứ mọi log khác bỏ sót:** ngay sau khi cài, WARP **tự
đổi edge lúc 09:14:43** (`…bac1:7a80::3d0:6` → `…bac5:d441:2646::3d0:6`) mà
**không có `rotate start` nào** — không phải ta yêu cầu. Journal cũng không ghi.
Timeline bắt được ngay:

```
1791252877  2026-10-06 09:14:37  2a09:bac1:7a80:48::3d0:6
1791252883  2026-10-06 09:14:43  2a09:bac5:d441:2646::3d0:6
```

Điều này cũng giải thích **một điều chưa giải thích được** ở Mục 5.6: lần IPv6
đổi 21:59→22:03 không ghi rotate. Không phải lỗi đo — WARP tự đổi edge.

**4. `provider.transport` (ECONNRESET) tăng song song với rotate.**

Message là `ECONNRESET: The socket connection was closed unexpectedly`.

| Ngày | transport | quota | tỉ lệ transport:quota |
|---|---|---|---|
| 10-06 | 12 | 2 | **6.00** |
| 10-05 | 76 | 88 | 0.86 |
| 10-04 | 106 | 132 | 0.80 |
| 10-03 | 38 | 53 | 0.72 |
| 10-02 | 1 | 14 | 0.07 |
| 10-01 | 1 | 21 | 0.05 |

Trước 03/10 daemon chưa chạy (0.05–0.07), từ 03/10 lên 0.7–0.86.

> **ĐÍNH CHÍNH (2026-10-06 09:45).** Bản đầu của Mục này kết luận “mỗi lần xoay
> đều sinh ra lỗi mới”. **Sai.** Đo lại trên cửa sổ log (34.9h, 149 lần xoay, 98
> lỗi transport):
>
> | Khoảng cách tới lần xoay gần nhất | Số lỗi |
> |---|---|
> | ≤ 5s | 6/98 (6%) |
> | ≤ 10s | 15/98 (15%) |
> | ≤ 20s | 22/98 (22%) |
> | ≤ 30s | **26/98 (27%)** |
> | > 5 phút | 55/98 (56%) |
>
> Nếu hai sự kiện không liên quan, kỳ vọng chỉ **7.0** lỗi nằm trong ±30s — quan
> sát 26 là **dương thực kỳ (p < 0.001)**, tức cắt tunnel **có** làm hỏng request
> đang bay. Nhưng chỉ **27%**, không phải 100%: phần lớn lỗi transport **không**
> do ta. Nguyên nhân còn lại chưa xác định — khả năng cao là WARP tự đổi edge
> (Mục 5.9), vì một lần đổi edge cũng làm rơi các stream đang mở.
>
> Ngày 06/10 có tỉ lệ 6.00 nhưng mẫu chỉ 12 lỗi, **không dùng để kết luận**.

**5. Đã cài `warp-report`** — chỉ đọc, không đụng tunnel:

```
~/.local/bin/warp-report          # DAYS=14 ./warp-report
```

Báo cáo 4 phần: (1) tỉ lệ rate limit theo ngày, (2) độ phủ timeline, (3) rate
limit **theo từng edge**, (4) mỗi lần xoay có thực sự dứt 429 không. Mở DB ở
chế độ `mode=ro` nên không thể ghi nhầm.

**Kết luận hiện tại, nói thẳng:** chưa đủ dữ liệu để kết luận 429 có gắn với IP
hay không. Cổ hở đã được vá (timeline + report), cần ~1–2 ngày dùng bình thường
để có mẫu đủ lớn.

---

### 5.9. Phát hiện lớn nhất: **WARP tự đổi edge, không cần ai xoay**

Timeline chạy được ~20 phút đã ghi **7 lần đổi edge** trong khi có **0 lần
rotate**:

```
09:14:37  2a09:bac1:7a80:48::3d0:6
09:14:43  2a09:bac5:d441:2646::3d0:6
09:15:00  2a09:bac1:7aa0:48::3d0:6
09:20:34  2a09:bac5:d444:2646::3d0:6   <- không có rotate
09:24:35  2a09:bac5:d445:2646::3d0:6   <- không có rotate
09:29:55  2a09:bac1:7a80:48::3d0:6   <- không có rotate
09:36:31  2a09:bac5:d441:2646::3d0:6   <- không có rotate
```

Khoảng cách giữa các lần: `[6s, 17s, 334s, 241s, 320s, 396s]` — **median 320s**.

Xác minh độc lập lúc 09:37, probe 5 lần trong 20s:

```
09:37:00  2a09:bac5:d441:2646::3d0:6
09:37:05  2a09:bac5:d441:2646::3d0:6
09:37:10  2a09:bac5:d441:2646::3d0:6
09:37:14  (rỗng — probe lỗi, không phải IP mới)
09:37:19  2a09:bac5:d443:2646::3d0:6   <- tự đổi giữa chừng
```

Suốt thời gian đó `warp-cli status` = `Connected` / `Network: healthy` và
**không có `rotate start` nào**. Tức WARP tự chuyển edge theo chu kỳ ~5 phút.

**Vì sao đây là phát hiện lớn:**

1. **Nó giải thích điều chưa giải thích được.** Mục 5.6 ghi lại một lần IPv6 đổi
   21:59→22:03 mà không có rotate nào trong log. Không phải lỗi đo — WARP tự đổi,
   và trước đây không ai ghi lại nên nhìn như sự cố.
2. **Nó làm nghi ngờ giả định của cả daemon.** `MAX_STUCK` được sinh ra để dừng
   việc cắt tunnel khi WARP trả lại cùng một edge. Nếu edge tự đổi mỗi ~5
   phút thì "bị kẹt" hiếm khi xảy ra và khi xảy ra nó sẽ tự thoát — cơ chế park
   có thể đang chặn oan.
3. **Nó gợi ý hướng cải thiện rẻ hơn nhiều:** nếu WARP tự xoay vân tay theo
   chu kỳ, thì đợi WARP tự xoay rẻ hơn là cắt tunnel (mỗi lần cắt đều sinh
   `ECONNRESET` — Mục 5.8). **Chưa kết luận được**, cần dữ liệu nhiều ngày.

**Trạng thái:** `stuck_edge=0`, `stuck_until` không có, 0 lần park hôm nay. Cơ chế
hiện tại **không** đang chặn oan — nhưng cũng chưa có bằng chứng nào cho thấy nó
còn cần thiết. Sẽ biết sau khi có dữ liệu.

---

### 5.10. Theo dõi **toàn bộ request**, không chỉ lỗi 429

`warp-report` nay có 8 phần (5–8 là mới). Mỗi dòng `assistant` trong DB có đủ
`model`, `tokens`, `cost`, `time.created/completed`, `error.type`, `retry` — nên
không cần thêm gì để đo.

Private daily request totals, token totals, and model usage counts are omitted.
The useful lesson is to compare error rate and latency separately. A quota
error does not by itself explain a change in successful request latency.

Quota errors can be concentrated on one model. This does not prove that the
limit depends only on the model, or that an IP change cannot help. A model
with fewer requests is not a valid control without comparable conditions.

**Retry — cái giá trực tiếp của việc cắt tunnel:**

| attempt | số request |
|---|---|
| 2 | 254 |
| 3 | 9 |
| 4 | 5 |
| 5 | 2 |
| 7 | 1 |
| 8 | 1 |

Có request phải thử tới **8 lần** mới xong. `retry.error.type` toàn là
`provider.transport` (ECONNRESET) — tức các lần thử lại là do tunnel bị cắt, không
phải do provider.

---

### 5.11. Giải mã chuỗi retry — và 46 lần cắt tunnel vô ích

**Cấu trúc thật.** Một dòng `assistant` có trường `retry` = *một lần thử đã thất
bại*, với `retry.at` là thời điểm lần thử đó xảy ra. Quan trọng: `retry.at`
**lớn hơn** `time_created` của chính dòng đó — nó nằm ở tương lai so với dòng.
Kết quả của chuỗi nằm ở dòng `assistant` **kế tiếp**, nên phải nối hai dòng mới
biết retry có cứu được gì không.

> **Lỗi của tôi, đã sửa.** Lần đầu tôi tính `time_created/1000 - retry.at` và ra
> “48760023.9 giờ” — vô lý vì trộn ms với giây. Số đúng: tuổi request tại lúc retry
> trung vị **9.9s**.

**Kết quả chuỗi (273 request có retry):**

| Kết cục chuỗi | Số | % |
|---|---|---|
| `recovered (tool-calls)` | 196 | **71%** |
| **`provider.quota`** | **46** | **17%** |
| `recovered (stop)` | 18 | 6% |
| `provider.transport` | 11 | 4% |
| không có gì trong 60s | 4 | 1% |
| `aborted` | 2 | 1% |

Tổng thời gian cháy: median **10s**/request, max 282s, **1.9 giờ** cho 273 request.

**Đây là phát hiện quan trọng nhất của toàn bộ phân tích.** 71% retry thành công —
tức cơ chế “cắt tunnel buộc client thử lại” **có hiệu lực** về mặt kỹ thuật. Nhưng
**46 request (17%) hết bằng `provider.quota`**: retry chạy xong rồi vẫn dính rate
limit. Với 46 trường hợp đó, lần cắt tunnel **không tạo ra lợi ích nào** — vừa
làm hỏng request, vừa vẫn 429.

**Quan trọng:** OpenCode **không retry rate limit** — 393 lỗi quota, **0** cái nào
có trường `retry`. Nó chỉ retry lỗi transport. Nên khi 429 đến, lần cắt tunnel do
daemon gây ra không giúp nó retry; nó chỉ làm request đang bay hỏng thêm.

**Ba kiểu dữ liệu còn thiếu đã kiểm tra, không có:**
- Bảng `message` is an older table; `session_message` contains newer records →
  đây là bảng legacy đã bị thay thế, **không phải lỗ hổng dữ liệu**.
- Bảng `part` chỉ chứa `tool`/`step-*`/`reasoning`/`patch`/`text` —
  là nội dung, không có tín hiệu provider nào thêm.
- `opencode.log` có `durationMs` nhưng chỉ cho **MCP server** (`server=cloudflare`
  ×263…), không phải request tới provider. 312 `status=401` đều là
  `mcp http authentication rejected` — không liên quan.

**Còn thiếu duy nhất: thời gian.** `edge_timeline.tsv` mới phủ ~30 phút. Cần
**1–2 ngày** để nối được `provider.quota` với edge cụ thể. Từ ngày 06/10 tần suất
quota là ~48/ngày và edge đổi ~5 lần/20 phút, nên chỉ cần vài chục lỗi quota là đủ
để có cohort có ý nghĩa.

---

### 5.12. Kết luận **không phụ thuộc model** — và sửa một đề xuất sai

Changing the model is not a substitute for fixing the requested model's
behavior. Separate model-specific limits from the client's retry rules.

Đo lại trên toàn DB:

| Nguyên nhân khiến client retry | Số |
|---|---|
| `provider.transport` | 270 |
| `provider.invalid-output` | 6 |
| `provider.internal` | 2 |
| **`provider.quota`** | **0** |

| Kết quả cuối | Số |
|---|---|
| `provider.quota` | **393** |
| ... trong đó có retry | **0** |
| `retry.error.type = 'provider.quota'` | **0** |

**Đây là quy luật của client, không phải của model:** OpenCode **không bao giờ**
retry một rate limit. Nó chỉ retry lỗi đường truyền. Điều này đúng với mọi model,
vì nó nằm ở tầng retry của client chứ không ở provider.

**Hệ quả trực tiếp với triết lý hiện tại.** Cơ chế của daemon là “cắt tunnel để
buộc client thử lại”. Thử lại chỉ xảy ra với lỗi transport. Với lỗi quota:

```
request nhận 429  ->  terminal, client không retry  ->  user phải bấm Continue
daemon cắt tunnel ->  request ĐANG BAY khác nhận ECONNRESET -> client retry
                     ->  request mới vẫn 429 (vì limit vẫn còn)
```

Tức lần cắt **không chữa được** request đã dính 429, chỉ làm hỏng thêm request
khác. Đo trên 149 lần xoay trong cửa sổ log, xem có request nào đang bay không:

| | Số | % |
|---|---|---|
| Xoay trùng một request đang chạy | 39 | 26% |
| **Xoay mà không có request nào đang bay** | **110** | **74%** |

**74% lần xoay không đụng gì cả** — cắt tunnel, chờ proxy lên 5–7 giây, rồi không
có tác dụng gì.

> **ĐÍNH CHÍNH (lần 2).** Bản đầu tôi tính là **36%** (96/149 có trúng) bằng cách
> lấy 200 dòng `assistant` bất kỳ sau vị trí xoay rồi thử overlap. Cách đó **sai**:
> 200 dòng có thể trải về nhiều **giờ** dữ liệu nên match quá rộng. Đo lại bằng
> interval thật (`created <= t <= completed`), lookback 600s theo p99 thời lượng
> request, cho **39/149 = 26%**. Hai cách lệch nhau 64% vs 26% nên số cũ bị bỏ.
>
> Thời lượng request: median 5.7s, p90 26.6s — nên request rất ngắn, phần lớn thời
> gian bạn không có gì đang bay, và xoay vào lúc đó chỉ là gián đoạn vô ích.

**Định hướng tối ưu đúng — áp dụng cho mọi model, không cần đổi model:**

Cấu trúc trong `rotations.tsv` (`epoch`, `reason`, `ipv6 trước`, `ipv6 sau`,
`đổi edge?`, `rc`) và cột `V` **không chứa gì về model**. Nghĩa là chính sách
xoay có thể được chấm điểm thuần theo hiệu quả đo được, độc lập model:

1. Mỗi lần xoay có verdict `V … 0` (ăn) hay `V … N` (vô ích) — đã có, đang ghi.
2. Khi cửa sổ gần đây nghiêng về `V > 0`, giảm tần suất xoay thay vì xoay liên tục.
3. Khi nhiều lần xoay liên tiếp **không trúng request nào đang bay** (loại 74% ở
   trên), đó là cắt vô ích tuyệt đối — nên bỏ qua, không cần đợi phản hồi.

Điểm 3 là hướng **rẻ và chắc nhất**: nó không phụ thuộc vào việc 429 có gắn với IP
hay không, nên áp dụng được ngay mà không cần chờ dữ liệu còn thiếu. Đòi hỏi thêm
một cột `hits` (số request đang bay lúc xoay) — đo được từ `opencode.db`.

**Đã đo chi phí để biết là làm được không:**

| Truy vấn | Thời gian |
|---|---|
| Quét toàn bảng (89k dòng) | **1487ms** — quá chậm cho loop |
| Giới hạn `time_created > now-300s` | **1ms** — dùng được |

Cửa sổ 5 phút là đủ vì thời lượng request p90 chỉ 26.6s, và có sẵn index
`session_message_time_created_idx`. **Chưa cài** vì đây là thay đổi hành vi
daemon — cần bạn đồng ý trước.

---

### 5.13. Lỗi `The request contains invalid parameters` — **không phải WARP**, và không phải quota

Error format:

```
Error: Error from provider (Console): The request contains invalid parameters.
Check the request body for any errors or inconsistencies.
```

**Đây là HTTP 400 của upstream, không phải 429 và không phải đứt tunnel.**
Trong DB nó là `error.type = 'provider.invalid-request'`, kèm `status: 400`,
`content: []`, và **token = 0** (không đếm được token nào → request bị chặn
ở tầng validate, trước khi model sinh bất cứ thứ gì). `retry.at` rỗng →
**OpenCode không retry lỗi này**, nên nó hiện thẳng ra cho bạn thấy.

**Diagnostic lesson:** Check `rotations.tsv` and `auto.log` before attributing
an error to WARP. A structured HTTP 400 response is not the same as a transport
reset (`ECONNRESET` or `ConnectionRefused`, reported as `provider.transport`).
Other successful requests through the same gateway can help distinguish a
request-specific failure from a service outage.

Do not infer a context limit from this generic error. Larger successful
requests alone do not establish which payload field was rejected. The old
context-size diagnosis was too strong.

A session payload can remain invalid after a tool-call turn. Repeating the
same history can repeat the HTTP 400. Older error formats used
`provider.error` with `Upstream request failed: [invalid_request_error] ...`;
newer formats use `provider.invalid-request`. Private session identifiers,
prompt sizes, usage counts, and interaction timelines are omitted.

> Cộng đồng cũng gặp lỗi này. `opencode.ai/zen` chuỗi hội thoại qua
> `previous_response_id`; khi upstream không còn nhận ra id đó (hết hạn /
> bị thu hồi) hoặc không validate được payload, nó trả **400 chung chung**
> `invalid_request_error: The request contains invalid parameters` — không
> có chữ "context length exceeded", không có mã lỗi cụ thể. Vì vậy **không
> đọc được nguyên nhân từ phía client**; chỉ biết nó là lỗi của request body.

**Cách khôi phục:** `/fork` (giữ lịch sử, bỏ chuỗi server-side bị nhiễm) →
`/compact` (viết lại lịch sử thành tóm tắt) → session mới. **Xoay tunnel
không giúp ích gì** cho lỗi này.

*Không tự động hoá được:* `opencode run --session <id> --fork` trả
`Error: Session not found` — CLI không resolve được session do TUI tạo; API
của server thì cần mật khẩu trong `~/.config/opencode/cli.json`. Phải bấm
tay trong TUI.

If a separate request succeeds, that does not prove that the original payload
is valid. Do not run a live probe without permission.

**Đã thêm Mục 10 vào `warp-report`:** liệt kê session có ≥3 lần fail **nối
tiếp ở đuôi** (sau lượt OK cuối cùng). This is a diagnostic signal, not proof
that a session cannot recover.

---

### 5.14. Thử nghiệm auto-Continue đã nghỉ — 2026-10-06

Một thử nghiệm cũ gửi message `Continue` sau quota. Nó có nguy cơ tạo prompt
thay mặt người dùng và đã bị thay thế. Plugin `zen-quota-continue.js` không
còn tồn tại. Thiết kế hiện tại chỉ chờ WARP xoay xong rồi thử lại cùng model
call tối đa một lần; không gửi prompt hoặc `Continue`.

The old experiment treated a later user message as a new turn, not a retry
of the failed request. Its private interaction timeline is omitted.

---

### 5.15. Speedup pass 2026-10-08: xoay và chuyển nhanh hơn, rẻ hơn

Chỉ đổi params/timeouts, mỗi cái có số liệu. Không đụng `DOWN_HOLD=2` (floor
của user), parks, dedupe windows, `RETRY_AFTER_CAP`, hay plugin nhà.

| Đổi | Cũ → Mới | Số liệu |
|---|---|---|
| `wait_connected` poll | 2s → 1s (vẫn trần 60s) | up-window 204×4s + 254×5s: lượng tử hoá 2s, mỗi xoay trả thêm ~1s |
| `probe_ipv6` poll | 2s → 1s (vẫn trần ~20s) | cùng họ với trên, nhánh retry sau connect |
| `ZEN_DRAIN_S` | 30s → 10s | đúng 1 lần drain trong 339 xoay (22:18:40), timeout 100%, +30s stall (36s so với 7s thường) mà vẫn cắt |
| retry-fallback (hint vắng) | 5s → 3s | 0 hint trong 326 dòng signal + 0 trong plugin log → fallback là đường nóng; mỗi sleep chặn cả vòng daemon |
| `EDGE_PROBE_TIMEOUT` | 8s → 5s | probe nền (đường xoay dùng timeout riêng); gap edge median 223s nên rớt một mẫu vô hại |

Đo trên state giả (`tests/test-speedup.sh`, không đụng tunnel): drain kẹt
30s → 10s; vòng backoff thiếu-hint 5s → 3s; `wait_connected` (connect ở poll
thứ 3) 4s → 2s. Suite đầy đủ xanh (130 pass), `timing-probe` xanh.

Không đổi và vì sao: plugin `PROXY_WAIT_MS`/`ROTATE_WAIT_MS` (14 timeout =
bound đang làm đúng việc, fail-nhanh ≠ chữa-nhanh; file của user);
`ROTATE_BACKOFF=300` (0 lần fail thật — 14 lần rc=127 là bug path đã sửa);
`HOOK_DEDUPE=45` (không có double-rotate nào); parks/dedupe
(tunnel 25s/90s, proxy 90s/600s, stuck 10s — user đã chốt).

---

## 6. Timeline các lần chỉnh sửa

| # | Thay đổi | Vì sao |
|---|---|---|
| 1 | Xoay theo interval 30 phút | bản đầu, sai |
| 2 | Event-driven bằng inotify | đo được độ trễ 2s so với 30s |
| 3 | Escalation 3 mức + cooldown chung + backoff 300s | một tín hiệu không đủ, retry thất bại thì xoay vô hạn |
| 4 | Xoá nhánh preemptive | Nhánh không bao giờ chạy theo số liệu lúc đó; đã xoá khỏi code. Giữ phép đo ở lịch sử để giải thích quyết định |
| 5 | Xoá timer 30 phút | 10 lần 429/28h *dù đã xoay mỗi 30 phút* |
| 6 | Định nghĩa lại "thành công" | `rotate done` ghi cả khi xoay hỏng; nay check rc, giữ latch, ghi `last_failed`, **không** stamp `last_rotate` |
| 7 | Theo dõi **cả thư mục** log | daemon mắt đúng nhưng nhìn sai chỗ (Mục 7.3) |
| 8 | Cursor **riêng từng file** | một offset chung nhảy lung tung khi chuyển file mới |
| 9 | `IDLE_HOLD=20` | chặn `ConnectionRefused` (Mục 7.4) |
| 10 | Đo IPv6 thay vì IPv4 | traffic thật đi IPv6 (Mục 7.2) |
| 11 | `wait_down()` / `wait_ready()` / `DOWN_HOLD=2` | tự động hoá đúng thao tác tay: tạo **cửa sổ downtime** để client retry thay vì nhận 429 (Mục 5.1) |
| 12 | Bỏ vòng lặp xoay lần hai khi IPv6 trùng | lần fail thứ hai giữa lúc client đang retry tệ hơn rơi lại cùng edge (Mục 5.2) |
| 13 | `IMMEDIATE=1` trong daemon | user xoay **ngay khi thấy 429**, không chờ cổng idle. `IMMEDIATE=0` giữ hành vi cũ |
| 14 | `detect_429_db()` — quét `opencode.db` | 3/3 lần 429 chỉ tồn tại trong DB, vắng mặt trong **mọi** file log; daemon không thể thấy (Mục 7.12) |
| 15 | `COOLDOWN` 90 → 20 | 90s giữ 429 tới 93 giây, phủ định mục đích của `IMMEDIATE=1` (Mục 7.13) |
| 16 | Chuyển khối `case` argv xuống cuối file | `--once` gọi `seed_cursors` trước khi hàm được định nghĩa (Mục 7.14) |
| 17 | `notify_rot()` — báo 3 mốc của vòng đời xoay | im lặng khiến `Rate limit exceeded` treo 1 phút trông như daemon chết (Mục 5.3) |
| 18 | Không ghi lại latch khi `do_rotate` trả 2 | daemon báo "đã dừng" nhưng thực tế vẫn cắt tunnel thêm 1 lần (Mục 7.15) |
| 19 | `COOLDOWN` 20 → **0**, `cooling_down` tự tắt | yêu cầu của người dùng: xoay ngay khi thấy 429, không hold (Mục 5.4) |
| 20 | `done` miễn gap; stamp ghi sau khi gửi thành công | đo được 15:57:40 / 15:58:04: lần sau xoay xong nhưng im lặng vì gap (Mục 5.3) |
| 21 | Xoá nhánh `IMMEDIATE=0` | 697 → 546 dòng. Nhánh chờ-idle **chưa từng chạy** từ 13:09 hôm nay; xoá `flow_snapshot`, `flow_busy`, `idle_ready`, `PROXY_PORT`, `IDLE_HOLD`, `IDLE_SINCE_FILE`, `FLOWS_FILE`, `FLOW_FORCE`, cờ `--flow-test` (Mục 7.16) |
| 22 | Phát hiện OpenCode **đã tự retry** | `⚠ Retry due · attempt 2` — giả định cốt lõi của cả Mục 5.1 là sai; kéo dài lỗi sẽ khiến retry ăn `ECONNREFUSED` (Mục 5.0) |
| 23 | `MAX_STUCK=1` + `stuck_until` (park 120s) | 10% lần xoay trả lại cùng IPv6. Trước: 6 lần 429 → 6 lần gián đoạn. Sau: **1** (Mục 5.5) |
| 24 | `STUCK_PARK` 120s → **10s** + log giá trị lúc khởi động | Park 120s tạo ra đúng triệu chứng nó sinh ra: 6 lần thấy 429 rồi từ chối xoay trong 23s, và 39/70 lần hỏng nhanh là do **không xoay** chứ không phải xoay dở. Thông báo "tôi dừng" bị DND nuốt nên trông như treo (Mục 5.6) |
| 25 | Cài `rotations.tsv` + `resolve_outcomes()` đo kết quả từng lần xoay | Không có cách nào biết lần xoay có chữa được 429 không; `auto.log` trim 2MB chỉ còn 1.5 ngày so với 30 ngày 429 trong DB nên không ghép được nhân quả (Mục 5.7) |
| 26 | Dọn 152 cursor `off.*` rác trong `STATE_DIR` | Cursor cho log đã bị xoá, `scan_new` fallback `off=0` → quét lại toàn bộ 42MB log. **Đã gây 1 lần xoay ngoài ý muốn lúc 09:06:16** (`burst (50 signals in 120s)` toàn bộ là 429 cũ bị đọc lại). Restart daemon ngay sau đó đã seed lại cursor, không tái diễn (Mục 5.7) |
| 27 | Cài `edge_timeline.tsv` + `record_edge()` | **Journal không ghi IPv6** (0 địa chỉ / 136206 dòng WARP), `auto.log` chỉ có IP trong khối xoay → 429 lúc không rotate thì không biết gắv IP nào. Bắt được ngay 1 lần WARP **tự** đổi edge 09:14:43 không có rotate (Mục 5.8) |
| 28 | Cài `warp-report` (chỉ đọc, DB `mode=ro`) | Không có cách nào ghép 429 với IP ngoài tay. Báo 4 phần: tỉ lệ theo ngày, rate limit theo edge, hiệu quả từng lần xoay (Mục 5.8) |
| 29 | Đổi chuẩn đếm 429: `error.type='provider.quota'` | `LIKE '%Rate limit exceeded%'` đếm 657 dòng nhưng chỉ **393** là rate limit thật; 264 dòng còn lại là log bị nhúng vào `user`/`synthetic`/`system` (Mục 5.8) |
| 30 | Thực thi hoá `EDGE_POLL` (thêm `edge_probed`) | Knob được khai báo và in ra log nhưng **không hề được dùng** → probe mỗi vòng inotify, tốn 774ms/lần. Giờ giới hạn 60s; đo trên daemon thật: stamp reset đúng mốc 60s, `NRestarts=0` (Mục 5.8) |
| 31 | `warp-report` thêm phần 5–8: toàn bộ request, lỗi theo model, retry | Compare latency, errors by model, and retry outcomes. Unequal model usage is not a controlled comparison (Mục 5.10). |
| 32 | **Đính chính Mục 5.8** | Bản đầu kết luận “mỗi lần xoay đều sinh lỗi” — sai. Đo lại: 26/98 lỗi transport nằm trong ±30s của một lần xoay (kỳ vọng ngẫu nhiên 7.0, p<0.001) → có quan hệ thật nhưng chỉ **27%**, không phải 100% (Mục 5.8) |
| 33 | `warp-report` thêm phần 9: giải mã chuỗi retry | `retry.at` nằm **sau** `time_created` và kết quả nằm ở dòng kế tiếp. 71% retry hồi phục, **17% kết thúc bằng `provider.quota`** → 46 lần cắt tunnel không đem lại lợi ích. OpenCode **không** retry 429 (0/393) (Mục 5.11) |
| 34 | **Sửa lỗi đếm 429 trong chính `warp-auto`** | `detect_429_db()` và `resolve_outcomes()` vẫn dùng `data LIKE '%Rate limit exceeded%'` sau khi đã chứng minh cách đó thừa (96 vs 79 trong 24h). Nghiêm trọng hơn: cursor `max(time_created)` **tiến theo dòng không phải rate limit**, nên một 429 thật sau đó có thể rơi sau cursor và không bao giờ được đếm. Đã đổi cả hai sang `json_extract(data,'\$.error.type')='provider.quota'` (Mục 5.8) |
| 35 | Điều tra `The request contains invalid parameters` + thêm Mục 10 cho `warp-report` | Distinguish HTTP 400 from transport resets. Repeated invalid payload errors can be session-specific; a generic error does not identify a context limit (Mục 5.13). |
| 36 | Thêm plugin tự Continue sau quota Zen | Historical experiment: a new Continue turn was not a retry. The plugin was removed because it could send a prompt for the user (Mục 5.14). |
| 37 | Speedup pass: poll 2s→1s, drain 30s→10s, retry-fallback 5s→3s, edge-probe timeout 8s→5s | Mỗi thay đổi có số liệu ledger (Mục 5.15). Không đụng DOWN_HOLD=2 (floor của user), parks, dedupe windows, hay cap |

---

## 7. Sai lầm — đọc mục này trước

Mỗi mục: chuyện gì đã xảy ra, vì sao sai, và bài học.

### 7.1. Kết luận quá từ dữ liệu không đủ

**Đã xảy ra ít nhất 2 lần**, và nguy hiểm vì cả hai lần đều dẫn tới khuyến
nghị *tắt daemon* — tức là khuyến nghị phá huỷ thứ đang hoạt động đúng.

Lần 1: dựa trên "IPv4 kẹt ở `.201` 3 lần liên tiếp" kết luận xoay vô ích.
Sai vì tiêu chí sai (Mục 7.2).

Lần 2: sau khi sửa đúng, vẫn kết luận xoay vô ích dựa trên test 9/9 lỗi —
mà test đó **không đo đúng đối tượng** (Mục 7.5).

**Bài học:** khi chuẩn bị nói "X không dùng được", hỏi xem cái đo đã đo đúng
thứ chưa, và đo lại bao nhiêu lần. Nếu chưa đủ, nói "chưa chứng minh được",
đừng nói "sai".

### 7.2. Đo sai tiêu chí: IPv4 trong khi traffic đi IPv6

Đo được:

```
curl -4 → 2a09:bac5:d446:16dc::247:9
curl -6 → 2a09:bac5:d446:16dc::247:9   ← giống hệt
```

Proxy ưu tiên IPv6 bất kể client yêu cầu gì. IPv4 `104.28.x` tồn tại trên
interface nhưng **không mang lưu lượng**.

Cả hai `warp-rotate` (bản đầu) và logic `stuck_ip4` (viết lúc 21:02) đều quyết
định dựa trên IPv4. Hậu quả cụ thể, lúc **22:09:57**:

```
after IPv6: 2a09:bac1:7aa0:48::17:36e   ← ĐÃ ĐỔI edge
after IPv4: 104.28.219.201              ← không đổi
→ rotate skipped from here: IPv4 stuck   ← BỎ QUA một lần xoay hữu ích
```

Phòng thủ bằng cách thêm một điều kiện sai lại **chặn đúng** những lần xoay
có tác dụng.

**Bài học:** trước khi dùng một chỉ số làm tiêu chí thành công, xác minh chỉ số
đó **thực sự tham gia** vào đường đi quan trọng. Và: một điều kiện chặn
"phòng thủ" phải có bằng chứng rằng thứ nó chặn thực sự vô ích.

### 7.3. Daemon mắt đúng, nhìn sai chỗ

Trong gần 4 tiếng, daemon `active`, vòng lặp sống, cursor bám đúng size file,
inotify quay vòng bình thường — và **không bắt được một lần 429 nào**. Vì:

- Lỗi 429 của session chính viết vào `opencode.log`.
- Lỗi của **subagent** đi đường plugin, vào `oh-my-opencode-slim.<timestamp>.log`.
- Từ 2026-10-03, provider error **không còn** ghi vào `opencode.log`.

Sửa: watch thư mục + quét `opencode.log` + 3 log plugin mới nhất, mỗi file một
cursor.

**Bài học:** hai nguyên nhân khác nhau trùng tên trong log — "hệ thống im lặng
vì không có việc" và "hệ thống im lặng vì nhìn sai chỗ" — trông **giống hệt
nhau** từ ngoài. Phải kiểm chứng cursor có tiến không, chứ không đoán.

Không watch một file plugin cụ thể: tên file có timestamp, mỗi lần khởi động app
là sinh file mới. Ghim vào file hôm nay thì ngày mai điếc.

### 7.4. "Socket im lặng" bị nhầm là "người dùng rảnh"

Chuỗi gây lỗi, lấy nguyên từ log:

```
20:54:08  busy: new connection          ← user bấm Continue
20:54:09  data moving  446635 → 2445474
20:54:10  data moving  2445474 → 2986049
20:54:10  data moving  2986049 → 2986849  (+800 byte)
20:54:11  idle (1 quiet flow)  →  ROTATE  ← giết đúng request đang bay
```

`flow_busy` coi là idle khi **byte không đổi giữa hai lần đo**. Nhưng khi
OpenCode đã gửi xong request và đang chờ model trả lời, socket đứng yên 1–3
giây — không phải vì user rảnh tay.

Hậu quả: `⚠ Retrying in 1s · attempt 3 · ConnectionRefused`. Bấm Continue càng
nhanh thì request mới càng dễ bị giữa chừng.

Sửa: `IDLE_HOLD=20` — phải có **20 giây im lặng liên tục** mới xoay, và áp cả
cho nhánh burst.

**Bài học:** "không có hoạt động quan sát được" ≠ "đối tượng không hoạt động".
Giữa hai thứ đó có khoảng trống, và request đang bay nằm đúng trong khoảng
trống.

### 7.5. Cái bẫy lớn nhất: tin vào một test hỏng

Hai test, cùng một kết luận sai, **cùng sai vì lý do khác nhau**.

**Test A — "9/9 lỗi dù edge đã đổi 3 lần":**
Bắn **3 request liên tiếp không nghỉ** ở mỗi edge. Request đầu đã 429 thì hai
request sau bắn ngay lập tức sẽ fail dù edge có tốt hay không — và xoay liên
tục giữa các đợt giữ người test trong cửa sổ phạt.

**Test B — "`UnexpectedStatus` mỗi lần":**
Trong khi test này chạy, **session thật của user vẫn chạy tốt**, cùng model,
cùng proxy, cùng thời điểm. Một cái chạy, một cái lỗi. Vậy `UnexpectedStatus`
của test là **loại lỗi khác** (nhiều khả năng 403 `free tier can only be used
from within OpenCode`, vốn đã biết là không liên quan IP), không phải 429.

Cả hai test đều cho ra con số rất đẹp và **không có giá trị bằng chứng nào**.

**Bài học:**
- Test phải tái hiện **đúng** hiện tượng. Test một thứ khác rồi quy kết cho thứ
  này là tự tạo bằng chứng giả.
- Luôn kiểm tra **đối chứng**: trong lúc test, session thật của user có đang
  hoạt động bình thường không? Nếu có, test của bạn đang đo sai thứ.
- Trước khi kết luận tiêu cực (cái gì đó "vô ích"), hãy hỏi: nếu nó thật sự vô
  ích, tại sao hành vi quan sát được lại ngược lại?

### 7.6. Sửa nhầm chỗ, và test vừa sửa vừa chạy

Logic idle thật nằm trong `handle_signal`, không phải `check_once`. Sửa
`check_once` → test vẫn xoay ở 3 giây idle → tưởng sửa không ăn. Phải tách
thành hàm `idle_ready()` dùng chung cho cả hai nhánh.

Cũng trong lúc đó: `--once` **không seed cursor**, nên test quét lại toàn bộ
lịch sử và xoay bừa. Test thất bại vì test, không phải vì script.

**Bài học:** sửa nhầm chỗ sẽ tạo ra vòng lặp "sửa → test fail → sửa tiếp
chỗ khác" rất tốn thời gian. Đọc lại cấu trúc hàm trước khi sửa.

### 7.7. Chế độ test bị gọi sai và tưởng script hỏng

`--detect-test` in `NO-MATCH` → tưởng đường offset hỏng. Thực ra
`--detect-test` chỉ test **pattern trên đối số truyền vào**; tôi gọi không có đối
số nên `NO-MATCH` là câu trả lời đúng.

**Bài học:** phân biệt "kết quả thử nghiệm sai" với "chương trình hỏng" trước
khi sửa code. Đã phải đính chính công khai vì điều này.

### 7.8. Cảnh báo trong code phải *thành công*

Test harness set `ACTIVE_PLUGIN_LOGS` rỗng → `head -n ""` lỗi → **im lặng**.
Nếu không nhìn kỹ thì tưởng daemon hỏng.

Sửa: `scan_new` **ghi log cảnh báo và báo lỗi** khi không tìm thấy file nào,
thay vì im lặng rồi báo "không có gì".

**Bài học:** đường lỗi im lặng là loại bug tệ nhất vì nó trông giống hành vi
đúng. Mọi nhánh "không tìm thấy gì" phải phân biệt được với nhánh "không có
gì mới".

### 7.9. Sửa file script khi tiến trình đang chạy

Bash đọc script dần theo file offset. Sửa `warp-auto` khi daemon đang chạy có
thể làm nó chạy rác giữa chừng.

Mọi lần sửa đều phải kèm `systemctl --user restart warp-auto.service`. Restart
này **không** đụng tunnel WARP — đã xác minh IP không đổi sau restart, proxy vẫn
LISTEN.

**Bài học:** với script dài chạy dưới systemd, sửa file ≠ nạp code mới. Luôn
restart sau khi sửa, và nói rõ restart này an toàn thế nào.

### 7.10. Đo thì phải đo kiểu rẻ

Ghi vào `AGENTS.md` từ sớm, và vẫn còn hiệu lực:

```bash
STATE_DIR=/tmp/wt-$$  WARP_ROTATE=/bin/true  FLOW_FORCE=idle|busy  LOG_DIR=/tmp/fake-log
```

Không cần ngắt tunnel thật để test logic daemon. Riêng bài test *end-to-end có
xoay thật* thì phải chờ lúc idle, vì ghi một 429 giả vào log thật sẽ kích hoạt
xoay thật và cắt các luồng đang mở của user.

### 7.11. Đừng ghi dòng giả vào log thật

Đã từng append dòng `run=tA|tB|e2etest|...` vào `opencode.log` để test, phải
dọn lại sau (backup ở `/tmp/opencode.log.bak*`) và chỉnh lại `log.offset`. Và 50 dòng
`Rate limit exceeded` còn lại trong log là của chính user, không phải test.

**Bài học:** dùng `LOG_FILE=` trỏ file riêng. Nếu đã lỡ ghi vào log thật, nói
rõ với user trước khi xoá.

### 7.12. Nguồn tín hiệu thiếu — daemon mù với 429 nằm trong DB

Đo 2026-10-04: đối chiếu `session_message` với mọi file log. Ba lần 429
(12:46:58, 13:29:33, 13:34:59) tồn tại trong DB và **hoàn toàn vắng mặt** trong
`opencode.log` lẫn plugin log. Daemon chỉ quét file log nên **về nguyên tắc không
thể thấy** chúng — đúng triệu chứng người dùng báo "đang nhận lỗi mà nó không
xoay".

Nay `detect_429_db()` quét `opencode.db` bằng cursor `time_created` (**mili
giây** — cột này không phải giây) và `check_once` cộng hai nguồn.

**Bài học:** "đã grep log rồi, không thấy" ≠ "không xảy ra". Kiểm tra **cả ba**
nguồn (opencode.log, plugin log, DB) trước khi kết luận daemon bỏ sót.

### 7.13. `COOLDOWN=90` phủ định đúng mục đích của `IMMEDIATE=1`

Log 13:30:14 → 13:31:47:

```
13:30:14  saw 1 rate-limit line(s) but cooling down — latched
13:31:47  latched rate limit, cooldown expired — rotating immediately
```

Người dùng bị 429 rồi phải chờ **93 giây**. `IMMEDIATE=1` sinh ra nhằm xử lý
ngay, nhưng cooldown 90s giữ nó lại. Hai thiết lập này **tranh nhau**.

Hệ quả nữa: giảm xuống 20s **vẫn chưa đủ**. Đo lại 15:07:58 → 15:10:03, 429 vẫn
nằm 2 phút vì 4 tín hiệu liên tiếp đều rơi vào cooldown rồi ghim latch. Rút
dần về 0 không phải giải pháp, nó chỉ chậm lại triệu chứng. Nay **`COOLDOWN=0`**
— xoá hẳn cổng chặn (Mục 5.4).

**Bài học:** thêm một cổng chặn mà không nghĩ nó tương tác với cổng cũ sẽ vô
hiệu hoá tính năng vừa thêm. Và khi một cổng đã chứng minh hại nhiều hơn lợi,
đừng chỉ giảm nó — hãy hỏi xem có cần nó không.

### 7.14. Dispatch block gọi hàm định nghĩa ở dòng sau

Khi thêm `seed_cursors` vào nhánh `--once`, hàm nằm **dưới** khối `case`. Bash
chạy trên xuống nên nhánh đó gọi hàm **chưa tồn tại** → `command not found`, và
vòng đầu quét lại toàn bộ lịch sử 429 nên xoay ngay. Phát hiện được nhờ test T1
( DB chỉ chứa 429 cũ, state dir mới, kỳ vọng 0 lần xoay — thực tế 1).

**Bài học:** khối `case` argv phải nằm **sau** mọi định nghĩa hàm. Test với một
kịch bản "không có gì mới xảy ra" mới bắt được lỗi loại này — chỉ test "có 429
mới" thì vẫn xoay đúng và che mất bug.

### 7.15. Không phân biệt rc 1 và rc 2 của `do_rotate` → "đã dừng" nhưng vẫn xoay

`do_rotate` trả **2** khi chủ động bỏ cuộc (IPv6 kẹt quá `MAX_STUCK`) và đã
`rm -f "$PENDING_FILE"`. Nhưng mọi caller viết:

```bash
do_rotate "..." && return 0
date +%s > "$PENDING_FILE"    # ghi LẠI latch vừa được xoá
return 2
```

Nên sau mỗi lần "dừng", vòng kế tiếp thấy latch và xoay tiếp — **đo được 1 lần
cắt tunnel thừa**. Tệ hơn: notification mới sẽ bảo "đã dừng xoay" trong khi
daemon vẫn đang xoay.

Đã sửa bằng cách phân biệt rc:

```bash
do_rotate "..."; rc=$?
[ "$rc" -eq 0 ] && return 0
[ "$rc" -eq 2 ] && return 2    # tự dừng: latch đã xoá, không ghi lại
date +%s > "$PENDING_FILE"
return 2                      # rc 1 = thất bại: cần giữ latch để retry
```

Test bắt được: `MAX_STUCK=1`, **một** lần 429 mới, gọi `--once` liên tiếp 4 vòng →
trước khi sửa rotator được gọi **2** lần, sau khi sửa **1** lần. Kịch bản
"chỉ có một 429 rồi im lặng" mới chứng minh được — test "cứ xoay thì 429" không
phân biệt được.

### 7.16. Xoá code chết: đo trước, xoá sau

Dọn codebase 2026-10-04, 697 → 546 dòng. Nhánh `IMMEDIATE=0` (chờ-idle) bị xoá
vì **đo** cho thấy nó chết, không phải vì "thấy không dùng":

```
$ grep -c "waiting for idle\|holding off\|idle held" auto.log
335                       # tổng số lần trong toàn bộ lịch sử
$ grep "waiting for idle" auto.log | tail -1
2026-10-04 13:02:55 ...   # lần CUỐI
```

Lần cuối 13:02:55. `IMMEDIATE=1` bật lúc 13:09. Tức là **335 lần chạy, 0 lần
sau khi tính năng bị bỏ** — nhánh đó chỉ còn là đường lùi không ai dùng. Xoá
theo lựa chọn của người dùng (xoá hẳn, không giữ đường lùi).

Xoá được: `flow_snapshot`, `flow_busy`, `idle_ready`, `PROXY_PORT`, `IDLE_HOLD`,
`IDLE_SINCE_FILE`, `FLOWS_FILE`, `FLOW_FORCE`, cờ `--flow-test`.

Còn lại sau khi dọn: 22 hàm, tất cả đều có call site (đếm bằng `grep`).

**Bài học:** "tôi không dùng tới" là tin đoán. "Nhánh cuối cùng nó chạy lúc
13:02:55 và từ đó tới giờ 0 lần" là bằng chứng. Xoá code dựa trên cái thứ hai.

### 7.17. Refactor phải giữ semantics, và phải test lại đúng chỗ vừa đổi

Gộp hai nhánh trùng lặt ở đầu `check_once` (cùng biểu thức
`detect_429_new + detect_429_db`, chỉ khác điều kiện thoát) thành một:

```bash
sig=$(( $(detect_429_new) + $(detect_429_db) ))
if [ "${sig:-0}" -gt 0 ]; then handle_signal "$sig"; return $?; fi
[ -f "$PENDING_FILE" ] || return 1
```

Nguy hiểm: latch là đường duy nhất giữ một 429 đã ghim. Nếu gộp sai, mọi latch
sẽ chết âm thầm và không có test nào bắt được — vì test "có 429 mới" không đụng
tới nhánh latch. Phải có test riêng:

```
L1 vòng đầu, không gì            -> rc=1 (không có gì)  ✓
L2 có latch, KHÔNG có 429 mới   -> rc=0, xoay=1, latch đã xoá  ✓
```

Chạy lại sau mỗi lần refactor: T1–T4 (DB), C1 (không hold), P1/F1–F2
(notify), S1–S2 (IPv6 kẹt), L1–L2 (latch). Không test nào được bỏ vì "không liên
quan".

---

## 8. Trạng thái nghi ngờ về 429 (chưa giải quyết)

Dữ liệu hai hướng, **chưa chốt**:

**Hướng "xoay vô ích":**
- 429 vẫn xảy ra y hệt ở 20:18 và 20:23 khi IPv4 không đổi một chữ nào.
- Tỷ lệ 429 đi từ 2.4% (trước daemon) lên 3.4–3.8% (sau).
- Khoảng cách giữa các lần 429 rút ngắn: 37 → 93 → 13 → 58 → 11 → 8 → 6 phút.
- User bấm **continue** là xong, đi qua cùng IP, cùng tunnel.

**Hướng "xoay có ích":**
- IPv6 **đổi mọi lần** đo được → mỗi lần xoay là một Cloudflare edge node khác.
- Success after an edge change does not by itself prove that the change
  cleared the quota.
- Concurrent 429 errors across sessions can indicate a shared quota, but
  do not identify its key.

**Possible mechanism:** Parallel subagents can increase request load and reach
a shared quota. A later attempt with less parallel work can succeed without
proving that a rotate helped. Private agent usage counts are omitted.

Giả thuyết đang mở: **Cloudflare WARP dùng chung địa chỉ IPv6 với nhiều người
dùng.** Xoay sang node khác không có nghĩa node đó trống.

### 8.2. Bằng chứng 17:02 nghiêng mạnh về “xoay không chữa được 429”

Chuỗi do chính người dùng bắt được (Mục 5.0):

```
17:02:17  429 (sau khi client tự retry)
17:02:18  rotate → IPv6 ĐÃ ĐỔI thành công
17:02:28  429 lần nữa, chỉ 3 giây sau khi xoay xong
```

IPv6 đã đổi thật và 429 vẫn quay lại trong 3 giây. Cùng với việc client **tự
retry** và vẫn ăn 429, điều này gợi ý 429 **không (hoặc không chỉ) gắn với IP
thoát** — nhiều khả năng là quota theo tài khoản / API key của plan free, cộng
dồn khi subagent chạy song song (Mục 8).

**Chưa chứng minh.** Cần phép thử phân biệt: cùng key `opencode/zen`, so sánh
một request qua WARP với một request đi thẳng IPv4 nhà. Nếu cả hai đều 429 →
xoay WARP vô dụng.

A direct comparison needs equivalent provider access. Without that access,
the comparison is not valid. Do not inspect or publish private credentials.

**Đừng hứa user rằng xoay chữa được 429.** Nói “đang thử cải thiện tốc độ phản
hồi” thành thật hơn.

### Cách kiểm chứng

Phép thử quyết định, chưa làm vì cần user quyết định:

**Tắt daemon 1 ngày** (`systemctl --user disable --now warp-auto.service`) và
chỉ bấm continue thủ công. Nếu số lần 429 không tăng → xoay không mang lại giá
trị gì và nên bỏ.

Nếu giữ daemon: lần tới gặp 429, **đừng bấm tay**, để nó tự xử lý, rồi đo bao
lâu sau `rotate done` thì điềm lại. Vài phút là hết → xoay có ích. Vẫn lặp →
không ích.

### 8.1. Bằng chứng 2026-10-04 buổi chiều (sau khi bật `IMMEDIATE=1`)

The historical experiment used `IMMEDIATE=1` to rotate while connections were
active. Later requests succeeded, but quota errors also returned after an
earlier rotate. This did not isolate the effect of `IMMEDIATE`, prove that
rotation clears quota, or prove that an active request is safe during a cut.
Keep the safety rule: a manual reconnect needs explicit permission. Private
prompt text, session timelines, and message counts are omitted.

---

## 9. Việc tồn đọng

- `need_rotate` từng biến mất mà không có rotate thành công nào (`last_rotate`
  vẫn là 13:07) — nghi ngờ mất trạng thái khi daemon restart. Chưa truy ra.
- Daemon restart 3 lần trong 13:50–14:00 với `NRestarts=0` → ai đó gọi
  `systemctl restart` tay, không phải crash. Không rõ là ai.
- Hai cursor cũ `log.offset` / `log.offset.403` đã thành rác.
- **Cursor rác tích luỹ**: hiện có **30** file `off.*` (15 cặp `.429`/`.403`)
  vì mỗi lần khởi động OpenCode sinh một log plugin mới có timestamp, và cursor
  cũ không bị dọn. Chạy lâu sẽ phình vô hạn trong `STATE_DIR`. Xoá `off.*` của
  log không còn tồn tại là an toàn — khi daemon khởi động lại nó sẽ seed lại.
- Expired MCP OAuth credentials need a separate login with
  `opencode mcp auth login cloudflare`; they are not a WARP quota error.

---

## 10. Danh sách kiểm trước khi đụng vào việc này

1. Đọc mục này trước. Đặc biệt Mục 7.
2. **Không** chạy `warp-cli disconnect/connect` khi user đang dùng OpenCode.
   Kiểm tra `ss -tn state established | grep -c ':40000'` — nếu > 0 thì dừng và hỏi.
3. Khi sửa `warp-auto` hoặc `warp-rotate`, luôn `bash -n` trước.
4. Khi sửa `warp-auto`, luôn `systemctl --user restart warp-auto.service` (không
   đụng tunnel, nhưng cần để nạp code).
5. Test bằng `STATE_DIR=/tmp/...` + `WARP_ROTATE=/bin/true` + `LOG_DIR=/tmp/...`.
6. Không append vào log thật.
7. Đừng kết luận từ một lần đo, và **kiểm tra đối chứng** (xem Mục 7.5).
8. Muốn nói "cái này vô ích" → đo lại bằng tiêu chí đúng, ít nhất 3 lần, có
   đối chứng.

---

## 11. Phụ lục: đường đi mạng và tốc độ (đo 2026-10-04)

### 11.1. Endpoint thật của model

| Model | baseURL |
|---|---|
| `opencode/muse-spark-1.3-contributor-free` | `https://opencode.ai/zen/v1` |
| `bai/*` | `https://api.b.ai/v1` |

Tìm ra từ `https://models.opencode.ai/api.json` (registry chính thức), mục
`/opencode`. **Đừng đo nhầm `api.b.ai`** — đó là provider `bai`, không phải
provider bạn đang dùng. Phân biệt:

- Provider `bai` cần key trong `opencode.json` (`{env:BAI_API_KEY}`).
- Provider `opencode` là provider nội bộ, **không** có entry trong `auth.json`
  (file này chỉ chứa `bai`).

### 11.2. Số đo direct vs WARP proxy

| Chỉ số | Direct | Qua proxy :40000 | Kết luận |
|---|---|---|---|
| Băng thông (speed.cloudflare.com 20MB) | 8,0 MB/s | **28,0 MB/s** | proxy **nhanh hơn 3,5x** |
| TLS handshake tới zen (TBF) | 0,732–0,860s | **0,565–0,667s** | proxy **NHANH hơn** |
| TTFB tới `api.b.ai` | 0,121s | 0,188s | +67ms |
| HTTP version | 2 | 2 | giữ nguyên HTTP/2 |
| WARP edge | — | Colo **HKG**, 27ms, loss **0.00%** | đường lành |
| CPU của `warp-svc` | — | 1,1% | không nghẽn CPU |

### 11.3. Proxy KHÔNG bộ đệm dữ liệu streaming

Phép thử drip (httpbin, nhả 1 byte mỗi 301ms):

| | median gap | max gap |
|---|---|---|
| direct | 301ms | 534 / 526ms |
| proxy | **301ms** | 612 / 589ms |

40 byte truyền đủ, median gap **giống hệt**. Proxy trong suốt; chỉ hơi rung ở đuôi
(max gap +60~80ms). Giả thuyết “proxy gom chunk rồi nhả” bị bác bỏ.

### 11.4. Chưa đo được: nhịp token thật

Cần gọi `opencode.ai/zen/v1/chat/completions` với `muse-spark-1.3-contributor-free`.
Không làm được:

- Không có `OPENCODE_API_KEY` ở bất cứ đâu trên máy.
- Không có key → `curl` trả **500 Internal server error**.
- Dùng key `bai` thay → **model không tồn tại** trên provider đó.

Nên **chưa có bằng chứng trực tiếp** cho tuyên bố “WARP làm tốc độ token giảm
 một nửa”. Mọi số đo hiện có đều nghiêng về hướng ngược lại: WARP nhanh hơn ở
băng thông và TTFB, và không thay đổi nhịp stream.

### 11.5. Sai lầm của lần đo này

Ban đầu tôi đo toàn bộ trên `api.b.ai` — sai endpoint — rồi đi tìm key `bai`,
gặp 403 “Deposit required”, rồi kết luận “không test được”. Suốt vậy là đo
**nhầm đối tượng**. Đáng ra phải tra registry `models.opencode.ai/api.json` ngay
từ đầu để xác định model của bạn thuộc provider nào, thay vì đoán từ `baseURL`
đầu tiên thấy trong config.

Bài học chung với Mục 7.5: **trước khi đo, xác định chính xác cái cần đo nằm ở
đâu.** Config có nhiều provider; đo nhầm cái thứ nhất tìm thấy sẽ ra kết luận
trông rất thuyết phục và hoàn toàn vô giá trị. Đừng làm thế nữa.

### 11.6. Công cụ đo (trong /tmp, không nằm trong repo)

- `/tmp/tokspeed.py` — đo chunk/s từ SSE, direct vs proxy
- `/tmp/stream-cadence.sh` — đo median/p90 gap của stream
- `/tmp/drip.py` — kiểm tra proxy có bộ đệm không

Lưu ý: máy **không có** `bc`, `traceroute`, `xclip`. Dùng `awk` thay `bc`.

## 12. Theo dõi

```bash
tail -f ~/.local/share/warp-rotate/auto.log     # nhật ký daemon
systemctl --user status warp-auto.service       # trạng thái
ss -tn state established | grep -c ':40000'      # user đang bận không
```

Kiểm tra xem **429 thật** vừa xảy ra chưa (nhanh nhất, không cần log file):

```bash
DB=~/.local/share/opencode/opencode.db
sqlite3 "$DB" "SELECT datetime(time_created/1000,'unixepoch','+7 hours'), session_id \
  FROM session_message WHERE data LIKE '%Rate limit exceeded%' \
  ORDER BY time_created DESC LIMIT 5;"
```

Có `Rate limit exceeded` trong `opencode.log` **không** đủ: tỷ lệ lớn các 429
nằm **chỉ trong DB** (`type=synthetic`, `state:"error"`, hoặc message `assistant`
có `error`), không xuất hiện ở bất kỳ file log nào. Vì vậy `detect_429_new`
quét file log sẽ **bỏ sót** nhiều 429 — đừng kết luận "không có 429" khi log
sạch.

`warp-auto` không hiện trên tray icon Cloudflare One — nó gọi `warp-cli` ở mức
CLI nên bạn sẽ **không thấy** icon nhấp nháy. Muốn biết nó có chạy không thì
phải đọc log.

## 13. Current policy and community findings (2026-10-07)

The current implementation has a narrower trigger than the earlier history in
this file:

- Only a 429 for `opencode/muse-spark-1.3-contributor-free` can trigger a
  rotation. Generic OpenCode and subagent log text is diagnostic only.
- The dedicated Zen hook is the primary signal. The database is a fallback for
  the same provider and model. A database row that follows a recent hook signal
  is treated as the same event for 45 seconds. Each fresh hook signal requests
  a reset, including after a same-edge result. Concurrent hook events share an
  active reset because all requests use the same WARP tunnel.
- After a confirmed reset, OpenCode waits 10 seconds before retrying. A later
  429 requests another reset. If reset does not become ready, retry also waits
  10 seconds.
  `Retry-After` takes precedence, capped at 10 seconds.
- The retry hook continues to retry if the WARP service is stopped or a reset
  fails. It does not require the local proxy to be on. The model request uses
  the system route when port `40000` is unavailable.

Repeated rotations can leave a quota error unchanged. An IPv6 change alone
is not proof of recovery. This does not prove that WARP rotation never helps.

Public reports are mixed. Some OpenCode Zen users say a new IP restored access;
others report that the free limit stayed active after an IP change. These are
user reports, not official quota rules. Community WARP rotator projects also
claim to clear 429s, but their readmes do not provide controlled evidence or a
guarantee that Cloudflare will assign a new address each time.

Cloudflare documents three relevant routing facts:

- Traffic and DNS UDP, TLS, and HTTPS all tunnel device traffic through WARP.
  They change DNS transport. They do not provide a supported way to select a
  Cloudflare data center or a new country.
- Local proxy mode only carries traffic sent to its configured localhost
  proxy. Cloudflare documents a 10-second request timeout for this mode. This
  may affect a long wait before the model starts streaming. It is not evidence
  that every long streaming response will fail.
- WARP+ offers a larger network and can improve route choice, but Cloudflare
  does not say that it clears a provider's rate limit.

Sources:

- [Cloudflare WARP modes](https://developers.cloudflare.com/warp-client/warp-modes/)
- [Cloudflare One client modes and local proxy timeout](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/modes/)
- [OpenCode Zen users report mixed results after changing IP](https://www.reddit.com/r/opencode/comments/1vm9bhh/free_limit_ends_too_fast_now/)
- [Community WARP and Zen rotator project](https://github.com/alztrk/opencode-ip-rotator)

The daemon was restarted at 14:38 local time on 2026-10-07 to load the new
filters. This restart did not disconnect WARP. The plugin change takes effect
when OpenCode2 starts a new process; do not restart a process that is handling
active work.

---

## 14. Verdict A/B tối 2026-10-07: proxy nghỉ hưu, tunnel là steady-state

**Kết luận đóng hồ sơ Mục 8 / 8.2.** Phép thử phân biệt từng treo ở Mục 8.2
("cùng key so một request qua WARP với một request đi thẳng") nay đã có đáp án
dưới dạng A/B theo mode, đo nhiều lần trong tối 07/10, không còn là ước lượng
n=17 như Mục 5.7:

| Mode | Số lần xoay | Kết quả |
|---|---|---|
| Proxy mode (WarpProxy `:40000`) | **8 lần xoay liên tiếp** | **vẫn 429** — không dứt |
| Full-tunnel mode | **≤2 lần** | **hết 429** |

Giải thích: pool egress của proxy **bẩn** (nhiều người dùng chung, quota đã cạn
trên gần như mọi edge của pool đó), và limiter key theo **route-identity** chứ
không theo suffix IP / IPv4 / key thuần. Bằng chứng: đổi suffix IPv6 hay IPv4
trong proxy mode đều không thoát; chỉ khi đổi cả route (full-tunnel) thì 2 lần
là xong. Đây cũng là lần đầu giả thuyết Mục 8 ("WARP dùng chung địa chỉ IPv6")
được đo tới nơi tới chốn — đúng cho proxy pool, sai cho tunnel.

**Quyết định:** proxy **nghỉ hưu cho Zen**. Steady-state từ giờ = full-tunnel.
Daemon và plugin giữ code path proxy chỉ để tương thích / đo tiếp, không còn là
đường chính.

**Real 429 cuối: 18:12:06, sau đó 0.** Sau mốc này mọi "429" còn lại đều là
**false positive của query `LIKE '%Rate limit exceeded%'` dính reasoning text**
(trường `reasoning`/`text` nhắc lại chuỗi lỗi cũ, không phải `error.type` mới).
Bài học lặp lại Mục 5.8 Timeline #34: **đừng `LIKE` thô** — lọc
`json_extract(data,'$.error.type')='provider.quota'` như `detect_429_db()` đang
làm. Ai query tay trong Mục 12 mà quên điều này sẽ tưởng 429 còn tiếp diễn.

### 14.1. Policy daemon mode-aware hiện tại (refactor fix-9)

Daemon nay biết mình đang ở mode nào và cư xử khác nhau. `mode=` có mặt trong
**mọi dòng quyết định** (rotate / park / dedupe / backoff) để đọc log không cần
đoán:

| | Tunnel mode | Proxy mode |
|---|---|---|
| Dedupe | **25s** (xoay nhanh, vì đã chứng minh ≤2 lần hết) | **90s** (chậm, vì xoay thêm cũng vô ích) |
| Quota-text trong log (`Rate limit exceeded` không kèm `error.type`) | coi như **throttle → được xoay** | **backoff**, không xoay ngay |
| Park khi edge kẹt (`MAX_STUCK`) | tối đa **90s** | **600s** (park dài vì pool bẩn, xoay lại cũng gặp edge bẩn khác) |
| Burst-gate | chung cả hai mode: **429 lẻ → backoff; xoay khi lặp trong 120s / burst ≥ 3** | như tunnel |
| 403 `free tier can only be used from within OpenCode` | **log-only, không xoay** (giữ nguyên tắc Mục 5.8 / AGENTS.md) | như tunnel |

Predicate thống nhất sau refactor fix-9: `eff_quota_rotates` (quota có được
xoay không) và `eff_single_guard` (429 lẻ có bị chặn không). Trước fix-9 hai
mode dùng hai nhánh `if` rời, dễ lệch semantics kiểu Mục 7.17 — nay một chỗ,
test lại T1–T4 / S1–S2 / L1–L2 sau mỗi lần đổi như cũ.

### 14.2. Plugin endpoint-wide `zen/v1/*` (thay gate model cứng)

`zen-quota-retry.js` không còn gate theo model (`muse-spark-1.3-...` cứng như
Mục 3 / Mục 13). **Toàn bộ `opencode.ai/zen/v1/*` đi qua WARP**, mọi model —
vì limiter đã chứng minh là theo route, không theo model (Mục 5.10 đúng ở chỗ
"393/393 dồn vào một model" nhưng kết luận "đổi model" đã bị bác ở Mục 5.12;
giờ gate theo endpoint mới là đúng tầng).

- **Passthrough 4 gate 403:** UA / session / tools / stream. Request nào dính
  một trong 4 gate này đi direct, không qua WARP — vì 403 là lỗi Cloudflare
  phía server (AGENTS.md: xoay IP vô ích), ép qua proxy chỉ thêm `transport`
  lỗi.
- **Mode-aware:** proxy sống → **strict-fail-closed** (lỗi là báo, không lén đi
  direct làm rò route-identity); proxy chết (`ECONNREFUSED` listener `:40000`)
  → **tunnel-passthrough nhanh** (đi system route, không chờ).
- **Log `route + status` cả hai nhánh:** nhánh success (line ~219) và 6 đường
  throw `TRANSPORT_ERROR:<code>`. Chỉ ghi route / sequence / status — không ghi
  prompt / header / token (giữ nguyên tắc Mục 3). Dùng log này để đối chiếu với
  `rotations.tsv` thay vì đoán như Mục 5.7.

### 14.3. Bảng route rút gọn + dọn folder

| # | Traffic | Đi đường nào | Vì sao |
|---|---|---|---|
| 1 | `opencode.ai/zen/v1/*` (mọi model) | **WARP** (tunnel; proxy chỉ khi đo) | limiter theo route-identity, verdict Mục 14 |
| 2 | `bai/*` (`api.b.ai`) | direct, **cấm proxy** | provider khác, key riêng (Mục 11.1) |
| 3 | LAN (`192.168.*`, `10.*`) | direct | local, qua proxy chỉ thêm vòng |
| 4 | localhost / loopback | direct | probe `wait_down`/`wait_ready` phải đo trực tiếp |
| 5 | MCP servers | direct | token OAuth riêng, 401/403 không liên quan WARP |
| 6 | `fetch` tool của OpenCode | direct | tool đi thẳng, giữ như launcher cũ |
| 7 | Speedtest / httpbin / drip probe | direct khi đo baseline | đối chứng direct-vs-proxy (Mục 11.2–11.3) |
| 8 | Còn lại | direct mặc định | fail-closed chỉ áp cho Zen, không áp toàn tiến trình |

Dọn folder (đã xong 07/10 17:15): source thật nằm trong
`~/Documents/zen-unlimited/` — đúng **8 file**
(`warp-auto`, `warp-rotate`, `warp-report`, `WARP-AUTO.md`,
`opencode-warp`, `opencode-warp-on`, `opencode-warp-off`, `opencode2-warp`).
`~/.local/bin/warp-*` và `~/WARP-AUTO.md` chỉ là **symlink** về đó
(vẫn đọc / chạy như cũ). Plugin (`~/.config/opencode/plugins/zen-quota-retry.js`),
state (`~/.local/share/warp-rotate/`), service-unit (`warp-auto.service`) giữ
path chuẩn — không di dời, để daemon / inotify / cursor không gãy.

### 14.4. Caveat còn mở (chưa phải kết luận)

1. **Proxy serialize request.** WarpProxy `:40000` xử lý nối tiếp — một request
   Zen kẹt là **pause toàn bộ opencode** (mọi session đứng theo). Tunnel không
   bị. Đây là lý do phụ nữa để nghỉ hưu proxy, ngoài verdict A/B.
2. **WARP tự đổi edge ~5 phút** (Mục 5.9) vẫn đúng trong cả hai mode. Timeline
   `edge_timeline.tsv` tiếp tục là nguồn duy nhất phân biệt "edge tự đổi" với
   "ta xoay". Đừng quy công / đổ lỗi khi chưa đọc timeline.
3. **`via unknown` đã fix bằng `edge_route` file.** Trước đây có khoảng trống
   probe rỗng (Mục 5.9: `09:37:14 (rỗng — probe lỗi)`) khiến `MAX_STUCK` không
   kích hoạt (Mục 5.6 "lỗi chưa sửa"). Nay probe ghi route vào file riêng nên
   không còn `unknown` — so sánh before/after luôn có hai đầu.

---

## 15. Cô lập MCP khỏi `:44444` — đo và sửa 2026-10-17

**Vấn đề.** Mục 14.3 dòng 5 ghi "MCP servers → direct" nhưng thực tế **chưa
đúng**: cả service lẫn process mới đều đẩy fetch MCP qua proxy env (`:44444`).
Xoay cắt listener ~7s → MCP đứt stream / reconnect fail.

**Đo được (2026-10-17):**
- Session start trong service mở **13 kết nối MCP mới lên `:44444`** (host
  cloudflare/context7/grep + retry loop). Generation Zen qua service: socket
  gửi **77KB** trên `:44444`.
- Standalone (process mới): **17 conn `:44444`** — ~15 conn MCP nhỏ (2–5KB gửi),
  còn lại là Zen (76.8KB gửi) + registry (411KB nhận). Các conn MCP đều xuất
  hiện đúng lúc MCP init.

**Ba cơ chế đã thử — kết quả đo:**
1. `fetch(url, { proxy: false })` per-request → **bun bỏ qua, rơi về env proxy**.
   Biến thể `null`/`""` cũng vậy; `"direct"` báo `fetch() proxy URL is invalid`.
   Explicit `{ proxy: { url } }` thì **được tôn trọng** (test dead-port: fail,
   không fallback env) — nhưng không có giá trị "no proxy" hợp lệ.
2. `delete process.env.HTTP(S)_PROXY` trong process (như `clearGlobalWarpProxy`)
   → **vô hiệu cho fetch**: bun dùng env **lúc process start**; xoá sau đó fetch
   vẫn mở conn `:44444` (đo trực tiếp).
3. `NO_PROXY` **lúc process start** → **hiệu lực, khớp suffix domain**
   (`mcp.cloudflare.com` khớp cả `docs.mcp.cloudflare.com`; `*` khớp tất cả).

**Sửa.** `lib/launch.sh` (proxy mode): `NO_PROXY` mặc định thêm
`mcp.cloudflare.com,mcp.context7.com,mcp.grep.app`. Zen (`opencode.ai`) không
nằm trong list → vẫn qua `:44444` (giữ nguyên choreography xoay/retry). Plugin
`zen-quota-retry.js`: **revert** pin `proxy:false` (vô hiệu như trên — đừng thêm
lại). Telegram MCP nay là HTTP service riêng trên `127.0.0.1:8765` (đã nằm
trong `NO_PROXY` sẵn qua `127.0.0.1`).

**Kết quả đo lại (standalone, env mới):** conn MCP trên `:44444`: **15 → 0**;
thay bằng kết nối direct `:443` tới host MCP. Zen vẫn trên `:44444` (76.8KB +
call nhỏ + registry). Env chốt lúc start → **restart OpenCode** để áp dụng cho
service/TUI đang chạy.
