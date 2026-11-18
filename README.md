# RV32I 5-Stage Pipeline with a Coprocessor Interface (v2)

[![regression](https://github.com/SandyGowda-op/riscv-ai-accelerator/actions/workflows/regression.yml/badge.svg)](https://github.com/SandyGowda-op/riscv-ai-accelerator/actions/workflows/regression.yml)

A 5-stage in-order RISC-V pipeline (IF, ID, EX, MEM, WB) with full forwarding,
hazard detection and a custom-0 instruction interface for driving a
matrix accelerator. Every hazard fix has a directed test, and the key ones
have a **negative control**: the same test recompiled with the fix removed,
which must fail.

This is the CPU half of [NeuroCore](https://github.com/SandyGowda-op/neurocore).
Here the accelerator is replaced by a small behavioural model so the CPU can
be built and verified on its own.

> **v1 vs v2.** `v1.0-mmio` (tag) is the original design: no forwarding,
> NOPs inserted by hand, accelerator started by a store to address 0x1000.
> v2 (this branch) adds forwarding, hazard detection, a register-file bypass
> and custom instructions with hardware interlocks.

## Instruction set

| Group | Instructions |
|---|---|
| RV32I subset | `ADD`, `ADDI`, `LUI`, `LW`, `SW`, `BEQ` |
| custom-0 (opcode `0x0B`) | `FMAC_START` (funct3 0), `RELU` (1), `FMAC_READ` (2), `FMAC_SETDESC` (3) |

`FMAC_READ rd, rs1`: `rs1[5:0]` = result element, `rs1[6]` = read status
`{busy, error}`, `rs1[7]` = read the high 32 bits of the 64-bit result.
There is no hardware multiply, and no `SUB`/`SLT`/shift instructions yet.

## Pipeline

```
 IF ──► ID ──────────────► EX ──────► MEM ──────► WB
        │ branch resolve   │ ALU,       │ data mem,   │ write-back
        │ (BEQ in ID)      │ custom ops │ descriptor  │ (write-through
        │ hazard unit      │            │ window      │  to ID reads)
        └─ forwarding: EX/MEM, MEM/WB ─► EX and ─► ID (branch compare)
```

## Hazards handled, and how each is tested

| Hazard | Fix | Test | Negative control |
|---|---|---|---|
| ALU result used by the `BEQ` right behind it (branch resolves in ID) | 1-cycle stall | T2 | – |
| `FMAC_READ` result used by the `BEQ` right behind it | 1-cycle stall | T3 | – |
| Value written back 3 instructions earlier read stale from the register file | write-through bypass | T7 | `-DNO_RF_BYPASS` fails T7 |
| Second `FMAC_START` while a job runs (would be silently dropped) | stall `START` while busy | T1, H7 | – |
| `FMAC_READ` before the job finishes, or right behind a new `START` | stall until done | H1, H2 | – |
| Invalid descriptor must not hang, and error must be visible | status read via `rs1[6]` | T4 | – |
| Load-use | 1-cycle stall | system program | – |

## Results

Run in a clean checkout; passes on Icarus Verilog 12.0 and 14.0 (devel) (`sh scripts/run_all.sh`):

```
T1 hazard_directed_tb                                ok (PASS)
T2 hazard_directed_tb                                ok (PASS)
T3 hazard_directed_tb                                ok (PASS)
T4 hazard_directed_tb                                ok (PASS)
T7 distance-3 RAW (register-file bypass)             ok (PASS)
  neg. control: -DNO_RF_BYPASS                       ok (FAIL)
riscv_pipeline_tb H1-H9 (system program)             ok (PASS)
checks as expected: 7   mismatches: 0
```

These are directed tests plus negative controls, not a formal proof.
The accelerator model has a fixed 300-cycle latency, so cycle counts here say
nothing about real accelerator performance (see NeuroCore for that).

## Run it

```sh
sh scripts/run_all.sh                    # needs iverilog >= 12 and python3
DEFS="-DNC_TRACE" sh scripts/run_all.sh  # same, with per-cycle debug prints
```

Logs land in `build/`.

## Layout

```
rtl/                     pipeline RTL (riscv_pipeline.v is the top)
verification/tb/         hazard_directed_tb (T1-T4), rawd3_tb (T7), riscv_pipeline_tb (H1-H9)
verification/models/     accel_model.sv: behavioural stand-in for the accelerator
scripts/                 run_all.sh, program generators (gen_progs.py, gen_t7_prog.py)
mem files/               program and data images
legacy/                  unused v1 modules (alu.v, alu_control.v)
```

## Known limits

- Instruction subset only (no `SUB`, `SLT`, shifts, `JAL`, other branches).
- Memories load their contents with `$readmemh` in simulation only; a real
  build needs ROM/BRAM initialisation.
- `mmul_mem.v` (the v1 memory-mapped multiplier at 0x1000) is still wired in
  for backward compatibility.

## License

MIT
