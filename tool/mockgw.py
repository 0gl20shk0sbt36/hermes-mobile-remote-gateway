#!/usr/bin/env python3
"""最小 Hermes 网关模拟器（用于手机 App 的端到端调试，不碰真实服务/凭据）。

支持的协议子集（照 hermes app 的 wire format）：

  HTTP
    POST /auth/password-login       → 200 + cookie（口令随意）
    POST /api/auth/ws-ticket        → {"ticket": "..."}
    GET  /api/sessions/<sid>/messages?limit&offset&order → 历史分页
    GET  /api/fs/download?path=...  → 直接回文件（附件/媒体卡片调试用）

  WebSocket  /api/ws?ticket=...
    请求: {"jsonrpc":"2.0","id":1,"method":"session.resume","params":{...}}
    响应: {"jsonrpc":"2.0","id":1,"result":{...}} / error
    事件: {"type":"message.delta","session_id":"...","payload":{...}}
    服务端还可发起请求（如 clarify）: {"id":9,"method":"clarify","params":{...}}

  控制面（给测试脚本用）
    POST /ctl/stream?n=60&delay=40&size=30   开始流式输出
    POST /ctl/append?text=...                追加一条完成的 assistant 消息
    POST /ctl/clarify                        推一张两题提问卡
    POST /ctl/reset                          重置会话
    GET  /ctl/state                          看当前状态

用法: python3 mockgw.py [--port 8899] [--history 40]
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import struct
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
SID = "mock-session-1"

STATE = {
    "active_sid": SID,
    "seq": 0,
    "history": [],          # [{role, content, id}]
    "streaming": False,
    "stream_sent": 0,
    "events_sent": 0,
    "ws_clients": [],       # list[Handler]
    "log": [],
}
LOCK = threading.Lock()


def log(*parts):
    line = " ".join(str(p) for p in parts)
    with LOCK:
        STATE["log"].append(f"{time.strftime('%H:%M:%S')} {line}")
        STATE["log"][:] = STATE["log"][-400:]
    print(line, flush=True)


def build_history(n: int):
    out = []
    out.append({"role": "user", "content": "开始：这是一段用于调试的假对话。", "id": 1})
    for i in range(1, n):
        out.append({
            "role": "assistant" if i % 2 else "user",
            "content": f"第 {i} 条假消息。滚动锚定测试用：内容要够长才能把列表撑起来。" * 3,
            "id": i + 1,
        })
    out.append({
        "role": "assistant", "content": "", "id": 900,
        "tool_calls": [{
            "id": "call_c1", "type": "function",
            "function": {"name": "clarify", "arguments": json.dumps({
                "questions": [{"qid": "q0", "question": "清不清缓存？（历史回放用）",
                               "choices": ["先别清", "现在就清"], "multi_select": False}],
            }, ensure_ascii=False)},
        }],
    })
    out.append({
        "role": "tool", "tool_name": "clarify", "tool_call_id": "call_c1", "id": 901,
        "content": json.dumps({"answers": {"q0": "先别清"}}, ensure_ascii=False),
    })
    return out


# ── WebSocket 帧 ──────────────────────────────────────────────────────────────
def ws_frame(payload: bytes, opcode: int = 1) -> bytes:
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([n])
    elif n < 65536:
        header += bytes([126]) + struct.pack(">H", n)
    else:
        header += bytes([127]) + struct.pack(">Q", n)
    return header + payload


def ws_read(handler) -> tuple[int, bytes] | None:
    head = handler.rfile.read(2)
    if len(head) < 2:
        return None
    b1, b2 = head[0], head[1]
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", handler.rfile.read(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", handler.rfile.read(8))[0]
    mask = handler.rfile.read(4) if masked else b"\x00\x00\x00\x00"
    data = bytearray(handler.rfile.read(length)) if length else bytearray()
    if masked:
        for i in range(len(data)):
            data[i] ^= mask[i % 4]
    return opcode, bytes(data)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mockgw/1.0"

    # ── 工具 ──
    def _json(self, obj, code=200, extra_headers=None):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # 静音默认访问日志
        return

    # ── HTTP ──
    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if path == "/auth/password-login":
            log("HTTP login")
            self._json({"ok": True}, extra_headers={"Set-Cookie": "hermes_session_mock=1; Path=/"})
            return
        if path == "/api/auth/ws-ticket":
            log("HTTP ws-ticket")
            self._json({"ticket": "mock-ticket"})
            return
        if path == "/ctl/stream":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            n = int((q.get("n") or ["60"])[0])
            delay = float((q.get("delay") or ["40"])[0]) / 1000
            size = int((q.get("size") or ["30"])[0])
            threading.Thread(target=self._stream, args=(n, delay, size), daemon=True).start()
            self._json({"started": n, "delay_ms": delay * 1000, "chunk": size})
            return
        if path == "/ctl/append":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            text = (q.get("text") or ["手动追加的一条消息。"])[0]
            with LOCK:
                STATE["history"].append({"role": "assistant", "content": text, "id": len(STATE["history"]) + 1})
            self._broadcast({"type": "message.complete", "session_id": STATE["active_sid"], "payload": {"text": text}})
            self._json({"ok": True, "items": len(STATE["history"])})
            return
        if path == "/ctl/reason":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            n = int((q.get("n") or ["8"])[0])
            threading.Thread(target=self._stream_reason, args=(n,), daemon=True).start()
            self._json({"ok": True, "chunks": n})
            return
        if path == "/ctl/tools":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            n = int((q.get("n") or ["2"])[0])
            threading.Thread(target=self._stream_tools, args=(n,), daemon=True).start()
            self._json({"ok": True, "tools": n})
            return
        if path == "/ctl/media":
            self._media()
            self._json({"ok": True})
            return
        if path == "/ctl/foreign":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            text = (q.get("text") or ["另一台设备发来的消息"])[0]
            with LOCK:
                STATE["history"].append({"role": "user", "content": text, "id": len(STATE["history"]) + 1})
                n_items = len(STATE["history"])
            # 真网关在别的客户端提交 prompt 时广播 sessions.changed
            self._broadcast({"type": "sessions.changed", "session_id": STATE["active_sid"], "payload": {"session_id": STATE["active_sid"]}})
            log("foreign user message:", text, "items=", n_items)
            self._json({"ok": True, "items": n_items, "text": text})
            return
        if path == "/ctl/clarify":
            self._broadcast_request({
                "method": "clarify",
                "params": {
                    "session_id": STATE["active_sid"],
                    "questions": [
                        {"qid": "q0", "question": "调试提问：清不清缓存？",
                         "choices": ["先别清 (Recommended)", "现在就清"], "multi_select": False},
                        {"qid": "q1", "question": "先看哪些套件？",
                         "choices": ["models", "tools", "sessions"], "multi_select": True},
                    ],
                },
            })
            self._json({"ok": True})
            return
        if path == "/ctl/reset":
            with LOCK:
                STATE["history"] = build_history(int(os.environ.get("MOCK_HISTORY", "40")))
                STATE["stream_sent"] = 0
            self._json({"ok": True, "items": len(STATE["history"])})
            return
        self._json({"ok": False, "error": "unknown"}, 404)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path == "/api/ws" and self.headers.get("Upgrade", "").lower() == "websocket":
            self._ws()
            return
        if path == "/ctl/state":
            self._json({
                "items": len(STATE["history"]),
                "clients": len(STATE["ws_clients"]),
                "events_sent": STATE["events_sent"],
                "log": STATE["log"][-40:],
            })
            return
        if path.startswith("/api/sessions/") and path.endswith("/messages"):
            q = urllib.parse.parse_qs(parsed.query)
            limit = int((q.get("limit") or ["300"])[0])
            offset = int((q.get("offset") or ["0"])[0])
            order = (q.get("order") or ["latest"])[0]
            with LOCK:
                hist = list(STATE["history"])
            # 分页：order=latest 时从最新一端算偏移
            if order == "latest":
                end = max(0, len(hist) - offset)
                start = max(0, end - limit)
                page = hist[start:end]
            else:
                page = hist[offset:offset + limit]
            rows = []
            for m in page:
                row = {
                    "id": m["id"], "role": m["role"], "content": m["content"],
                    "display_kind": "user" if m["role"] == "user" else None,
                }
                for k in ("tool_name", "tool_call_id", "tool_calls"):
                    if m.get(k):
                        row[k] = m[k]
                rows.append(row)
            log(f"HTTP history offset={offset} limit={limit} -> {len(rows)}")
            self._json({
                "session_id": STATE["active_sid"],
                "profile": "mock",
                "messages": rows,
                "pagination": {"limit": limit, "offset": offset, "order": order, "returned": len(rows)},
            })
            return
        if path == "/api/fs/download":
            q = urllib.parse.parse_qs(parsed.query)
            target = (q.get("path") or [""])[0]
            max_width = int((q.get("max_width") or ["0"])[0] or 0)
            try:
                raw = open(os.path.expanduser(target), "rb").read()
            except OSError:
                self._json({"detail": "not found"}, 404)
                return
            ctype = "application/octet-stream"
            if max_width > 0 and target.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
                try:
                    import io as _io
                    from PIL import Image as _Image
                    with _Image.open(_io.BytesIO(raw)) as im:
                        if im.width > max_width:
                            h = max(1, round(im.height * max_width / im.width))
                            im = im.resize((max_width, h))
                        buf = _io.BytesIO()
                        im.convert("RGB").save(buf, format="WEBP", quality=78, method=4)
                        raw = buf.getvalue()
                    ctype = "image/webp"
                except Exception as exc:
                    log("thumb failed:", exc)
            etag = 'W/"%s"' % hashlib.sha1(raw).hexdigest()[:16]
            if (self.headers.get("If-None-Match") or "") == etag:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("ETag", etag)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if path in ("/", "/login"):
            self._json({"ok": True, "mock": True})
            return
        self._json({"ok": False}, 404)

    # ── WebSocket ──
    def _ws(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        with LOCK:
            STATE["ws_clients"].append(self)
        log("WS connected; clients =", len(STATE["ws_clients"]))
        # App 的 Gateway 只有在收到 gateway.ready 后才把状态置为 connected。
        self._broadcast({"type": "gateway.ready", "payload": {"version": "mockgw", "heartbeat": True}})
        try:
            while True:
                got = ws_read(self)
                if got is None:
                    break
                opcode, data = got
                if opcode == 8:      # close
                    break
                if opcode == 9:      # ping
                    self.wfile.write(ws_frame(data, opcode=10))
                    self.wfile.flush()
                    continue
                if opcode not in (1, 2):
                    continue
                try:
                    req = json.loads(data.decode("utf-8", "replace"))
                except ValueError:
                    continue
                self._rpc(req)
        except (ConnectionResetError, BrokenPipeError, OSError):
            pass
        finally:
            with LOCK:
                if self in STATE["ws_clients"]:
                    STATE["ws_clients"].remove(self)
            log("WS disconnected; clients =", len(STATE["ws_clients"]))

    def _send(self, obj):
        try:
            self.wfile.write(ws_frame(json.dumps(obj, ensure_ascii=False).encode()))
            self.wfile.flush()
            return True
        except (BrokenPipeError, OSError):
            return False

    def _rpc(self, req: dict):
        rid = req.get("id")
        method = req.get("method") or ""
        params = req.get("params") or {}
        if rid is None or not method:
            # 客户端对服务端请求的回执（clarify 的 answers 等，答案在 result 里）
            log("CLIENT RESPONSE", json.dumps(req, ensure_ascii=False)[:300])
            return
        log("RPC", method, json.dumps(params, ensure_ascii=False)[:120])
        result: dict = {}
        if method == "session.list":
            result = {"sessions": [{
                "id": SID, "session_key": SID, "title": "模拟会话（mockgw）",
                "updated_at": time.time(), "message_count": len(STATE["history"]),
                "preview": "调试用假会话", "model": "mock-model", "source": "mobile",
            }]}
        elif method == "session.resume":
            result = {
                "session_id": STATE["active_sid"], "running": False, "message_count": len(STATE["history"]),
                "info": {"model": "mock-model", "provider": "mock", "reasoning_effort": "medium"},
                "messages": [],
            }
        elif method == "session.active_list":
            result = {"sessions": [{
                "id": SID, "session_key": SID, "title": "模拟会话（mockgw）",
                "status": "idle", "model": "mock-model", "last_active": time.time(),
            }]}
        elif method == "session.create":
            STATE["seq"] += 1
            new_sid = f"mock-session-{STATE['seq'] + 1}"
            STATE["active_sid"] = new_sid
            with LOCK:
                STATE["history"] = []
            result = {
                "session_id": new_sid,
                "stored_session_id": new_sid,
                "info": {"model": "mock-model", "provider": "mock"},
            }
            log("session.create ->", new_sid)
        elif method == "session.status":
            result = {"running": STATE["streaming"], "session_id": STATE["active_sid"]}
        elif method == "process.list":
            result = {"processes": []}
        elif method == "subagent.list":
            result = {"subagents": []}
        elif method == "commands.catalog":
            result = {"commands": []}
        elif method == "model.options":
            result = {"models": [{"id": "mock-model", "label": "Mock"}]}
        elif method == "prompt.submit":
            log("PROMPT", json.dumps(params, ensure_ascii=False)[:160])
            result = {"accepted": True}
            text = str(params.get("text") or "")
            with LOCK:
                STATE["history"].append({"role": "user", "content": text, "id": len(STATE["history"]) + 1})
            threading.Thread(target=self._stream, args=(40, 0.05, 30), daemon=True).start()
        elif method == "session.interrupt":
            STATE["streaming"] = False
            result = {"ok": True}
        else:
            result = {}
        self._send({"jsonrpc": "2.0", "id": rid, "result": result})

    # ── 事件推送 ──
    def _broadcast(self, event: dict):
        """event = {type, session_id?, payload} → 包成 JSON-RPC notification 下发。"""
        params = dict(event)
        note = {"jsonrpc": "2.0", "method": "event", "params": params}
        with LOCK:
            clients = list(STATE["ws_clients"])
        for c in clients:
            c._send(note)

    def _broadcast_request(self, req: dict):
        with LOCK:
            clients = list(STATE["ws_clients"])
        for i, c in enumerate(clients):
            c._send({"jsonrpc": "2.0", "id": 9000 + i, **req})

    def _stream_reason(self, n: int):
        """先来一段推理，再来正文：验证 App 的思考块（默认折叠、点开看全文）。"""
        sid = STATE["active_sid"]
        STATE["streaming"] = True
        self._broadcast({"type": "message.start", "session_id": sid, "payload": {}})
        for i in range(n):
            self._broadcast({"type": "reasoning.delta", "session_id": sid,
                             "payload": {"text": f"思考第 {i} 步：先看上下文，再决定要不要读文件。\n"}})
            time.sleep(0.25)
        self._broadcast({"type": "reasoning.available", "session_id": sid,
                         "payload": {"text": "".join(f"思考第 {i} 步。\n" for i in range(n))}})
        self._broadcast({"type": "message.delta", "session_id": sid,
                         "payload": {"text": "看完上下文了，结论是：不需要读文件。\n"}})
        self._broadcast({"type": "message.complete", "session_id": sid,
                         "payload": {"text": "看完上下文了，结论是：不需要读文件。"}})
        STATE["streaming"] = False
        log(f"reasoning stream done: {n}")

    def _stream_tools(self, n: int):
        """一轮里穿插 n 次工具调用，验证"工具行按顺序内联、点开能看参数/返回值"。"""
        STATE["streaming"] = True
        self._broadcast({"type": "message.start", "session_id": STATE["active_sid"], "payload": {}})
        self._broadcast({"type": "message.delta", "session_id": STATE["active_sid"],
                         "payload": {"text": "先看一下环境，然后逐个调用工具。\n"}})
        time.sleep(0.2)
        for i in range(n):
            tid = f"tool-{int(time.time()*1000)}-{i}"
            self._broadcast({"type": "tool.start", "session_id": STATE["active_sid"], "payload": {
                "tool_id": tid,
                "name": ["terminal", "web_search", "read_file"][i % 3],
                "args": {"command": f"echo step-{i}", "timeout": 30, "描述": "工具参数多行测试"},
                "context": f"step-{i}",
            }})
            time.sleep(0.7)
            self._broadcast({"type": "tool.complete", "session_id": STATE["active_sid"], "payload": {
                "tool_id": tid,
                "summary": f"step-{i} 完成",
                "duration_s": 0.71,
                "result": f"第 {i} 个工具的返回值：\n" + "输出行\n" * 6,
            }})
            self._broadcast({"type": "message.delta", "session_id": STATE["active_sid"],
                             "payload": {"text": f"第 {i} 步完成，继续。\n"}})
            time.sleep(0.2)
        self._broadcast({"type": "message.complete", "session_id": STATE["active_sid"],
                         "payload": {"text": "工具链跑完了。"}})
        STATE["streaming"] = False
        log(f"tools stream done: {n}")

    def _media(self):
        """一条带 MEDIA: 行的完成消息，验证卡片原地渲染 + 点击下载。"""
        img = os.path.expanduser("~/share/apk/shots-debug/01-login.png")
        txt = os.path.expanduser("~/share/inbox/README.md")
        text = ("这是带媒体的回复，卡片应该**原地**出现（不是堆到最底部）：\n\n"
                f"MEDIA:{img}\n\n"
                "中间还有一段文字，用来验证顺序没被打乱。\n\n"
                f"MEDIA:{txt}\n\n"
                "结尾一句话。\n")
        with LOCK:
            STATE["history"].append({"role": "assistant", "content": text, "id": len(STATE["history"]) + 1})
        self._broadcast({"type": "message.complete", "session_id": STATE["active_sid"], "payload": {"text": text}})
        log("media message pushed")

    def _stream(self, n: int, delay: float, size: int):
        if STATE["streaming"]:
            return
        STATE["streaming"] = True
        text = ""
        self._broadcast({"type": "message.start", "session_id": STATE["active_sid"], "payload": {}})
        for i in range(n):
            chunk = f"[{i:03d}] 流式块{'·' * (size // 3)}\n"
            text += chunk
            self._broadcast({"type": "message.delta", "session_id": STATE["active_sid"], "payload": {"text": chunk}})
            STATE["events_sent"] += 1
            time.sleep(delay)
        self._broadcast({"type": "message.complete", "session_id": STATE["active_sid"], "payload": {"text": text}})
        with LOCK:
            STATE["history"].append({"role": "assistant", "content": text, "id": len(STATE["history"]) + 1})
            STATE["stream_sent"] += n
        STATE["streaming"] = False
        log(f"stream done: {n} chunks")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8899)
    ap.add_argument("--history", type=int, default=40)
    args = ap.parse_args()
    os.environ["MOCK_HISTORY"] = str(args.history)
    STATE["history"] = build_history(args.history)
    srv = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    srv.daemon_threads = True
    log(f"mockgw listening on 0.0.0.0:{args.port} (history={args.history}, sid={SID})")
    srv.serve_forever()


if __name__ == "__main__":
    main()
