//==============================================================================
// rawd3_tb : T7 -- distance-3 RAW through the register file (no bypass = stale read)
//   x5 = ADD x2,x0 (rs1 d3) -> 0x11 ; x6 = ADD x0,x10 (rs2 d3) -> 0x22 ; BEQ d3 taken -> x8 stays 5
//==============================================================================
`timescale 1ns/1ps
module rawd3_tb;
    reg clk = 0, rst = 1; always #5 clk = ~clk;
    wire mmul_busy, mmul_done, dbg_accel_busy;
    wire [31:0] dbg_pc, dbg_instr, dbg_alu, dbg_dmem_load;
    wire [31:0] r1, r2, r3, r4, r5, r6, r7, r8, r9;
    riscv_pipeline dut (.clk(clk), .rst(rst), .mmul_busy(mmul_busy), .mmul_done(mmul_done),
        .dbg_pc(dbg_pc), .dbg_instr(dbg_instr), .dbg_alu(dbg_alu), .dbg_dmem_load(dbg_dmem_load),
        .dbg_r1(r1), .dbg_r2(r2), .dbg_r3(r3), .dbg_r4(r4), .dbg_r5(r5), .dbg_r6(r6), .dbg_r7(r7),
        .dbg_r8(r8), .dbg_r9(r9), .dbg_accel_busy(dbg_accel_busy),
        .desc_we(1'b0), .desc_idx(7'd0), .desc_word_off(3'd0), .desc_wdata(32'd0));
    integer errs = 0;
    task automatic chk(input [255:0] what, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("  [FAIL] %0s got %0h exp %0h", what, got, exp); end
        else $display("  [ OK ] %0s = %0h", what, got);
    endtask
    initial begin
        repeat (4) @(posedge clk); rst = 0; repeat (120) @(posedge clk);
        chk("x5 (rs1 RAW d3)", dut.rf.regs[5], 32'h11);
        chk("x6 (rs2 RAW d3)", dut.rf.regs[6], 32'h22);
        chk("x8 (BEQ d3 taken skips clear)", dut.rf.regs[8], 32'd5);
        if (errs == 0) $display("T7 RESULT: PASS"); else $display("T7 RESULT: FAIL (%0d)", errs);
        $finish;
    end
endmodule