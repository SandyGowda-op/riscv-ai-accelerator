#!/usr/bin/env python3
"""Tiny assembler for the NeuroCore directed hazard tests.
Emits progs/tN.mem (one 32-bit hex word per line, padded to 352 words like the
existing instruction_memory.mem). Supported: ADDI, BEQ, NOP and the custom-0 ops.
"""
import os, sys
OUT = sys.argv[1] if len(sys.argv) > 1 else "progs"   # output folder (optional arg)
NOP = 0x00000013
def addi(rd, rs1, imm): return ((imm & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13
def beq(rs1, rs2, off):
    o = off & 0x1FFF
    return (((o >> 12) & 1) << 31) | (((o >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0 << 12) | (((o >> 1) & 0xF) << 8) | (((o >> 11) & 1) << 7) | 0x63
def custom(f3, rd, rs1, rs2=0): return (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x0B
def start():            return custom(0b000, 0, 0)
def setdesc(rs1):       return custom(0b011, 0, rs1)
def fmac_read(rd, rs1): return custom(0b010, rd, rs1)
HALT = beq(0, 0, 0)
PRE  = [NOP] * 64          # descriptors are loaded by the tb during this window
def nops(n): return [NOP] * n
END  = [addi(31, 0, 1)] + nops(6) + [HALT]    # x31 = 1 is the "program finished" marker

progs = {}
# T1: START directly behind START (same descriptor). Invariant checked by the tb:
#     accelerator_run pulses == all_done pulses (a dropped run = lost job).
progs[1] = PRE + [addi(1,0,0), setdesc(1), start(), start(), addi(2,0,0), fmac_read(10,2)] + END

# T2: ALU result consumed by the BEQ directly behind it.
#   case A: x1 changes 7->9, BEQ(x1,x2=7) must NOT be taken (stale x1=7 would take it)
#   case B: x1 changes 9->7, BEQ(x1,x2=7) must be taken    (stale x1=9 would not)
progs[2] = PRE + [addi(2,0,7), addi(1,0,7), addi(8,0,5)] + nops(4) + [
    addi(1,0,9), beq(1,2,8), addi(7,0,1), NOP,          # expect x7 == 1 (not taken)
    addi(1,0,7), beq(1,2,8), addi(8,0,1), NOP,          # expect x8 == 5 (sentinel kept: skipped)
] + END

# T3: FMAC_READ result consumed by the BEQ directly behind it (C[0] = -14 for the sparse job).
progs[3] = PRE + [addi(5,0,5), addi(1,0,0), addi(2,0,0), addi(6,0,-14), setdesc(1), start(),
                  fmac_read(4,2), beq(4,6,8), addi(5,0,1), NOP] + END   # expect x5 == 5 (sentinel kept: skipped)

# T4: invalid descriptor (rows = 0, descriptor 2) must not hang, must report error,
#     and the accelerator must recover for a good job afterwards.
#     FMAC_READ with rs1[6]=1 returns the status word {busy, error}.
progs[4] = PRE + [addi(4,0,0x55), addi(5,0,0x55), addi(10,0,0x55),
                  addi(3,0,64), addi(1,0,2), setdesc(1), start(),
                  fmac_read(4,3),                         # x4 expect 1 (error, not busy)
                  addi(1,0,0), setdesc(1), start(),       # good sparse job
                  fmac_read(5,3),                         # x5 expect 0 (error cleared by new run)
                  addi(2,0,0), fmac_read(10,2)] + END     # x10 expect exp_sp[0]

# T5: 64-bit result read as two 32-bit halves: FMAC_READ idx (low) and idx+128 (high), sparse then dense job.
#     Element index comes from env HI_IDX (default 43). x4/x5 = sparse low/high, x6/x7 = dense low/high.
HI = int(os.environ.get("HI_IDX", "43"))
progs[5] = PRE + [addi(1,0,0), setdesc(1), start(), addi(2,0,HI), addi(3,0,HI+128), fmac_read(4,2), fmac_read(5,3),
                  addi(1,0,1), setdesc(1), start(), fmac_read(6,2), fmac_read(7,3)] + END

os.makedirs(OUT, exist_ok=True)
for n, p in sorted(progs.items()):
    assert len(p) <= 352, (n, len(p))
    p = p + [NOP] * (352 - len(p))
    with open(os.path.join(OUT, f"t{n}.mem"), "w") as f:
        f.write("\n".join(f"{w & 0xFFFFFFFF:08x}" for w in p) + "\n")
    print(f"t{n}.mem  ({len([w for w in p if w != NOP])} non-NOP words)")