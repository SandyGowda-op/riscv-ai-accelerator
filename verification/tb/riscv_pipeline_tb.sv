//==============================================================================
// Testbench : riscv_pipeline_tb  -- top-to-bottom system test
//
//   instruction_memory.mem  ->  riscv_pipeline (CPU)  ->  FMAC_SETDESC /
//   FMAC_START / FMAC_READ  ->  accelerator_top  ->  sparse + dense subsystems
//   (private memories loaded from sparse_data_memory.mem / dense_data_memory.mem)
//
// The tb only (a) loads the two descriptors over the desc_* bus, (b) releases
// reset and (c) observes. All matrix data reaches the checks through the CPU's
// own FMAC_READ -> register-file writeback path.
//
// Checks
//   H1  FMAC_READ stalls until the job is actually done (retire time > all_done
//       time, and the PC visibly freezes)
//   H2  FMAC_READ directly behind FMAC_START does not read the PREVIOUS job's
//       stale results (job 1, element 0 must be 1, not 3460)
//   H3  ADDI -> FMAC_SETDESC / FMAC_READ operand forwarding (right job, right
//       element, 128 times)
//   H4  FMAC_READ result forwarded straight into an ADD
//   H5  exactly two accelerator all_done pulses (no spurious/dropped dispatch)
//   H6  all 64 elements of the sparse AND dense result matrices read back
//       through the CPU path match golden
//==============================================================================
`timescale 1ns/1ps

module riscv_pipeline_tb;

    localparam time CLK_PERIOD = 10ns;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(CLK_PERIOD/2) clk = ~clk;

    // descriptor bus
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

    // ---------------------------------------------------------------- golden
    reg signed [63:0] exp_sp [0:63];
    reg signed [63:0] exp_de [0:63];
`include "gold_arrays.svh"


    // ------------------------------------------------------ descriptor loader
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

    // ------------------------------------------------------------- monitors
    integer cyc = 0;
    integer done_pulses = 0;
    integer run_pulses = 0;
    time    t_done [0:3];
    time    t_run  [0:3];
    time    t_x10 = 0, t_x14 = 0;
    integer sweep_n = 0;
    reg signed [63:0] sweep [0:127];
    integer freeze = 0, max_freeze0 = 0, max_freeze1 = 0;
    time    t_x21 = 0, t_x22 = 0;
    reg [31:0] last_pc = 32'hFFFF_FFFF;

    always @(posedge clk) if (!rst) begin
        cyc <= cyc + 1;

        // PC freeze tracker -- gated on done_pulses BEFORE it's incremented
        // below, so the boundary cycle (all_done fires this same cycle) is
        // attributed to the phase that was ending, not the one that's about
        // to start. Getting this order backwards silently carries the tail
        // of one phase's stall length into the next phase's max.
        if (dbg_pc === last_pc) begin
            freeze = freeze + 1;
            if (done_pulses == 0 && freeze > max_freeze0) max_freeze0 = freeze;
            if (done_pulses == 1 && freeze > max_freeze1) max_freeze1 = freeze;
        end else freeze = 0;
        last_pc = dbg_pc;

        if (dut.accelerator_all_done) begin
            if (done_pulses < 4) t_done[done_pulses] = $time;
            done_pulses = done_pulses + 1;
        end
        // H7/H8 measured directly off accelerator_run (hierarchical ref),
        // not inferred from PC-freeze bucketing -- a run pulse either
        // happens when expected or it doesn't; no phase-boundary guessing.
        if (dut.accelerator_run) begin
            if (run_pulses < 4) t_run[run_pulses] = $time;
            run_pulses = run_pulses + 1;
        end
        // register writebacks of interest (values as they retire)
        if (dut.wb_we && dut.wb_rd == 5'd10 && t_x10 == 0) t_x10 = $time;
        if (dut.wb_we && dut.wb_rd == 5'd14 && t_x14 == 0) t_x14 = $time;
        if (dut.wb_we && dut.wb_rd == 5'd21 && t_x21 == 0) t_x21 = $time;
        if (dut.wb_we && dut.wb_rd == 5'd22 && t_x22 == 0) t_x22 = $time;
        if (dut.wb_we && dut.wb_rd == 5'd20 && sweep_n < 128) begin
            sweep[sweep_n] = $signed(dut.wb_data);
            sweep_n = sweep_n + 1;
        end
    end

    // ---------------------------------------------------------------- main
    integer errs = 0, i, sp_bad, de_bad;

    task automatic check(input [639:0] name, input integer got, input integer exp);
        begin
            if (got !== exp) begin
                errs = errs + 1;
                $display("  [FAIL] %0s : got %0d, expected %0d", name, got, exp);
            end else
                $display("  [ OK ] %0s = %0d", name, got);
        end
    endtask

    initial begin
        $display("============================================================");
        $display("  RISC-V + ACCELERATOR  TOP-TO-BOTTOM RUN");
        $display("============================================================");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        // CPU is now running the NOP preamble; load descriptors meanwhile.
        //        idx  srcA        srcB        meta        dst         rows   cols   k      sA     sB     sC     bpe   flags
        load_descriptor(0, 32'h1000_0000, 32'h1000_0100, 32'h1000_0200, 32'h1000_0300,
                        16'd8, 16'd8, 16'd8, 16'd32, 16'd32, 16'd32, 8'd4, 8'b0000_0001); // sparse
        load_descriptor(1, 32'h1000_0000, 32'h1000_0100, 32'h0000_0000, 32'h1000_0200,
                        16'd8, 16'd8, 16'd8, 16'd32, 16'd32, 16'd32, 8'd4, 8'b0000_0000); // dense
        $display("  descriptors loaded at cycle %0d (program still in NOP preamble)", cyc);

        wait (t_x22 != 0);   // last thing the program writes -- run to true completion
        repeat (8) @(posedge clk);

        $display("");
        $display("  ---- directed hazard / forwarding cases ----");
        check("H1/H3 x10 sparse C[0]  (first read, stalled)", dut.rf.regs[10], exp_sp[0]);
        check("     x11 sparse C[9]", dut.rf.regs[11], exp_sp[9]);
        check("     x12 sparse C[63]", dut.rf.regs[12], exp_sp[63]);
        check("H4    x13 = x12 + x10 (FMAC_READ -> ADD forward)", dut.rf.regs[13], exp_sp[63] + exp_sp[0]);
        check("H2    x14 dense C[0] right behind START (stale would be job0's C[0], not this)", dut.rf.regs[14], exp_de[0]);
        check("     x15 dense C[63]", dut.rf.regs[15], exp_de[63]);
        check("     x16 dense C[10]", dut.rf.regs[16], exp_de[10]);

        $display("");
        $display("  ---- timing ----");
        check("H8 accelerator all_done pulses (2 orig + 2 re-dispatch)", done_pulses, 4);
        check("H8 accelerator run   pulses (2 orig + 2 re-dispatch)", run_pulses, 4);
        check("H7    x21 job1 2nd-run C[5]  (proves 2nd START wasn\'t dropped)", dut.rf.regs[21], exp_de[5]);
        check("      x22 job1 2nd-run C[63]", dut.rf.regs[22], exp_de[63]);
        if (t_x10 <= t_done[0]) begin errs = errs + 1;
            $display("  [FAIL] H1 first FMAC_READ retired at %0d ns, BEFORE job 0 done at %0d ns", t_x10, t_done[0]);
        end else
            $display("  [ OK ] H1 first FMAC_READ retired %0d ns after job 0 done (done at %0d ns)", t_x10 - t_done[0], t_done[0]);
        if (t_x14 <= t_done[1]) begin errs = errs + 1;
            $display("  [FAIL] H2 race FMAC_READ retired at %0d ns, BEFORE job 1 done at %0d ns", t_x14, t_done[1]);
        end else
            $display("  [ OK ] H2 race FMAC_READ retired %0d ns after job 1 done", t_x14 - t_done[1]);
        if (max_freeze0 < 100 || max_freeze1 < 100) begin errs = errs + 1;
            $display("  [FAIL] H1 expected long PC freezes; got %0d (job0) / %0d (job1) cycles", max_freeze0, max_freeze1);
        end else
            $display("  [ OK ] H1 PC frozen %0d cycles waiting on sparse job, %0d on dense job", max_freeze0, max_freeze1);
        // A weak/dropped busy-stall shows up as a SHORT freeze here (the
        // START falls through immediately instead of waiting) or as a
        // TIMEOUT further down (job1 2nd run never dispatches at all).
        // H7, the real check: the 4th run pulse (job1's 2nd dispatch) must
        // not fire before the 3rd all_done (job0's 2nd run finishing). If
        // the busy-stall is missing/broken, t_run[3] lands right after
        // t_run[2] instead (a handful of cycles for addi+setdesc), i.e.
        // long before job0's 2nd run is actually done.
        if (t_run[3] < t_done[2]) begin errs = errs + 1;
            $display("  [FAIL] H7 job1 2nd START fired at %0d ns, BEFORE job0 2nd run done at %0d ns -- not stalled", t_run[3], t_done[2]);
        end else
            $display("  [ OK ] H7 job1 2nd START held until job0 2nd run done (fired %0d ns after, at %0d ns)", t_run[3]-t_done[2], t_run[3]);

        $display("");
        $display("  ---- full 64-element matrices read back through FMAC_READ ----");
        sp_bad = 0; de_bad = 0;
        for (i = 0; i < 64; i = i + 1) begin
            if (sweep[i]      !== exp_sp[i]) begin sp_bad = sp_bad + 1; if (sp_bad <= 3) $display("  [FAIL] sparse[%0d] got %0d exp %0d", i, sweep[i], exp_sp[i]); end
            if (sweep[64 + i] !== exp_de[i]) begin de_bad = de_bad + 1; if (de_bad <= 3) $display("  [FAIL] dense [%0d] got %0d exp %0d", i, sweep[64+i], exp_de[i]); end
        end
        $display("  H6 sparse 8x8 : %0d/64 match golden", 64 - sp_bad);
        $display("  H6 dense  8x8 : %0d/64 match golden", 64 - de_bad);
        errs = errs + sp_bad + de_bad;

        $display("");
        $display("  ---- H9: sparse-vs-dense equivalence ----");
        // job0 (sparse) and job1 (dense) now share one coordinated A x B
        // (Option A: main_memory_model only has ONE valid address window
        // per subsystem, so a separate equivalence job isn't possible).
        // sweep[0:63] is job0's sparse sweep, sweep[64:127] is job1's
        // dense sweep, both already captured by the H6 sweep logic above
        // -- equivalence falls out for free, no new dispatch needed.
        begin : h9_block
            integer j, x_bad;
            x_bad = 0;
            for (j = 0; j < 64; j = j + 1) begin
                if (sweep[j] !== sweep[64+j]) begin
                    x_bad = x_bad + 1;
                    if (x_bad <= 3) $display("  [FAIL] H9 sparse!=dense[%0d] sparse=%0d dense=%0d", j, sweep[j], sweep[64+j]);
                end
            end
            $display("  H9 sparse vs dense : %0d/64 identical (both already verified vs golden by H6)", 64 - x_bad);
            errs = errs + x_bad;
        end

        $display("");
        $display("  total cycles: %0d", cyc);
        $display("============================================================");
        if (errs == 0) $display("  TOP-TO-BOTTOM RUN : PASS");
        else           $display("  TOP-TO-BOTTOM RUN : FAIL (%0d)", errs);
        $display("============================================================");
        $finish;
    end

    initial begin
        #3000000;
        $display("[FAIL] TIMEOUT  pc=%08h sweep_n=%0d done_pulses=%0d", dbg_pc, sweep_n, done_pulses);
        $finish;
    end
endmodule