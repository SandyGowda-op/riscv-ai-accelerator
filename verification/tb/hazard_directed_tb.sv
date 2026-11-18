//==============================================================================
// hazard_directed_tb : four directed tests for the CPU<->accelerator coupling
//   +TEST=1  START directly behind START   (run pulses must equal all_done pulses)
//   +TEST=2  ALU result -> BEQ directly behind it (taken / not-taken, both ways)
//   +TEST=3  FMAC_READ result -> BEQ directly behind it
//   +TEST=4  invalid descriptor (rows=0): no hang, error visible via status read,
//            and a good job afterwards still runs correctly
// The program for each test is progs/tN.mem (copy it over instruction_memory.mem
// before simulating -- run_directed.sh does this).
//==============================================================================
`timescale 1ns/1ps
module hazard_directed_tb;
    localparam time CLK_PERIOD = 10ns;
    reg clk = 1'b0, rst = 1'b1;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg         desc_we = 1'b0;
    reg  [6:0]  desc_idx = 7'd0;
    reg  [2:0]  desc_word_off = 3'd0;
    reg  [31:0] desc_wdata = 32'd0;

    wire        mmul_busy, mmul_done, dbg_accel_busy;
    wire [31:0] dbg_pc, dbg_instr, dbg_alu, dbg_dmem_load;
    wire [31:0] dbg_r1, dbg_r2, dbg_r3, dbg_r4, dbg_r5, dbg_r6, dbg_r7, dbg_r8, dbg_r9;

    riscv_pipeline dut (
        .clk(clk), .rst(rst),
        .mmul_busy(mmul_busy), .mmul_done(mmul_done),
        .dbg_pc(dbg_pc), .dbg_instr(dbg_instr), .dbg_alu(dbg_alu),
        .dbg_dmem_load(dbg_dmem_load),
        .dbg_r1(dbg_r1), .dbg_r2(dbg_r2), .dbg_r3(dbg_r3), .dbg_r4(dbg_r4),
        .dbg_r5(dbg_r5), .dbg_r6(dbg_r6), .dbg_r7(dbg_r7), .dbg_r8(dbg_r8),
        .dbg_r9(dbg_r9), .dbg_accel_busy(dbg_accel_busy),
        .desc_we(desc_we), .desc_idx(desc_idx),
        .desc_word_off(desc_word_off), .desc_wdata(desc_wdata)
    );

    reg signed [63:0] exp_sp [0:63];
    reg signed [63:0] exp_de [0:63];
`include "gold_arrays.svh"

    task automatic write_word(input [6:0] idx, input [2:0] off, input [31:0] data);
        begin
            @(posedge clk);
            desc_we <= 1'b1; desc_idx <= idx; desc_word_off <= off; desc_wdata <= data;
            @(posedge clk);
            desc_we <= 1'b0;
        end
    endtask

    task automatic load_descriptor(
        input [6:0] idx, input [31:0] srcA, srcB, meta, dst,
        input [15:0] rows, cols, k, strideA, strideB, strideC,
        input [7:0] bpe, flag_bits);
        begin
            write_word(idx, 3'd0, srcA);
            write_word(idx, 3'd1, srcB);
            write_word(idx, 3'd2, meta);
            write_word(idx, 3'd3, dst);
            write_word(idx, 3'd4, {rows, cols});
            write_word(idx, 3'd5, {k, strideA});
            write_word(idx, 3'd6, {strideB, strideC});
            write_word(idx, 3'd7, {16'd0, bpe, flag_bits});
        end
    endtask

    integer hi_idx = 43;
    integer run_pulses = 0, done_pulses = 0, cyc = 0, errs = 0, test = 0;
    always @(posedge clk) if (!rst) begin
        cyc <= cyc + 1;
        if (dut.accelerator_run)      run_pulses  = run_pulses  + 1;
        if (dut.accelerator_all_done) done_pulses = done_pulses + 1;
    end

    task automatic check(input [511:0] name, input integer got, input integer exp);
        begin
            if (got === exp) $display("  PASS  %0s  (%0d)", name, got);
            else begin $display("  FAIL  %0s  got %0d expected %0d", name, got, exp); errs = errs + 1; end
        end
    endtask

    initial begin
        if (!$value$plusargs("TEST=%d", test)) test = 1;
        if (!$value$plusargs("IDX=%d", hi_idx)) hi_idx = 43;
        $display("==== hazard_directed_tb  TEST=%0d ====", test);
        repeat (4) @(posedge clk);
        rst = 1'b0;
        // 0 sparse, 1 dense (same as riscv_pipeline_tb), 2 = INVALID (rows = 0)
        load_descriptor(0, 32'h1000_0000, 32'h1000_0100, 32'h1000_0200, 32'h1000_0300,
                        16'd8, 16'd8, 16'd8, 16'd32, 16'd32, 16'd32, 8'd4, 8'b0000_0001);
        load_descriptor(1, 32'h1000_0000, 32'h1000_0100, 32'h0000_0000, 32'h1000_0200,
                        16'd8, 16'd8, 16'd8, 16'd32, 16'd32, 16'd32, 8'd4, 8'b0000_0000);
        load_descriptor(2, 32'h1000_0000, 32'h1000_0100, 32'h1000_0200, 32'h1000_0300,
                        16'd0, 16'd8, 16'd8, 16'd32, 16'd32, 16'd32, 8'd4, 8'b0000_0001);

        // program end marker (x31 = 1) or watchdog
        fork
            begin wait (dut.rf.regs[31] == 32'd1); end
            begin repeat (20000) @(posedge clk); $display("  FAIL  TIMEOUT -- program never finished (hang)"); errs = errs + 1; end
        join_any
        disable fork;
        repeat (8) @(posedge clk);

        case (test)
        1: begin
            check("T1 run pulses == all_done pulses", run_pulses, done_pulses);
            check("T1 two jobs dispatched",            run_pulses, 2);
            check("T1 x10 = sparse C[0]",              dut.rf.regs[10], exp_sp[0]);
        end
        2: begin
            check("T2a ALU->BEQ not-taken case: x7 executed", dut.rf.regs[7], 1);
            check("T2b ALU->BEQ taken case: x8 skipped (sentinel 5 kept)", dut.rf.regs[8], 5);
        end
        3: begin
            check("T3 FMAC_READ->BEQ taken: x5 skipped (sentinel 5 kept)", dut.rf.regs[5], 5);
            check("T3 x4 = sparse C[0]",                 dut.rf.regs[4], exp_sp[0]);
        end
        4: begin
            check("T4 status after bad descriptor (error=1,busy=0)", dut.rf.regs[4], 1);
            check("T4 status after good job (error cleared)",        dut.rf.regs[5], 0);
            check("T4 good job result still correct x10",            dut.rf.regs[10], exp_sp[0]);
            check("T4 two all_done pulses (bad job still completes)", done_pulses, 2);
        end
        5: begin
            if ({dut.rf.regs[5], dut.rf.regs[4]} === exp_sp[hi_idx])
                $display("  PASS  T5 sparse {high,low} == golden C[%0d] (%0d)", hi_idx, $signed(exp_sp[hi_idx]));
            else begin errs = errs + 1;
                $display("  FAIL  T5 sparse C[%0d] got %0d expected %0d", hi_idx, $signed({dut.rf.regs[5], dut.rf.regs[4]}), $signed(exp_sp[hi_idx])); end
            if ({dut.rf.regs[7], dut.rf.regs[6]} === exp_de[hi_idx])
                $display("  PASS  T5 dense  {high,low} == golden C[%0d] (%0d)", hi_idx, $signed(exp_de[hi_idx]));
            else begin errs = errs + 1;
                $display("  FAIL  T5 dense  C[%0d] got %0d expected %0d", hi_idx, $signed({dut.rf.regs[7], dut.rf.regs[6]}), $signed(exp_de[hi_idx])); end
        end
        endcase
        $display("==== TEST %0d : %0s (%0d errors) ====", test, errs == 0 ? "PASS" : "FAIL", errs);
        $finish;
    end
endmodule