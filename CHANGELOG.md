## 1.6.0+22

- **常驻通知本地化**：通知栏里的持续通知原来标题/渠道名/按钮全是 Kotlin 里硬编码的阿拉伯语
  （中文界面下就是「Hermes + 一串阿拉伯字母」）。现在这些文案由 Dart 按 App 当前语言下发：
  标题「Hermes 正在后台运行」、渠道「Hermes 后台连接」、按钮「关闭后台连接」、初始状态「正在连接服务器…」。
- 通知渠道换成 `gateway_connection_v2` 并删除旧渠道——Android 的渠道名创建后不可改，不换 id 的话
  通知设置里会一直留着阿拉伯语渠道名。
- 语言切换后重新开启后台连接即生效（服务启动时下发一次）。
- **历史里能看见"我问过什么"**：clarify（提问卡）在历史里原来只有一个 "clarify" 标签、看不到题目。
  现在工具行摘要直接显示题目文本，展开可看完整选项与你的回答（`{"answers": …}`）。
- `chatItemsFromResume` 与 REST 历史行统一走同一套解析（认 `text`/`content`、认 `tool_calls` 与配对的
  `role=tool` 行），分页与首屏行为一致。

## 1.5.1+21

- **历史分页（"加载更早"）修好了**：REST 历史行用的是 `content` 字段，而 `chatItemsFromResume` 只读 `text`，
  导致翻页抓回来的整页变成空气泡（实测 100 行 → 50 个空 item，滑到顶整屏空白）。现在 `text`/`content`/`display_content` 都认。
- 分页前插补偿加护栏：`maxScrollExtent` 是惰性估算，刚插入一页时会从 7.5 万塌到 6 千，
  照 `offset + grew` 补偿会把视图甩出好几屏（实测 -69874px）。估算不合理时不补偿。
- 文件卡片的 MIME 按扩展名给全（md/txt/json/zip/图片/音视频…），
  不再一律 `*/*`（之前点开 .md 会列出"日历/证书安装器"这类无关应用）。
- 调试基建：`lib/trace.dart` 遥测（debug 构建默认开，release 零开销）、`tool/mockgw.py` 模拟网关、
  `tool/scenario-e2e.py` 场景驱动；新增 `test/history_pagination_test.dart` 回归。

## 1.5.0+20

- Ported the **web/RN scroll model** to Flutter (no maintained equivalent exists in Flutter):
  - transcript list is **top-anchored** (`reverse: false`), so appending at the end cannot move content above;
  - "stick to bottom" only when within 70px of the bottom (the same 70px threshold `use-stick-to-bottom`,
    the engine behind bolt.new, uses), plus the initial jump to the newest message on open;
  - older pages (the only case where content really is inserted above) re-anchor by the measured delta —
    the `firstItemIndex` idea from react-virtuoso / RN's `maintainVisibleContentPosition`.
- Fixed the real reason the previous attempt looked broken: `store.items` is newest-first, so a top-anchored
  list has to walk it backwards; without that flip the transcript rendered upside down and new rows landed
  at the visual top.
- Regression tests now cover the model: opens at the newest message, a new row while reading history moves
  nothing (offset and the visible bubble both pinned), streaming likewise, and at-bottom keeps following.

`flutter analyze`: 0 issues · `flutter test`: 166 passed.

## 1.4.5+19

- Reverted the top-anchored experiment (it lost the "opens at the newest message" behaviour and threw
  runtime errors); the list is reversed again, so a session always opens at the bottom.
- Reading position is now held by a **centre anchor** fed through a **multi-frame convergence loop**:
  the bubble nearest the viewport centre is remembered before a change and pushed back to the same y on
  each following frame until the offset settles. Two reasons the earlier attempts failed:
  1. a `SliverList` only knows the new extent one frame later, so a single `jumpTo` gets clamped and the
     compensation is silently dropped;
  2. anchoring on the *top-most* bubble loses its render object as soon as content shifts (it scrolls
     out and is recycled), so the correction had nothing to measure.
- Every correction is still gated on `isScrollingNotifier` — nothing is touched while a drag or fling is
  running.
- History pagination is wired back onto the reversed list (row at the oldest end, auto-load near it).

`flutter analyze`: 0 issues · `flutter test`: 165 passed.

## 1.4.4+18

- The transcript list is now **non-reversed** (top-anchored), which removes the drift instead of
  compensating for it. In a `reverse: true` list the scroll offset is measured from the bottom, so any
  growth at the newest end pushes everything above it — every workaround (pixel compensation, anchors,
  freezing) fought that. Top-anchored, appending at the end cannot move existing content, which is how
  web chat UIs behave. The list still follows the newest output, but only while it is already at the
  bottom; the first layout jumps to the bottom once (and older pages, which really are inserted above,
  re-anchor by the height delta).
