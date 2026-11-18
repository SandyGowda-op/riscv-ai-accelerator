// [quiet_trace] debug prints are opt-in: compile with -DNC_TRACE
module hazard_detection_unit (

    input  wire [4:0] ifid_rs1,
    input  wire [4:0] ifid_rs2,

    input  wire [4:0] idex_rd,
    input  wire       idex_mem_read,

    input wire ifid_branch,
    input wire idex_reg_write,

    output reg        pc_write,
    output reg        ifid_write,
    output reg        idex_flush

);
wire branch_load_hazard;

always @(*) begin

    // Default: normal execution
    pc_write   = 1'b1;
    ifid_write = 1'b1;
    idex_flush = 1'b0;
`ifdef NC_TRACE
    $display(
"HZD: mem_read=%b idex_rd=%0d ifid_rs1=%0d ifid_rs2=%0d stall=%b",
idex_mem_read,
idex_rd,
ifid_rs1,
ifid_rs2,
(idex_mem_read &&
 (idex_rd != 0) &&
 ((idex_rd == ifid_rs1) ||
  (idex_rd == ifid_rs2)))
);
`endif 
    // Load-use hazard detection
    if (idex_mem_read &&
        (idex_rd != 0) &&
        ((idex_rd == ifid_rs1) ||
         (idex_rd == ifid_rs2))) begin

        pc_write   = 1'b0;
        ifid_write = 1'b0;
        idex_flush = 1'b1;
    end

    // Branch-after-producer hazard: BEQ resolves in ID, but ID-stage
    // forwarding only sees EX/MEM and MEM/WB. A BEQ directly behind an
    // instruction that writes its source register would compare the stale
    // register-file value. Stall one cycle so the producer reaches MEM and
    // is forwarded from exmem_alu. pc_write low also suppresses the
    // pipeline's branch_taken (it includes pc_write) for the stalled cycle.
    if (ifid_branch &&
        idex_reg_write &&
        (idex_rd != 0) &&
        ((idex_rd == ifid_rs1) ||
         (idex_rd == ifid_rs2))) begin

        pc_write   = 1'b0;
        ifid_write = 1'b0;
        idex_flush = 1'b1;
    end
end

endmodule