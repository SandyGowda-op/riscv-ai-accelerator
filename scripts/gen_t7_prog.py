#!/usr/bin/env python3
"""T7: distance-3 RAW (producer in WB while consumer is in ID). Usage: gen_t7_prog.py OUT.mem"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_swdesc_progs import NOP, ADDI
def R(op_f3, f7, rd, rs1, rs2): return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (op_f3 << 12) | (rd << 7) | 0x33
def ADD(rd, rs1, rs2): return R(0, 0, rd, rs1, rs2)
def BEQ(rs1, rs2, imm):
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (((imm >> 1) & 0xf) << 8) | (((imm >> 11) & 1) << 7) | 0x63
assert ADD(5, 2, 0) == 0x000102b3 and BEQ(11, 12, 8) == 0x00c58463
p  = [NOP] * 10
p += [ADDI(12, 0, 0x33), ADDI(8, 0, 5)] + [NOP] * 4              # preset x12, sentinel x8=5
p += [ADDI(2, 0, 0x11), ADDI(3, 0, 1), ADDI(4, 0, 2), ADD(5, 2, 0)]     # rs1 at distance 3 -> x5 = 0x11
p += [ADDI(10, 0, 0x22), ADDI(3, 0, 1), ADDI(4, 0, 2), ADD(6, 0, 10)]   # rs2 at distance 3 -> x6 = 0x22
p += [ADDI(11, 0, 0x33), ADDI(3, 0, 1), ADDI(4, 0, 2),                   # BEQ rs1 at distance 3, taken
      BEQ(11, 12, 8), ADDI(8, 0, 0)]                                      # skipped instr would clear sentinel
p += [NOP] * 8
open(sys.argv[1], "w").write("\n".join(f"{x & 0xffffffff:08x}" for x in p) + "\n")
print("wrote", sys.argv[1], len(p), "words")