- Older pages still load on scroll-to-top; the page insert is the only case that needs re-anchoring now,
  and it is tracked explicitly (`store.olderEpoch`).

`flutter analyze`: 0 issues · `flutter test`: 165 passed.

## 1.4.3+17

- History pagination: the transcript now opens with the newest page and loads older messages on demand —
  scrolling near the oldest end (or tapping the row at the top) pulls the next page via
  `GET /api/sessions/<sid>/messages?limit&offset&order=latest`, merges it above the current content and
  de-duplicates the page boundary. A spinner shows while a page is in flight, and the row says so when
  there is nothing older left.
- Because older rows are appended beyond the current scroll extent, the list does not move when a page
  arrives (same behaviour as the reference chat list's `onEndReached`).

`flutter analyze`: 0 issues · `flutter test`: 165 passed.

## 1.4.2+16

- Adopted the reference model (Flyer Chat's `flutter_chat_ui`, `ChatAnimatedList`): **the transcript's
  scroll position is never adjusted programmatically except when already at the bottom** (or right after
  sending). All of the custom pixel-compensation / anchor code is gone — that code was what jumped while
  you were scrolling, because `ScrollPosition.jumpTo` cancels any scroll activity that is in flight,
  including a ballistic fling.
- A "jump back to latest" button now appears ~250 ms after you scroll away (same delay the reference
  library uses), so it does not flicker during a fling.
- Behaviour you should see: while reading history, arriving tokens grow the newest bubble and the list
  simply follows Flutter's reversed-viewport rules — no jumps; if the list is at the bottom it keeps
  following the newest content on its own.

`flutter analyze`: 0 issues · `flutter test`: 165 passed.

## 1.4.1+15

- Fix: corrections no longer fight the user's scrolling. `jumpTo` cancels any in-flight scroll
  activity (`ScrollPosition.jumpTo` docs), so compensating while a drag **or a ballistic fling** was
  running made the view jump mid-scroll. The old guard only covered a finger-down drag
  (`ScrollStartNotification.dragDetails != null`); a fling sends the same notification with no drag
  details. Every correction is now gated on `ScrollPosition.isScrollingNotifier` (true for the whole
  scroll, idle-only when safe) plus the notification state, so while you are scrolling nothing is
  touched at all.

`flutter analyze`: 0 issues · `flutter test`: 165 passed.

## 1.4.0+14

- Reworked the transcript's scroll logic around an **anchor** instead of pixel deltas. The viewport's
  top-most visible bubble is remembered (item + screen y) right before any content change and pushed
  back to that same y after layout, so the reading position no longer moves when a turn *ends* — the
  old code only compensated growth, and the end of a turn shrinks the list (the running line disappears,
  an empty placeholder item is dropped, the streaming text is finalised), which snapped the view to the
  top. Both directions are now handled by the same rule, and the fallback path (anchor item removed)
  restores the last resting offset. Item keys are stable per `ChatItem`, so reordering never resets the
  scroll state.

`flutter analyze`: 0 issues · `flutter test`: 165 passed.

## 1.3.9+13

- Multi-device sync: a user message typed on another surface (Windows desktop ↔ phone) now shows up
  without refreshing. The gateway never broadcast the user's own row, so each client only ever saw
  its own sends. On this side the app now pulls one page of the transcript when a turn starts (and on
  `sessions.changed`) and merges the last user row if it isn't already present (dedupe by text, so
  your own optimistic bubble is not duplicated).

`flutter analyze`: 0 issues (2 info lints) · `flutter test`: 165 passed.

## 1.3.8+12

- Fix: tapping a received file did nothing (no chooser, no installer). Three separate causes:
  1. downloads were written to `getApplicationDocumentsDirectory()` (`…/app_flutter`), which is
     **not** covered by open_filex's FileProvider (`files/` + `cache/` only) — so the URI could not
     be opened at all. They now go to `getApplicationSupportDirectory()` (`…/files`).
  2. `REQUEST_INSTALL_PACKAGES` was missing, so Android 8+ refused to launch the APK installer.
  3. no `<queries>` entry for `application/vnd.android.package-archive` / `VIEW`, so Android 11+
     package visibility hid the installer and open_filex reported "no app can open this".
  APK/PDF now also pass an explicit MIME type, and a failed install shows the real reason instead of
  staying silent (the user still has to allow "install unknown apps" for Hermes once).

`flutter analyze`: 0 issues · `flutter test`: 158 passed.

## 1.3.7+11

- Fix: a `MEDIA:<path>` line **inside a fenced code block** is no longer treated as a real attachment.
  Splitting on it cut the code fence in half, which rendered as an empty code block plus mis-paired
  fences (the following paragraph fell inside the block) and a phantom media card. The splitter now
  tracks ```/~~~ fences and only honours `MEDIA:` lines outside them.

`flutter analyze`: 0 issues · `flutter test`: 158 passed.

## 1.3.6+10

- Files the agent sends (`MEDIA:<path>`) stay where they were written: the marker line is replaced by a
  card **in place** instead of every card being collected at the end of the message, and images render
  inline at that spot. Only a line that is exactly `MEDIA:<path>` counts — a mention inside a sentence or
  inline code no longer spawns a phantom card (that bug is what made a tap report "file not found").
- Links are tappable: a short tap opens the system browser (`http`/`https`/`mailto`/`tel` only — other
  schemes such as `intent:`/`file:`/`javascript:` are refused), while long-press still selects and copies
  text, because gpt_markdown resolves link taps at paragraph level without taking selection away.

`flutter analyze`: 0 issues · `flutter test`: 156 passed.

## 1.3.5+9

- The question panel (clarify / approval) can be collapsed: tap the title row to keep just the header
  plus a one-line summary of the next unanswered question, so the panel stops covering the conversation
  while you read back. The choice is remembered for the next question too, and a multi-question card
  shows how many you have already answered. Tapping again expands it back.

`flutter analyze`: 0 issues · `flutter test`: 148 passed.

## 1.3.4+8

- Reading position is kept while new output arrives: when the transcript is scrolled away from the newest
  message, the viewport is compensated by the same amount the content grew, so a new tool row or streamed
  text no longer pushes what you are reading out of view. (A small residual is expected: content outside
  the viewport is laid out from an estimate.)
- Duplicate output hardening: a replayed `message.delta` chunk that the streaming bubble already ends with
  is ignored, `message.complete` never re-adds text already delivered in this turn (interim included), and
  `session.resume`'s in-flight tail is not appended when the transcript already ends with the same text.
- Top bar: the session actions are now labelled pills — 「归档」 (release the session from this phone) and
  「新建」 (new session) — instead of two ambiguous icons (archive box / pencil).
- Emulator builds are a first-class Gradle flavour: `--flavor emu` disables Impeller via
  `src/emu/AndroidManifest.xml`; the shipped `prod` flavour is untouched. See docs/EMULATOR.md.
- `HermesApplication` no longer hands a destroyed engine to a recreated activity (engine lifecycle
  listener + `FlutterEngineCache` + `isExecutingDart` check), which fixes the
  `FlutterJNI is not attached to native` crash seen when the APK is installed while the app is starting.

`flutter analyze`: 0 issues · `flutter test`: 145 passed.

## 1.3.3+7

- Background activity panel no longer flickers: rows now follow the gateway's report. `process.list` keeps
  recently-finished processes, so the old "clear a row 6 s after it finishes" timer fought the 6 s poll
  (row removed, then re-created by the next poll, forever). Rows stay while the server still reports them
  and disappear once it stops; the linger window now only applies to event-only rows.
- `_serverRows` is cleared with the session so a re-used id cannot suppress the linger.

`flutter analyze`: 0 issues · `flutter test`: 139 passed.

## 1.3.2+6

Seven mobile-client fixes reported on 2026-10-16.

- Clarify answers are sent as `{"answers": {qid: value}}`; the previous frame (`{"answer": ...}`) made the gateway treat every answer as a cancel. The card is now a form: per-question choices (single or `multi_select`), a free-text answer, and an explicit submit button.
- Tool rows render in order: no more pre-created placeholder bubble, so text that follows a tool call gets its own bubble, and `message.interim` (commentary around tool calls) is no longer dropped.
- Tool rows keep the full arguments and the return value (live `tool.start`/`tool.complete`, stored `content` in history) with expandable, full-screen and copyable payloads.
- Background activity panel is height-capped and scrolls internally, so the collapse control stays reachable; every row opens a detail sheet (subagents poll `subagent.tail` for their live transcript).
- Always-visible transcript scrollbar plus a jump-to-latest button.
- Diagnostics panel (long-press the top-bar title): chronological server events/requests and outgoing frames, secrets redacted.
- Offline demo mode (`--dart-define=HERMES_DEMO=true`) for reviewing the UI without a gateway.

`flutter analyze`: 0 issues · `flutter test`: 137 passed.

# Changelog

## 1.3.1

Fast, reliable session switching.

### Fixed
- Opening a session no longer pulls the whole transcript through the WebSocket. `session.resume` is called with `omit_messages` and the transcript comes from the REST page (`/api/sessions/{id}/messages`), as Hermes Desktop does. On a long session this cut a switch from 4-5 s (a ~16 MB reply) to well under a second.
- Switching back to a session paints its chat immediately from a per-session cache, then reconciles with the server in the background.
- A slow earlier switch can no longer overwrite the session picked after it.
- Live events that arrive while a session loads are held and applied after the snapshot instead of being lost.
- Opening a session that is mid-turn restores the in-flight prompt and partial reply, so streaming continues in place.
- The running indicator no longer sticks: the active-session poll only corrects it after two consistent readings, ignores the brief post-turn window and the `starting` state of an agent being built, and a turn that finishes in a background session clears its cached running state.
- Gateways without the REST transcript route fall back to the previous full resume.

## 1.3.0

Liquid Glass design, tuned for 120 Hz Android displays.

### Design
- The top bar and composer float as glass over the transcript, so messages scroll beneath them; the drawer, model sheet, dialogs, cards and page headers use the same glass surfaces.
- Glass is a warm tint with a lit top edge and a specular rim, built on the existing colour tokens (no palette change).
- Every control on a glass surface (attach, commands, model chip, voice, send, steer, queue, dialog actions) is an inset glass drop; disabled controls show an empty rim.
- Presses squash and spring back like a liquid drop; dialogs and revealed surfaces materialize (settle in from slightly oversized); page routes slide in with a soft overshoot.
- Model sheet: Thinking levels use compact labels (X-High, Med) that never clip, and the selected model is marked with a glass check instead of a flat disc.

### Performance
- No refraction shaders or live backdrop blur: on a Snapdragon 7-class phone a live blur behind the bars capped scrolling at ~67-77 fps; without it the transcript scrolls at ~100-110 fps on a 120 Hz panel. `--dart-define=GLASS_BLUR=true` restores the blur for comparison.
- The app asks Android for the display's fastest refresh rate on start and resume.
- Spinners and live status dots repaint on their own layers; bar heights update through notifiers instead of rebuilding the screen.
- Optional side-by-side build: `HERMES_APP_VARIANT=<name>` produces a separate application id and label for experiments.

## 1.2.0

Two cross-device features on top of 1.1.0.

### Pull a session between devices
- A send refused because another device owns the session (`SESSION_NOT_OWNED`) now offers to pull it: a dialog explains the session is open elsewhere and pulls it to the phone on request, then re-sends the same draft automatically once ownership moved.
- The draft is restored to the composer on refusal, so nothing typed is lost.
- The backend half (`session.takeover` RPC + `session.taken_over` event + cross-surface lease transfer) lands in the gateway; a desktop plugin contributes "اسحب الجلسة إلى هذا الجهاز" to the command palette and toasts when a session is pulled away from that window.
- While a turn is actively running on the other surface the pull waits or refuses (`TAKEOVER_BUSY`) instead of corrupting the running turn.

### Saved gateways (البوابات والاتصال)
- New screen listing saved gateways: switch between a local Tailscale serve and a public remote gateway over HTTPS with one tap; the active gateway is checked and shown in the drawer.
- Add or edit a gateway (name, address, username, password) with a Test connection action that proves login and the WebSocket ticket before saving, and per-gateway delete behind a confirmation.
- Passwords live per gateway in the platform keychain; existing single-login installs migrate into the first saved gateway on update.
- URLs are normalized by scheme: plain-HTTP hosts default to `:9131`, `https://` keeps the standard port (no Tailscale needed for the remote gateway).

## 1.1.0

Background activity panel for the open session.

- New panel above the composer lists long-running `terminal(background=true)` processes, delegated subagents and `/background` side agents that belong to the session you are looking at.
- Rows show live state (running, finished, failed with exit code), the tool a subagent is using, its model and tool count; the panel stays collapsed to one line until you open it.
- Streaming terminal output is captured per process and the detail view keeps the tail bounded, so a noisy job cannot grow the row without limit.
- Stop a running process (`process.kill`) or a live subagent (`subagent.interrupt`); dismiss finished rows. A failure to stop keeps the row so it can be retried.
- Finished rows clear themselves after a short linger, failures stay longer, and switching or closing a session drops the previous session's rows.
- Hydrates from `process.list` / `subagent.list` on open and every few seconds, so work started before the app connected (or while the phone slept) still appears.

## 1.0.0

First public Android community release.

- Authenticated Hermes gateway access over a private Tailscale network.
- Streaming chat, sessions, model search and English Thinking levels.
- Steering, queued follow-ups and turn-bound attachment handling.
- Received image/file cards and authenticated downloads.
- Foreground connection service and local completion notifications.
- Shared confirmation/feedback components and explicit model-switch approval.
- Private installation defaults removed from the public app.
- Dedicated release signing, checksum manifest and Android CI build artifacts.

Known limits: Arabic UI only; ARM64 release; background delivery is not cloud push; backend compatibility depends on the gateway version. See the README before deployment.
