#!/usr/bin/env python3
"""端到端场景驱动：模拟后端(mockgw) + debug 版 App + HTRACE 遥测。

场景：
  A 贴底流式  —— 停在底部时来流式输出，期望 px 跟着 max 走（自动跟随）
  B 看历史流式 —— 滑到历史里再流式，期望 px 恒定（不被顶走），并命中 HBREAK
每步都从 logcat 里的 HTRACE 取真实数字，不靠肉眼。
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = "export PATH=$HOME/tools/android-sdk/platform-tools:$PATH; adb"
PKG = "ai.ailigent.hermes_mobile"
MOCK = "http://127.0.0.1:8899"


def sh(cmd: str) -> str:
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout


def adb(*args: str) -> str:
    return sh(f"{ADB} {' '.join(args)}")


def dump_ui() -> list[tuple[str, str]]:
    adb("shell uiautomator dump /sdcard/ui.xml")
    adb("pull /sdcard/ui.xml /home/yyx/tmp/ui.xml")
    try:
        tree = ET.parse("/home/yyx/tmp/ui.xml")
    except Exception:
        return []
    out = []
    for n in tree.iter("node"):
        label = n.get("content-desc") or n.get("text") or ""
        if label:
            out.append((n.get("bounds") or "", label))
    return out


def center(bounds: str) -> tuple[int, int] | None:
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


def open_chat() -> bool:
    """保证停在会话内容页。"""
    nodes = dump_ui()
    if any("إرسال" in lbl for _, lbl in nodes):
        return True  # 已在会话页（有发送按钮）
    for bounds, label in nodes:
        if "模拟会话" in label:
            c = center(bounds)
            if c:
                adb("shell input tap", str(c[0]), str(c[1]))
                time.sleep(4)
                return True
    return False


def traces() -> list[dict]:
    raw = sh(f"{ADB} logcat -d | grep -E 'HTRACE|HBREAK'")
    rows = []
    for line in raw.splitlines():
        m = re.search(r"(HTRACE|HBREAK) (\{.*\})$", line.strip())
        if m:
            try:
                rows.append(json.loads(m.group(2)))
            except ValueError:
                pass
    return rows


def last_scroll() -> dict | None:
    for r in reversed(traces()):
        if r.get("k") == "scroll":
            return r
    return None


def swipe_to(target: str, limit: int = 25) -> dict | None:
    """target=bottom: from<70；target=history: from>400。"""
    time.sleep(0.6)
    s = last_scroll()
    if s is None:
        # 清过 logcat 后没有追踪：先滑一次制造一条
        adb("shell input swipe 360 800 360 400 160")
        time.sleep(0.8)
        s = last_scroll()
    for _ in range(limit):
        frm = s.get("from")
        if target == "bottom" and frm is not None and frm <= 60:
            return s
        if target == "history" and frm is not None and frm >= 400:
            return s
        s = last_scroll() or {}
        if target == "bottom":
            adb("shell input swipe 360 900 360 300 140")
        else:
            adb("shell input swipe 360 300 360 900 140")
        time.sleep(0.35)
    return last_scroll()


def stream(n: int, delay: int) -> None:
    # 本机有 HTTP 代理环境变量，urllib 会把 127.0.0.1 也走代理（返回 404）→ 用 curl --noproxy
    subprocess.run(f"curl -s --noproxy '*' -X POST '{MOCK}/ctl/stream?n={n}&delay={delay}&size=40'",
                   shell=True, capture_output=True, text=True)


def summarize(rows: list[dict], label: str) -> dict:
    stores = [r for r in rows if r.get("k") == "store"]
    evs = [r for r in rows if r.get("k") == "event"]
    breaks = [r for r in rows if r.get("b")]
    px = [r["px"] for r in stores if "px" in r]
    mx = [r["max"] for r in stores if "max" in r]
    return {
        "phase": label,
        "store_events": len(stores),
        "stream_events": sum(1 for e in evs if str(e.get("type", "")).startswith("message.")),
        "breaks": len(breaks),
        "px_first": px[0] if px else None,
        "px_last": px[-1] if px else None,
        "px_moved": (max(px) - min(px)) if px else None,
        "max_first": mx[0] if mx else None,
        "max_last": mx[-1] if mx else None,
        "max_grew": (mx[-1] - mx[0]) if mx else None,
    }


def main() -> int:
    if not open_chat():
        print("✗ 进不去会话页")
        return 1
    print("✓ 已在会话页")

    results = []

    # ── 场景 A：贴底流式 ──
    adb("logcat -c")
    s = swipe_to("bottom")
    print(f"A 起点: from={s.get('from') if s else '?'} px={s.get('px') if s else '?'}")
    time.sleep(0.8)
    stream(40, 60)
    time.sleep(4.5)
    rows = traces()
    a = summarize(rows, "A 贴底流式")
    results.append(a)
    print("A", json.dumps(a, ensure_ascii=False))

    # ── 场景 B：看历史流式 ──
    adb("logcat -c")
    s = swipe_to("history")
    print(f"B 起点: from={s.get('from') if s else '?'} px={s.get('px') if s else '?'}")
    time.sleep(0.8)
    stream(50, 60)
    time.sleep(5.5)
    rows = traces()
    b = summarize(rows, "B 看历史流式")
    results.append(b)
    print("B", json.dumps(b, ensure_ascii=False))

    with open("/home/yyx/tmp/scenario-results.json", "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print("\n结果已存 /home/yyx/tmp/scenario-results.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
