#!/usr/bin/env python3
"""Programs for swdesc_tb (T6). Word-per-line hex, 40-NOP preamble (TB preloads desc 0 meanwhile).
  t6a   : CPU authors desc 4 (sparse, window 0 data) with 8 SW; operands ready early (no forwarding dependence)
  t6b   : CPU authors desc 5 with ADDI/LUI -> SW back-to-back (EX/MEM and MEM/WB store-data forwarding)
  t6c<w>: START (desc 0, TB-preloaded) immediately followed by a SW that corrupts descriptor word <w>
Usage: gen_swdesc_progs.py OUTDIR"""
import sys, os
NOP = 0x13
def I(op, rd, rs1, imm, f3=0): return ((imm & 0xfff) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def ADDI(rd, rs1, imm): return I(0x13, rd, rs1, imm)
def LUI(rd, imm20):     return ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x37
def SW(rs2, rs1, imm):  return (((imm >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | ((imm & 0x1f) << 7) | 0x23
def CUST(f3, rd, rs1): return 0x0B | (rd << 7) | (f3 << 12) | (rs1 << 15)
START = CUST(0, 0, 0)
def SETDESC(rs1): return CUST(3, 0, rs1)
def READ(rd, rs1): return CUST(2, rd, rs1)
assert SETDESC(1) == 0x0000b00b and START == 0x0000000b and READ(10, 2) == 0x0001250b and ADDI(1,0,0) == 0x93

def pre(): return [NOP] * 40
def reads(rd0=20):
    p = []
    for k, idx in enumerate([0, 9, 63]):
        p += [ADDI(12, 0, idx), READ(rd0 + k, 12)]
    p += [ADDI(12, 0, 0x40), READ(rd0 + 3, 12)]       # status {busy,error}
    return p + [NOP] * 4

def t6a():
    p = pre() + [LUI(1, 2), ADDI(1, 1, 0x80)]                       # x1 = desc 4 base 0x2080
    for r, off in [(2, 0), (3, 0x100), (4, 0x200), (5, 0x300)]:
        p += [LUI(r, 0x10000), ADDI(r, r, off)] if off else [LUI(r, 0x10000)]
    p += [LUI(6, 0x80), ADDI(6, 6, 8), LUI(7, 0x80), ADDI(7, 7, 0x20), LUI(8, 0x200), ADDI(8, 8, 0x20), ADDI(9, 0, 0x401)]
    p += [NOP] * 4
    p += [SW(2,1,0), SW(3,1,4), SW(4,1,8), SW(5,1,12), SW(6,1,16), SW(7,1,20), SW(8,1,24), SW(9,1,28)]
    p += [ADDI(11, 0, 4), SETDESC(11), START]
    return p + reads(20)

def t6b():
    p = pre() + [LUI(1, 2), ADDI(1, 1, 0xA0)]                       # x1 = desc 5 base 0x20A0
    p += [LUI(2, 0x10000), SW(2,1,0)]                                # LUI -> SW   (EX/MEM fwd)
    p += [ADDI(2,2,0x100), ADDI(3,0,0), SW(2,1,4)]                   # ADDI, 1 gap, SW (MEM/WB fwd)
    p += [ADDI(2,2,0x100), SW(2,1,8)]
    p += [ADDI(2,2,0x100), SW(2,1,12)]
    p += [LUI(2,0x80), ADDI(2,2,8), SW(2,1,16)]
    p += [ADDI(2,2,0x18), SW(2,1,20)]
    p += [LUI(2,0x200), ADDI(2,2,0x20), SW(2,1,24)]
    p += [ADDI(2,0,0x401), SW(2,1,28)]
    p += [ADDI(11, 0, 5), SETDESC(11), START]
    return p + reads(20)

def t6c(w):
    bad_reg = 9 if w in (0, 1, 2) else 0                              # 0x1000_0400 (zeros region) or x0 (rows/k = 0)
    p = pre() + [LUI(1, 2), LUI(9, 0x10000), ADDI(9, 9, 0x400), ADDI(7, 0, 0)] + [NOP] * 4
    p += [SETDESC(7), START, SW(bad_reg, 1, w * 4)]                  # SW directly behind START
    p += [ADDI(8, 0, 0), READ(10, 8), ADDI(15, 0, 9), READ(11, 15), ADDI(14, 0, 0x40), READ(13, 14)]
    return p + [NOP] * 4

if __name__ == "__main__":
    out = sys.argv[1]; os.makedirs(out, exist_ok=True)
    progs = {"t6a": t6a(), "t6b": t6b()}
    for w in (0, 1, 2, 4, 5): progs[f"t6c{w}"] = t6c(w)
    for n, p in progs.items():
        open(os.path.join(out, n + ".mem"), "w").write("\n".join(f"{x & 0xffffffff:08x}" for x in p) + "\n")
    print("wrote", ", ".join(progs))
