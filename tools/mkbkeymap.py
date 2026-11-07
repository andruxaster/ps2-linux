#!/usr/bin/env python3
"""Таблицы раскладки из `loadkeys -u --mktable` → двоичная раскладка busybox loadkmap.

`loadkeys -b` не умеет Unicode-символы вроде кириллицы, а ядро хранит их
в таблицах как есть (код < 0xf000). Поэтому берём числовые таблицы, которые
печатает --mktable, и пишем формат bkeymap: "bkeymap", 256 байт флагов
(1 — таблица есть), затем по 128 значений uint16 (little-endian) на таблицу.

    loadkeys -u --mktable ru.kmap | mkbkeymap.py > ru.bmap
"""
import re
import struct
import sys

NR_KEYS = 128          # столько читает busybox loadkmap
MAX_NR_KEYMAPS = 256

src = sys.stdin.read()

maps = {}
for m in re.finditer(r"unsigned short (\w+)\[NR_KEYS\] = \{(.*?)\};", src, re.S):
    maps[m.group(1)] = [int(v, 16) for v in re.findall(r"0x[0-9a-fA-F]+", m.group(2))]

order = re.search(r"key_maps\[MAX_NR_KEYMAPS\] = \{(.*?)\};", src, re.S)
if not order or not maps:
    sys.exit("mkbkeymap: не похоже на вывод loadkeys --mktable")
names = [n.strip() for n in order.group(1).split(",")]

flags = bytearray(MAX_NR_KEYMAPS)
body = bytearray()
for i, name in enumerate(names[:MAX_NR_KEYMAPS]):
    if name in maps:
        vals = (maps[name] + [0xf200] * NR_KEYS)[:NR_KEYS]   # 0xf200 = K_HOLE
        flags[i] = 1
        body += struct.pack("<%dH" % NR_KEYS, *vals)

sys.stdout.buffer.write(b"bkeymap" + bytes(flags) + bytes(body))
