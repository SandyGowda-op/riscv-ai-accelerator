#  RISC-V AI Accelerator  
### 5-Stage Pipelined RV32I Processor with Matrix Multiplication Unit



##  Overview

This project explores the intersection of *processor design and AI acceleration, implementing a **5-stage pipelined RISC-V (RV32I) CPU* integrated with a *custom matrix multiplication (MMUL) accelerator*.

It demonstrates how *hardware-level optimization* can accelerate compute-intensive workloads using a *memory-mapped accelerator architecture*.

---

##  Architecture

<img width="600" height="500" alt="image" src="https://github.com/user-attachments/assets/3f768f37-2684-4394-9da5-bfbfaa28f8d0" />



---

##  Pipeline Design

<img width="600" height="500" alt="image" src="https://github.com/user-attachments/assets/8e4a9b39-5d95-4c8c-a93c-2b790bc800c1" />



### Pipeline Stages

| Stage | Function |
|------|--------|
| IF   | Instruction Fetch |
| ID   | Decode + Register Read |
| EX   | ALU Execution |
| MEM  | Memory / Accelerator |
| WB   | Register Writeback |

 Enables instruction-level parallelism  
 Improves throughput  

---

##  Scgematic Diagram

<img width="600" height="500" alt="image" src="https://github.com/user-attachments/assets/06f9dbac-19cf-4c20-8555-8e95fb34c1a3" />



###  Memory Mapping


BASE ADDRESS: 0x00001000


###  Trigger Sequence

assembly
lui   x1, 0x1
addi  x2, x0, 1
sw    x2, 0(x1)


###  Execution Flow


CPU → Store → MMUL Triggered
        ↓
mmul_busy = 1 → Pipeline Stall
        ↓
Matrix Multiplication
        ↓
mmul_done = 1 → CPU Resume


---

##  Key Highlights

-  5-stage pipelined RISC-V CPU (RV32I)
-  Modular RTL design
-  Custom AI accelerator (Matrix Multiply)
-  Memory-mapped CPU–accelerator interface
-  Stall control using mmul_busy
-  Waveform + cycle-level verification
-  Timing closure achieved (STA clean)

---

##  Results & Verification

###  Pipeline Execution

- PC increments correctly:
  
  PC = PC + 4
  

- Instruction flow verified:
  
  IF → ID → EX → MEM → WB
  

- ALU outputs appear with correct latency

---

###  Functional Verification

assembly
addi x1, x0, 5
addi x2, x0, 10
add  x3, x1, x2


*Output:*

x1 = 5
x2 = 10
x3 = 15


 Correct ALU + writeback behavior  

---

###  Hazard Demonstration

*RAW Hazard:*
assembly
add x3, x1, x2


*Solution used:*
assembly
nop


Demonstrates pipeline timing awareness  

---

###  AI Accelerator Verification

Trigger:
assembly
sw x2, 0(x1)


Observed:

mmul_busy = 1 → CPU stalls
mmul_done = 1 → CPU resumes


 Correct CPU–accelerator interaction  

---

###  Matrix Multiplication Output


Matrix A: [...]
Matrix B: [...]
Matrix C: A × B

STATUS: PASS

Succesfully multiplied a 8X8 matrix, and verified the outputs.


---

###  Static Timing Analysis (STA)

| Metric | Value |
|------|------|
| WNS | +0.785 ns |
| Violations | 0 |
| Status | PASSED |

*Estimated Frequency:*

~400–450 MHz


---

##  Limitations

- No forwarding unit  
- No hazard detection logic  
- Requires NOP insertion  
- Blocking accelerator execution  

---

##  Future Work

- Forwarding unit  
- Hazard detection  
- Parallel MAC units  
- DMA support  
- Interrupt-based completion  
- AXI / SoC integration  

---

##  Tools & Platform

- Verilog  
- Xilinx Vivado  
- Artix-7 FPGA (xc7a200t)  

---

##  Author

*Sandesh*  
EEE Student | Aspiring RTL / VLSI Engineer  

---

##  Note

This project marks a strong foundation in *RTL design, processor architecture, and AI hardware acceleration*.


