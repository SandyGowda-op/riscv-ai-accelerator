
**RESULTS**

Pipeline Verification

The pipelined execution was verified using waveform analysis and cycle-accurate logs.

- Program Counter (PC) increments correctly by +4 every cycle
- Instructions propagate across IF → ID → EX → MEM → WB stages
- ALU outputs observed with expected pipeline latency

Example execution:

addi x1, x0, 5
addi x2, x0, 10
add  x3, x1, x2

Final register values:

x1 = 5
x2 = 10
x3 = 15


Hazard Demonstration

- RAW hazards observed in dependent instructions
- Resolved using NOP insertion (manual scheduling)
- Confirms correct pipeline timing behavior in absence of forwarding


AI Accelerator Verification

- Accelerator triggered via memory-mapped store instruction:

sw x2, 0(x1)   // x1 = 0x00001000

Observed behavior:

- "mmul_busy = 1" → pipeline stalls
- Matrix multiplication executed internally
- "mmul_done = 1" → CPU resumes execution


Static Timing Analysis (STA)

- Worst Negative Slack (WNS): +0.785 ns
- No timing violations
- Estimated maximum frequency (Fmax): ~450 MHz

All timing constraints successfully met on Artix-7 FPGA.
