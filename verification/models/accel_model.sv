//==============================================================================
// accel_model : BEHAVIOURAL stand-in for NeuroCore's accelerator_top.
//
// This is a test model, not hardware. It lets the CPU's coprocessor interface
// (FMAC_SETDESC / FMAC_START / FMAC_READ and their interlocks) be verified on
// its own, without the full accelerator. The real accelerator lives in the
// neurocore-accel / neurocore repositories.
//
// Contract it models (same ports and handshake as accelerator_top):
//   - run is accepted only when idle; a run while busy is silently dropped
//     (exactly the hazard the CPU's START-behind-START interlock prevents)
//   - desc_fetch_busy is high for FETCH_CYCLES after run (descriptor fetch)
//   - all_done pulses for one cycle LATENCY cycles after run
//   - any_error = "rows field of the selected descriptor is 0", cleared on run
//   - result_read_data_out returns golden element [index] (gold_arrays.svh)
//     once the job has finished, and a poison value before that, so reading
//     too early is visible in the tests
//==============================================================================
`timescale 1ns/1ps
`default_nettype none

module accelerator_top #(
    parameter int NUM_JOBS     = 2,
    parameter bit VERBOSE      = 1'b0,
    parameter int FETCH_CYCLES = 18,
    parameter int LATENCY      = 300
)(
    input  logic        clk,
    input  logic        rst,

    input  logic        run,
    input  logic [6:0]  job_index_in,
    output logic        all_done,
    output logic        any_error,

    input  logic        cpu_we,
    input  logic [6:0]  cpu_desc_idx,
    input  logic [2:0]  cpu_word_offset,
    input  logic [31:0] cpu_wdata,

    output logic               debug_dense_result_valid,
    output logic [15:0]        debug_dense_result_row,
    output logic [15:0]        debug_dense_result_col,
    output logic signed [63:0] debug_dense_result_data,
    output logic [31:0]        debug_dense_mac_count,
    output logic signed [63:0] debug_sparse_result [0:7][0:7],
    output logic [31:0]        debug_sparse_mac_count,

    input  logic [5:0]         result_read_index_in,
    output logic signed [63:0] result_read_data_out,

    output logic [6:0]  debug_current_job_index,
    output logic [1:0]  debug_job_status,
    output logic        desc_fetch_busy
);
    // golden results (same file the testbenches use)
    reg signed [63:0] exp_sp [0:63];
    reg signed [63:0] exp_de [0:63];
`include "gold_arrays.svh"

    // only the rows field matters to this model (for the invalid-descriptor test)
    logic [15:0] rows_of [0:127];
    always_ff @(posedge clk)
        if (cpu_we && cpu_word_offset == 3'd4) rows_of[cpu_desc_idx] <= cpu_wdata[31:16];

    logic        busy, have_result;
    logic [15:0] cnt;
    logic [6:0]  job;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; have_result <= 1'b0; cnt <= '0; job <= '0; any_error <= 1'b0;
        end else if (!busy && run) begin
            busy <= 1'b1; have_result <= 1'b0; cnt <= '0; job <= job_index_in;
            any_error <= 1'b0;
        end else if (busy) begin
            cnt <= cnt + 16'd1;
            if (cnt == LATENCY - 1) begin
                busy <= 1'b0;
                have_result <= 1'b1;
                any_error <= (rows_of[job] == 16'd0);
            end
        end
    end

    assign all_done        = busy && (cnt == LATENCY - 1);
    assign desc_fetch_busy = busy && (cnt < FETCH_CYCLES);
    assign result_read_data_out = have_result ? exp_sp[result_read_index_in]
                                              : 64'shBAD0_BAD0_BAD0_BAD0;

    assign debug_current_job_index  = job;
    assign debug_job_status         = busy ? 2'd1 : (any_error ? 2'd3 : 2'd2);
    assign debug_dense_result_valid = 1'b0;
    assign debug_dense_result_row   = '0;
    assign debug_dense_result_col   = '0;
    assign debug_dense_result_data  = '0;
    assign debug_dense_mac_count    = '0;
    assign debug_sparse_mac_count   = '0;
    always_comb
        for (int r = 0; r < 8; r++) for (int c = 0; c < 8; c++) debug_sparse_result[r][c] = '0;
endmodule

`default_nettype wire
