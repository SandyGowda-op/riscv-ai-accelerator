# riscv-ai-accelerator
Entry-level RTL project exploring AI acceleration through a 5-stage pipelined RISC-V processor integrated with a custom matrix multiplication (MMUL) accelerator.

This project focuses on the intersection of chip architecture and hardware acceleration, demonstrating how digital design can support AI workloads through efficient compute units and memory-mapped integration.



Highlights:-

- 5-stage pipeline: IF, ID, EX, MEM, WB
- RV32I support: ADDI, ADD, LUI, SW
- Memory-mapped AI accelerator at "0x00001000"
- Pipeline stall control using "mmul_busy"
- Verified using waveform + cycle-level logs
- Timing closure achieved on FPGA (STA)


