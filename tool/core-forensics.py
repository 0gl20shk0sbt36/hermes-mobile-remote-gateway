#!/usr/bin/env python3
"""极简 ELF64 core dump 取证（不需要 gdb）。

用法: core-forensics.py <core> [--stack-words 4000]

输出: 崩溃线程的信号/RIP/模块/偏移/最近符号, 以及沿栈扫描出的疑似调用链。
符号用 nm -D / nm 现场查; 只做只读 pread, 不加载整个 core。
"""
import os
import struct
import subprocess
import sys

PT_LOAD, PT_NOTE = 1, 4
NT_PRSTATUS, NT_PRPSINFO, NT_FILE, NT_SIGINFO = 1, 3, 0x46494C45, 0x53494749
SIGNAMES = {4: "SIGILL", 6: "SIGABRT", 7: "SIGBUS", 8: "SIGFPE", 11: "SIGSEGV"}


def read_at(fh, off, size):
    fh.seek(off)
    return fh.read(size)


def parse(path):
    fh = open(path, "rb")
    ident = read_at(fh, 0, 64)
    assert ident[:4] == b"\x7fELF" and ident[4] == 2, "not an ELF64 core"
    e_phoff, = struct.unpack_from("<Q", ident, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", ident, 0x36)
    loads, notes = [], []
    for i in range(e_phnum):
        ph = read_at(fh, e_phoff + i * e_phentsize, e_phentsize)
        p_type, p_flags = struct.unpack_from("<II", ph, 0)
        p_offset, p_vaddr, p_paddr, p_filesz, p_memsz = struct.unpack_from("<QQQQQ", ph, 8)
        if p_type == PT_LOAD:
            loads.append((p_vaddr, p_memsz, p_offset, p_filesz, p_flags))
        elif p_type == PT_NOTE:
            notes.append((p_offset, p_filesz))
    # 解析 notes
    threads, files, siginfo = [], [], None
    for off, size in notes:
        blob = read_at(fh, off, size)
        pos = 0
        while pos + 12 <= len(blob):
            namesz, descsz, ntype = struct.unpack_from("<III", blob, pos)
            pos += 12
            name = blob[pos:pos + namesz].rstrip(b"\0")
            pos += (namesz + 3) // 4 * 4
            desc = blob[pos:pos + descsz]
            pos += (descsz + 3) // 4 * 4
            if name != b"CORE":
                continue
            if ntype == NT_PRSTATUS and len(desc) >= 112:
                pr_cursig, = struct.unpack_from("<H", desc, 12)
                regs = struct.unpack_from("<27Q", desc, 112 - 112 + 8 * 0) if False else None
                # x86_64 elf_prstatus: pr_reg 紧跟固定头部; 直接按已知偏移取寄存器
                # struct elf_prstatus: 0 si_signo(short)... 用 user_regs_struct 布局找 RIP/RSP:
                # pr_reg 起始偏移在 x86_64 上是 112 (pr_pid 等之后)
                reg_off = 112
                if len(desc) >= reg_off + 27 * 8:
                    r = struct.unpack_from("<27Q", desc, reg_off)
                    # user_regs_struct: r15,r14,r13,r12,rbp,rbx,r11,r10,r9,r8,rax,rcx,rdx,rsi,rdi,orig_rax,rip,cs,eflags,rsp,ss,...
                    threads.append({"cursig": pr_cursig, "rip": r[16], "rsp": r[19], "rbp": r[4], "rax": r[10]})
            elif ntype == NT_SIGINFO and len(desc) >= 16:
                si_signo, si_errno, si_code = struct.unpack_from("<iii", desc, 0)
                addr, = struct.unpack_from("<Q", desc, 16) if len(desc) >= 24 else (0,)
                siginfo = {"signo": si_signo, "code": si_code, "addr": addr}
            elif ntype == NT_FILE and len(desc) >= 8:
                count, pgsz = struct.unpack_from("<QQ", desc, 0)
                pos2 = 16
                ents = []
                for _ in range(count):
                    start, end, off2 = struct.unpack_from("<QQQ", desc, pos2)
                    pos2 += 24
                    ents.append([start, end, off2, None])
                strs = desc[pos2:].split(b"\0")
                for i, e in enumerate(ents):
                    if i < len(strs):
                        e[3] = strs[i].decode("utf-8", "replace")
                files.extend(ents)
    return fh, loads, threads, files, siginfo


def mem_read(fh, loads, addr, size):
    for vaddr, memsz, off, filesz, flags in loads:
        if vaddr <= addr < vaddr + memsz:
            delta = addr - vaddr
            avail = min(size, memsz - delta, max(0, filesz - delta))
            if avail <= 0:
                return b""
            return read_at(fh, off + delta, avail)
    return b""


def module_of(files, addr):
    for start, end, off, name in files:
        if start <= addr < end:
            return name, addr - start + off, end
    return None, None, None


def main():
    core = sys.argv[1]
    fh, loads, threads, files, siginfo = parse(core)
    print(f"== core: {core}  ({os.path.getsize(core)/1e9:.2f} GB)")
    print(f"== PT_LOAD 段: {len(loads)}  映射文件: {len(files)}  线程: {len(threads)}")
    if siginfo:
        print(f"== si_signo={siginfo['signo']} ({SIGNAMES.get(siginfo['signo'], '?')}) si_code={siginfo['code']} si_addr=0x{siginfo['addr']:x}")
    crash = None
    for t in threads:
        if t["cursig"]:
            crash = t
            break
    crash = crash or (threads[0] if threads else None)
    if not crash:
        print("!! 没解析到线程寄存器（NT_PRSTATUS 布局不符）")
        return
    print(f"== 崩溃线程: signal={crash['cursig']} RIP=0x{crash['rip']:x} RSP=0x{crash['rsp']:x} RBP=0x{crash['rbp']:x} RAX=0x{crash['rax']:x}")
    name, moff, end = module_of(files, crash["rip"])
    print(f"== RIP 落在: {name} + 0x{moff:x}" if name else f"== RIP 落在未映射区: 0x{crash['rip']:x}")
    if name:
        base = name if os.path.isabs(name) else os.path.join(_emu_libdir(), name)
        sym = nearest_symbol(base, moff)
        print(f"== 最近符号: {sym}")
    if siginfo and siginfo["addr"]:
        an, aoff, _ = module_of(files, siginfo["addr"])
        print(f"== si_addr 落在: {an} + 0x{aoff:x}" if an else f"== si_addr 未映射: 0x{siginfo['addr']:x}")
    # 沿栈扫返回地址（粗粒度调用链）
    words = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
    stack = mem_read(fh, loads, crash["rsp"], words * 8)
    print(f"== 栈上疑似返回地址（模块+偏移+符号），最多 25 条：")
    seen = 0
    for i in range(0, len(stack) - 8, 8):
        w, = struct.unpack_from("<Q", stack, i)
        if w < 0x1000:
            continue
        n, o, _ = module_of(files, w)
        if not n:
            continue
        n2 = n if os.path.isabs(n) else os.path.join(_emu_libdir(), n)
        if not os.path.exists(n2):
            continue
        s = nearest_symbol(n2, o)
        if not s:
            continue
        print(f"   rsp+0x{i:04x}: {os.path.basename(n)} + 0x{o:x}  {s}")
        seen += 1
        if seen >= 25:
            break


_CACHE = {}


def _emu_libdir():
    return "/home/yyx/tools/android-sdk/emulator/lib64"


def nearest_symbol(path, offset):
    if path in _CACHE:
        table = _CACHE[path]
    else:
        table = []
        for args in (["nm", "-D", "-C", "--defined-only"], ["nm", "-C", "--defined-only"]):
            try:
                out = subprocess.run(args + [path], capture_output=True, text=True, timeout=120).stdout
            except Exception:
                out = ""
            for line in out.splitlines():
                parts = line.split(" ", 2)
                if len(parts) == 3 and parts[1] in ("T", "t", "W", "i"):
                    try:
                        table.append((int(parts[0], 16), parts[2]))
                    except ValueError:
                        pass
            if table:
                break
        table.sort()
        _CACHE[path] = table
    lo, hi, best = 0, len(table) - 1, None
    while lo <= hi:
        mid = (lo + hi) // 2
        if table[mid][0] <= offset:
            best = table[mid]
            lo = mid + 1
        else:
            hi = mid - 1
    if best is None:
        return None
    return f"{best[1]} + 0x{offset - best[0]:x}"


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[2] == "--emu-libdir":
        pass
    main()