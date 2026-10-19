#!/usr/bin/env python3
"""驱动模拟器里的 App：按文字点击 / 长按 / 读界面文本（按视觉顺序）/ 查滚动条像素。

用法：
  drive.py texts                 # 按 y 坐标排序打印界面上所有文字（= 视觉顺序）
  drive.py tap <子串>            # 点第一个包含该子串的元素
  drive.py long <子串>           # 长按
  drive.py swipe up|down         # 滑动
  drive.py scrollbar             # 原始截屏，检查右侧是否有一列常显滚动条像素
  drive.py shot <路径>           # 存 PNG 截图
"""
import re
import struct
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zlib

ADB = "/home/yyx/tools/android-sdk/platform-tools/adb"
DEV = "emulator-5554"


def sh(*args, binary=False):
    r = subprocess.run([ADB, "-s", DEV, *args], capture_output=True)
    if r.returncode != 0 and not binary:
        sys.stderr.write(r.stderr.decode("utf-8", "replace"))
    return r.stdout if binary else r.stdout.decode("utf-8", "replace")


def dump(retry=4):
    for _ in range(retry):
        sh("shell", "uiautomator", "dump", "/sdcard/ui.xml")
        xml = sh("shell", "cat", "/sdcard/ui.xml")
        try:
            return ET.fromstring(xml)
        except ET.ParseError:
            time.sleep(0.8)
    return None


def nodes(root):
    out = []
    for n in root.iter("node"):
        t = (n.get("text") or "").strip()
        d = (n.get("content-desc") or "").strip()
        if not (t or d):
            continue
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds") or "")
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        out.append({"text": t or d, "x": (x1 + x2) // 2, "y": (y1 + y2) // 2,
                    "top": y1, "bottom": y2, "cls": (n.get("class") or "").split(".")[-1]})
    return out


def cmd_texts():
    root = dump()
    if root is None:
        print("dump 失败"); return 1
    rows = sorted(nodes(root), key=lambda n: (n["top"], n["top"]))
    print(f"({len(rows)} 个文本节点，按视觉顺序 top→bottom)")
    for n in rows:
        t = n["text"].replace("\n", "\\n")
        print(f"  y={n['top']:>5}  x={n['x']:>4}  {t[:160]!r}")
    return 0


def tap(needle, long=False):
    root = dump()
    if root is None:
        print("dump 失败"); return 1
    hits = [n for n in nodes(root) if needle in n["text"]]
    if not hits:
        print(f"未找到含 {needle!r} 的节点"); return 1
    n = sorted(hits, key=lambda n: n["top"])[0]
    if long:
        sh("shell", "input", "swipe", str(n["x"]), str(n["y"]), str(n["x"]), str(n["y"]), "900")
        print(f"long({n['text'][:40]!r}) @ {n['x']},{n['y']}")
    else:
        sh("shell", "input", "tap", str(n["x"]), str(n["y"]))
        print(f"tap({n['text'][:40]!r}) @ {n['x']},{n['y']}")
    time.sleep(1.2)
    return 0


def swipe(direction):
    sz = sh("shell", "wm", "size")
    m = re.search(r"(\d+)x(\d+)", sz)
    w, h = int(m.group(1)), int(m.group(2))
    x = w // 2
    if direction == "up":      # 手指上滑 = 看更旧的内容
        y1, y2 = int(h * 0.7), int(h * 0.3)
    else:
        y1, y2 = int(h * 0.3), int(h * 0.7)
    sh("shell", "input", "swipe", str(x), str(y1), str(x), str(y2), "400")
    time.sleep(1.2)
    print(f"swipe {direction} on {w}x{h}")
    return 0


def raw_screen():
    """screencap 原始帧：12 字节头（w,h,format）+ RGBA8888 像素。"""
    data = subprocess.run([ADB, "-s", DEV, "exec-out", "screencap"], capture_output=True).stdout
    w, h, fmt = struct.unpack_from("<III", data, 0)
    pix = data[12:]
    assert fmt in (1, 2), f"unexpected format {fmt}"
    return w, h, pix


def cmd_scrollbar():
    """统计最右 40px 内、高度中段那一列里的亮像素（滚动条绘制在列表右侧）。"""
    w, h, pix = raw_screen()
    best = []
    for x in range(w - 40, w):
        bright = 0
        for y in range(int(h * 0.15), int(h * 0.85), 3):
            i = (y * w + x) * 4
            r, g, b = pix[i], pix[i + 1], pix[i + 2]
            if max(r, g, b) > 120:
                bright += 1
        best.append((bright, x))
    best.sort(reverse=True)
    print(f"屏幕 {w}x{h}；最右 40 列里亮像素最多的几列（阈值 120）：{best[:6]}")
    col, x = best[0]
    print(f"结论：x={x} 列亮像素 {col} 个（每 3 行取一格，满值 ≈ {int(h*0.7/3)}）")
    return 0


def cmd_shot(path):
    data = subprocess.run([ADB, "-s", DEV, "exec-out", "screencap", "-p"], capture_output=True).stdout
    open(path, "wb").write(data)
    print("截图 ->", path, len(data), "bytes")
    return 0


if __name__ == "__main__":
    c = sys.argv[1]
    if c == "texts":
        sys.exit(cmd_texts())
    if c == "tap":
        sys.exit(tap(sys.argv[2]))
    if c == "long":
        sys.exit(tap(sys.argv[2], long=True))
    if c == "swipe":
        sys.exit(swipe(sys.argv[2]))
    if c == "scrollbar":
        sys.exit(cmd_scrollbar())
    if c == "shot":
        sys.exit(cmd_shot(sys.argv[2]))
    print(__doc__)
