// [quiet_trace] debug prints are opt-in: compile with -DNC_TRACE
`timescale 1ns/1ps

module riscv_pipeline (
    input wire clk,
    input  wire        rst,
    output wire mmul_busy,
    output wire mmul_done,
    output wire [31:0] dbg_pc,
    output wire [31:0] dbg_instr,
    output wire [31:0] dbg_alu,
    output wire [31:0] dbg_dmem_load,
    output wire [31:0] dbg_r1,
    output wire [31:0] dbg_r2,
    output wire [31:0] dbg_r3,
    output wire [31:0] dbg_r4,
    output wire [31:0] dbg_r5,
    output wire [31:0] dbg_r6,
    output wire [31:0] dbg_r7,
    output wire [31:0] dbg_r8,
    output wire [31:0] dbg_r9,
    output wire        dbg_accel_busy,

    // Descriptor authoring bus -> accelerator_top's descriptor memory.
    // Driven by the testbench (or later a CPU-side path); idle = desc_we 0.
    input  wire        desc_we,
    input  wire [6:0]  desc_idx,
    input  wire [2:0]  desc_word_off,
    input  wire [31:0] desc_wdata
);
    // ============================================================
    // Global datapath signals
    // ============================================================

    wire [31:0] exmem_alu;
    wire [4:0]  exmem_rd;
    wire        exmem_reg_write;
    wire        exmem_mem_read;
    wire [31:0] dmem_rdata;

    wire [4:0]  memwb_rd;
    wire        memwb_reg_write;
    wire mmul_result_valid;
    wire [31:0] branch_rs1_val; //BEQ CONTROL SIGNALS
    wire [31:0] branch_rs2_val; //BEQ CONTROL SIGNALS
    wire id_is_fmac; //CUSTOM ISA EXTENSION CONTROL SIGNALS
    wire id_is_relu; //CUSTOM ISA EXTENSION CONTROL SIGNALS
    wire id_is_fmac_read; //CUSTOM ISA EXTENSION CONTROL SIGNALS
    wire id_is_fmac_setdesc; //CUSTOM ISA EXTENSION CONTROL SIGNALS (funct3=011, writes descriptor_index_reg)
    reg  accel_done_reg;   // latched job-complete flag (driven in NEUROCORE INTEGRATION block)
    reg  accel_busy_reg;   // set when FMAC_START dispatches, cleared on all_done -- gates a 2nd START
    wire accel_fetching;   // accelerator_top is fetching a descriptor (store-vs-fetch guard)
    wire accelerator_any_error; // sticky error flag from accelerator_top (declared early: read by FMAC_READ status)
    wire accelerator_all_done; // all_done pass-through (driven in NEUROCORE INTEGRATION block)
    wire idex_is_fmac;     // FMAC_START currently in EX (assigned in EX-stage decode)
    wire [31:0] relu_result; //RELU RESULT WIRE
    wire [31:0] mmul_rdata; //MMUL RESULT READ DATA WIRE
    wire [31:0] mmul_result_direct; //DIRECT WIRE FROM MMUL TO EX STAGE FOR FMAC READS
    // ============================================================
    // HAZARD DETECTION WIRES
    // ============================================================
    wire pc_write;
    wire ifid_write;
    wire idex_flush;

    // ============================================================
    // MMIO HAZARD DETECTION WIRES
    // ============================================================
    wire final_pc_write;
    wire final_ifid_write;
    wire final_idex_flush;

    // ============================================================
    // PC wires instantiation
    // ============================================================
    reg [31:0] pc_reg;
    wire cpu_stall = 1'b0; //STALLING FOR HAZARD DETECTION

    // ============================================================
    // IF stage
    // ============================================================
    wire [31:0] instr_fetched;

    instr_mem instr_mem_inst (
        .addr (pc_reg),
        .instr(instr_fetched)
    );

    wire [31:0] ifid_pc_out;
    wire [31:0] ifid_instr_out;
    wire ifid_flush; //FLUSH SIGNAL FOR BEQ

    if_id if_id_inst (
        .clk(clk),
        .rst(rst),
        .enable(final_ifid_write),   // 🔒 STALL HERE
        .flush(ifid_flush),
        .pc_in(pc_reg),
        .instr_in(instr_fetched),
        .pc_out(ifid_pc_out),
        .instr_out(ifid_instr_out)
    );

    assign dbg_instr = ifid_instr_out;

    // ============================================================
    // ID stage
    // ============================================================
    wire [6:0] id_opcode = ifid_instr_out[6:0];
    wire [2:0] id_funct3 = ifid_instr_out[14:12];
    wire [4:0] id_rs1    = ifid_instr_out[19:15];
    wire [4:0] id_rs2    = ifid_instr_out[24:20];
    wire [4:0] id_rd     = ifid_instr_out[11:7];

    wire [31:0] rf_rs1_data, rf_rs2_data;

    wire wb_we;
    wire [4:0] wb_rd;
    wire [31:0] wb_data;

    register_file rf (
        .clk(clk),
        .rst(rst),
        .we_en(wb_we),
        .we_addr(wb_rd),
        .we_data(wb_data),
        .rs1_addr(id_rs1),
        .rs2_addr(id_rs2),
        .rs1_data(rf_rs1_data),
        .rs2_data(rf_rs2_data),
        .dbg_r1(dbg_r1),
        .dbg_r2(dbg_r2),
        .dbg_r3(dbg_r3),
        .dbg_r4(dbg_r4),
        .dbg_r5(dbg_r5),
        .dbg_r6(dbg_r6),
        .dbg_r7(dbg_r7),
        .dbg_r8(dbg_r8),
        .dbg_r9(dbg_r9)
    );

    // ============================================================
    // Immediate generator
    // ============================================================
    wire [31:0] id_imm;
    immediate_gen imm_gen (
        .instr(ifid_instr_out),
        .imm_out(id_imm)
    );

    // ============================================================
    // Control
    // ============================================================
    wire id_mem_read   = (id_opcode == 7'b0000011);
    wire id_mem_write  = (id_opcode == 7'b0100011);
    wire id_reg_write  = (id_opcode == 7'b0110011) |
                          (id_opcode == 7'b0010011) |
                          (id_opcode == 7'b0000011) |
                          (id_opcode == 7'b0110111) |
                     id_is_fmac |
                     id_is_relu|
                     id_is_fmac_read;

    wire id_mem_to_reg = (id_opcode == 7'b0000011);
    wire id_alu_src    = (id_opcode != 7'b0110011);
    wire id_branch = (id_opcode == 7'b1100011); //BEQ BRANCHING ADDED

    // ============================================================
    // CUSTOM ISA EXTENSION CONTROL SIGNALS
    // ============================================================

    assign id_is_fmac =
    (id_opcode == 7'b0001011) &&
    (id_funct3 == 3'b000);

    assign id_is_relu =
    (id_opcode == 7'b0001011) &&
    (id_funct3 == 3'b001);

    assign id_is_fmac_read =
    (id_opcode == 7'b0001011) &&
    (id_funct3 == 3'b010);

    assign id_is_fmac_setdesc =
    (id_opcode == 7'b0001011) &&
    (id_funct3 == 3'b011);

    //always @(*) begin

    //if (id_is_fmac)
    //    $display("CUSTOM ISA: FMAC DETECTED");

    //if (id_is_relu)
    //    $display("CUSTOM ISA: RELU DETECTED");

    //end
    // ============================================================
    // MMUL CONTROL SIGNALS
    // ============================================================
    wire [31:0] mmul_read_addr;
    wire reading_mmul_result;
    wire accel_raw_hazard;
    wire reading_fmac_result;

    assign reading_fmac_result =
    id_is_fmac_read;

    assign mmul_read_addr =
    branch_rs1_val + id_imm;

    assign reading_mmul_result =
    id_mem_read &&
    (mmul_read_addr == 32'h00001008);

    // reading_mmul_result (old MMIO poll @ 0x1008) still gates on
    // mmul_result_valid. reading_fmac_result (FMAC_READ) now gates on
    // accel_done_reg instead -- see NEUROCORE INTEGRATION block below --
    // since FMAC_START no longer drives the old mmul_mem accelerator.
    //
    // "|| idex_is_fmac": accel_done_reg only clears once FMAC_START reaches EX
    // (one cycle after it left ID). A FMAC_READ sitting in ID directly behind
    // that START would still see the PREVIOUS job's stale done=1 and sail
    // through, reading old results. While a START is in EX the new job is by
    // definition not done yet, so hold the read one more cycle; from then on
    // accel_done_reg itself is 0 and takes over.
    //
    // "id_is_fmac && accel_busy_reg": a second FMAC_START reaching EX while a
    // job is still running would have its `run` pulse silently dropped by
    // accelerator_top (it only accepts run in TOP_IDLE) instead of erroring
    // -- stall it in ID until accel_busy_reg clears on all_done, same
    // mechanism as the FMAC_READ RAW hazard above.
    assign accel_raw_hazard =
    (reading_mmul_result && !mmul_result_valid) ||
    (reading_fmac_result && (!accel_done_reg || idex_is_fmac)) ||
    (id_is_fmac && (accel_busy_reg || idex_is_fmac))
`ifndef NO_DESC_STORE_GUARD
    // a store behind START must not land while the DFU is still reading the descriptor
    || (id_mem_write && (idex_is_fmac || accel_fetching))
`endif
    ;

    `ifdef NC_TRACE
    always @(*) begin
    if (accel_raw_hazard)
        $display(
            "ACCEL RAW HAZARD DETECTED valid=%b fmacrd=%b mmio=%b",
            mmul_result_valid,
            reading_fmac_result,
            reading_mmul_result
        );

    end
    `endif

    // ============================================================
    // BEQ CONTROL SIGNALS
    // ============================================================
    assign branch_rs1_val =

    (exmem_mem_read &&
    (exmem_rd != 0) &&
    (exmem_rd == id_rs1))
    ? dmem_rdata :

    (exmem_reg_write &&
     (exmem_rd != 0) &&
     (exmem_rd == id_rs1))
        ? exmem_alu :

    (memwb_reg_write &&
     (memwb_rd != 0) &&
     (memwb_rd == id_rs1))
        ? wb_data :

    rf_rs1_data;

    assign branch_rs2_val =

    (exmem_mem_read &&
    (exmem_rd != 0) &&
    (exmem_rd == id_rs2))
    ? dmem_rdata :

    (exmem_reg_write &&
     (exmem_rd != 0) &&
     (exmem_rd == id_rs2))
        ? exmem_alu :

    (memwb_reg_write &&
     (memwb_rd != 0) &&
     (memwb_rd == id_rs2))
        ? wb_data :

    rf_rs2_data;
    wire branch_taken =
    id_branch && pc_write &&
    (branch_rs1_val == branch_rs2_val);
    wire [31:0] branch_target = //COMPUTE SIGNAL FOR BRANCH TARGET
    ifid_pc_out + id_imm;
    assign ifid_flush = //FLUSH SIGNAL FOR BEQ
    branch_taken && pc_write;

    `ifdef NC_TRACE
    always @(*) begin
    if (id_branch)
        $display(
            "BRANCH: pc_write=%b rs1=%h rs2=%h taken=%b",
            pc_write,
            branch_rs1_val,
            branch_rs2_val,
            branch_taken
        );
    end
    `endif

    `ifdef NC_TRACE
    always @(*) begin
    if (id_opcode == 7'b1100011)
        
        $display(
            "BEQ_DEBUG PC=%h IMM=%h TARGET=%h",
            ifid_pc_out,
            id_imm,
            branch_target
        );
    end
    `endif
    

    // ============================================================
    // FORWARDING WIRES (INSTANTIATION AT END)
    // ============================================================
    wire [1:0] forward_a;
    wire [1:0] forward_b;

    // ============================================================
    // ID / EX
    // ============================================================
    wire [31:0] idex_rs1, idex_rs2, idex_imm;
    wire [4:0]  idex_rs1_addr;
    wire [4:0]  idex_rs2_addr;
    wire [4:0]  idex_rd;
    wire [6:0]  idex_opcode;
    wire        idex_mem_read, idex_mem_write, idex_mem_to_reg, idex_reg_write, idex_alu_src;
    wire [2:0] idex_funct3;

    id_ex id_ex_inst (
        .clk(clk),
        .rst(rst),
        .flush(final_idex_flush),

        .pc_in(ifid_pc_out),
        .rs1_data_in(rf_rs1_data),
        .rs2_data_in(rf_rs2_data),
        .imm_in(id_imm),
        .rs1_in(id_rs1),
        .rs2_in(id_rs2),
        .rd_in(id_rd),
        .opcode_in(id_opcode),
        .funct3_in(id_funct3),

        .alu_src_in(id_alu_src),
        .mem_read_in(id_mem_read),
        .mem_write_in(id_mem_write),
        .mem_to_reg_in(id_mem_to_reg),
        .reg_write_in(id_reg_write),

        .pc_out(),
        .rs1_out(idex_rs1),
        .rs2_out(idex_rs2),
        .imm_out(idex_imm),
        .rs1_addr_out(idex_rs1_addr),
        .rs2_addr_out(idex_rs2_addr),
        .rd_out(idex_rd),
        .opcode_out(idex_opcode),
        .funct3_out(idex_funct3),
        .alu_src_out(idex_alu_src),
        .mem_read_out(idex_mem_read),
        .mem_write_out(idex_mem_write),
        .mem_to_reg_out(idex_mem_to_reg),
        .reg_write_out(idex_reg_write)
    );

    wire [31:0] forwarded_rs1; //FORWARDED REGISTER VALUES
    wire [31:0] forwarded_rs2;
    // ============================================================
    // EX stage (LUI FIX PRESERVED)(FORWARDING DONE)
    // ============================================================

    assign idex_is_fmac =           //relu ex stage
    (idex_opcode == 7'b0001011) &&
    (idex_funct3 == 3'b000);

    wire idex_is_relu =
    (idex_opcode == 7'b0001011) &&
    (idex_funct3 == 3'b001);      //relu ex stage end

    wire idex_is_fmac_read =
    (idex_opcode == 7'b0001011) &&
    (idex_funct3 == 3'b010);

    wire idex_is_fmac_setdesc =
    (idex_opcode == 7'b0001011) &&
    (idex_funct3 == 3'b011);

    assign forwarded_rs1 =
    (forward_a == 2'b10) ? exmem_alu :
    (forward_a == 2'b01) ? wb_data   :
                           idex_rs1;

    assign forwarded_rs2 =
    (forward_b == 2'b10) ? exmem_alu :
    (forward_b == 2'b01) ? wb_data   :
                           idex_rs2;

    // FMAC_READ element index: rs1[5:0] as a flat 8x8 index, same style as
    // FMAC_SETDESC's rs1[6:0] descriptor index. row=index[5:3], col=index[2:0]
    // (the row/col split itself happens inside scheduler_engine).
    wire [5:0] accel_read_index = forwarded_rs1[5:0];
    wire signed [63:0] accel_read_data;

    wire [31:0] alu_b = idex_alu_src ? idex_imm : forwarded_rs2;

    wire [31:0] normal_alu_result =
    (idex_opcode == 7'b0110111) ?
        idex_imm :
        (forwarded_rs1 + alu_b);

    wire [31:0] alu_result_ex =
    idex_is_relu ?
        relu_result :

    idex_is_fmac_read ?
        // KNOWN LIMITATION: accel_read_data is 64-bit (the accelerator's
        // MAC accumulators), truncated to the low 32 bits here because the
        // register file / writeback path is 32-bit. Fine for this test's
        // values (all well under 2^16) -- wrong for any real result that
        // doesn't fit in 32 bits. A real fix needs a wider read (e.g. a
        // second funct3 for the high half) -- out of scope for now, flagged
        // rather than silently truncated without comment.
        (forwarded_rs1[6] ? {30'b0, accel_busy_reg, accelerator_any_error}
                          : (forwarded_rs1[7] ? accel_read_data[63:32] : accel_read_data[31:0])) :

        normal_alu_result;
    assign dbg_alu = alu_result_ex;

    `ifdef NC_TRACE
    always @(*) begin
    if (idex_is_relu)
    
        $display(
            "RELU_EX rs1=%h result=%h",
            forwarded_rs1,
            relu_result
        );
end
`endif
`ifdef NC_TRACE
    always @(*) begin

    if (idex_is_fmac)
        $display("FMAC_START EXECUTING");

end
`endif 

    //=============================================================
    // RELU UNIT INSTANTIATION
    //=============================================================

    relu_unit relu_inst (
        .in_data(forwarded_rs1),
        .out_data(relu_result)
    );
    
    // ============================================================
    // EX / MEM
    // ============================================================
    
    wire [31:0] exmem_rs2;
    wire         exmem_mem_write, exmem_mem_to_reg;

    ex_mem ex_mem_inst (
        .clk(clk),
        .rst(rst),

        .alu_in(alu_result_ex),
`ifdef NO_STORE_FWD_FIX
        .rs2_data_in(idex_rs2),
`else
        .rs2_data_in(forwarded_rs2),
`endif
        .rd_in(idex_rd),
        .mem_read_in(idex_mem_read),
        .mem_write_in(idex_mem_write),
        .mem_to_reg_in(idex_mem_to_reg),
        .reg_write_in(idex_reg_write),

        .alu_out(exmem_alu),
        .rs2_data_out(exmem_rs2),
        .rd_out(exmem_rd),
        .mem_read_out(exmem_mem_read),
        .mem_write_out(exmem_mem_write),
        .mem_to_reg_out(exmem_mem_to_reg),
        .reg_write_out(exmem_reg_write)
    );
    `ifdef NC_TRACE
    always @(posedge clk) begin
    $display("EXMEM_CAPTURE alu_result_ex=%08h exmem_alu=%08h",
             alu_result_ex,
             exmem_alu);
    end
`endif
    // ============================================================
    // MEM stage + MMUL
    // ============================================================
    localparam MMUL_BASE = 32'h00001000;

    wire mmul_sel = (exmem_alu >= MMUL_BASE) &&
                    (exmem_alu <  MMUL_BASE + 32'h100);

    // CPU-authored descriptors: SW to 0x2000..0x2FFF -> descriptor memory
    wire desc_sel = exmem_mem_write && (exmem_alu[31:12] == 20'h00002);

    data_memory dmem (
        .clk(clk),
        .mem_read(exmem_mem_read & ~mmul_sel),
        .mem_write(exmem_mem_write & ~mmul_sel & ~desc_sel),
        .addr(exmem_alu),
        .write_data(exmem_rs2),
        .read_data(dmem_rdata)
    );

    //===================================================
    // MMUL INSTATIATION
    //===================================================

    //FMAC START PULSE GENERATION

    wire mmul_start_mmio;
    wire mmul_we;

    assign mmul_start_mmio =
    exmem_mem_write & mmul_sel;

    // FMAC_START no longer pokes mmul_mem (that's the redirect to
    // accelerator_top below), and FMAC_READ no longer reads its
    // mmul_result_direct output either -- it reads accelerator_top via the
    // indexed result_read port instead. mmul_mem stays instantiated only
    // for the legacy MMIO poke/peek path (mmul_rdata at the MMIO addresses);
    // mmul_result_direct is now a dead wire.
    assign mmul_we =
    mmul_start_mmio;

    mmul_mem mmul_inst (
        .clk(clk),
        .rst(rst),
        .addr(exmem_alu),
        .wdata(exmem_rs2),
        .mmul_result_valid(mmul_result_valid),
        .we(mmul_we),
        .mmul_busy(mmul_busy),
        .mmul_done(mmul_done),
        .rdata(mmul_rdata),
        .result_out(mmul_result_direct)
    );

    assign dbg_accel_busy = mmul_busy;

    //===================================================
    // NEUROCORE INTEGRATION -- FMAC_SETDESC / FMAC_START
    // dispatch into accelerator_top
    //===================================================
    // ASSUMPTION FLAGGED: width hardcoded to 7 bits here to match
    // "writes rs1[6:0] into descriptor_index_reg". Verify this against
    // descriptor_pkg::DESC_INDEX_WIDTH before running against the real
    // package -- if it differs, widen/narrow this and job_index_in together.
    localparam DESC_INDEX_WIDTH_LOCAL = 7;

    reg [DESC_INDEX_WIDTH_LOCAL-1:0] descriptor_index_reg;

    always @(posedge clk or posedge rst) begin
        if (rst)
            descriptor_index_reg <= {DESC_INDEX_WIDTH_LOCAL{1'b0}};
        else if (idex_is_fmac_setdesc)
            descriptor_index_reg <= forwarded_rs1[DESC_INDEX_WIDTH_LOCAL-1:0];
    end

    `ifdef NC_TRACE
    always @(*) begin
    if (idex_is_fmac_setdesc)
        $display(
            "FMAC_SETDESC EXECUTING desc_idx=%0d",
            forwarded_rs1[DESC_INDEX_WIDTH_LOCAL-1:0]
        );
    end
    `endif

    // accel_done_reg: latched job-complete flag for accelerator_top, kept
    // separate from mmul_result_valid (which still gates the old MMIO
    // polling read). Set on accelerator_top's one-cycle all_done pulse,
    // cleared the next time FMAC_START dispatches a new job -- so a stale
    // "done" from a previous job can never unblock a FMAC_READ for a job
    // that hasn't actually finished yet.
    wire accelerator_run;

    assign accelerator_run = idex_is_fmac;

    always @(posedge clk or posedge rst) begin
        if (rst)
            accel_done_reg <= 1'b0;
        else if (idex_is_fmac)
            accel_done_reg <= 1'b0;
        else if (accelerator_all_done)
            accel_done_reg <= 1'b1;
    end

    // accel_busy_reg: set the moment FMAC_START dispatches (EX), cleared on
    // all_done. accelerator_top only accepts `run` while it's in TOP_IDLE --
    // a second FMAC_START reaching EX mid-job would silently be dropped
    // instead of erroring, so it's stalled in ID (accel_raw_hazard above)
    // for as long as this is set, same mechanism FMAC_READ already uses.
    always @(posedge clk or posedge rst) begin
        if (rst)
            accel_busy_reg <= 1'b0;
        else if (idex_is_fmac)
            accel_busy_reg <= 1'b1;
        else if (accelerator_all_done)
            accel_busy_reg <= 1'b0;
    end

    // Descriptor preload comes in on the desc_* top-level ports (driven by
    // the testbench) -- the CPU itself doesn't author descriptors yet. This
    // milestone covers FMAC_SETDESC + FMAC_START dispatch, plus FMAC_READ via the indexed
    // result_read_index_in/result_read_data_out pass-through (see
    // scheduler_engine.sv for why that exists instead of the debug array/
    // stream ports below). debug_* outputs
    // are left unconnected -- FMAC_READ doesn't need them anymore, and
    // debug_sparse_result specifically would hit the Icarus 2D-unpacked-
    // array-port bug if read from this far up the hierarchy.
    accelerator_top #(
        .NUM_JOBS (2),
        .VERBOSE  (1'b0)
    ) u_accelerator_top (
        .clk (clk),
        .rst (rst),

        .run          (accelerator_run),
        .job_index_in (descriptor_index_reg),
        .all_done     (accelerator_all_done),
        .any_error    (accelerator_any_error),

        .cpu_we          (desc_we | desc_sel),
        .cpu_desc_idx    (desc_sel ? exmem_alu[11:5] : desc_idx),
        .cpu_word_offset (desc_sel ? exmem_alu[4:2]  : desc_word_off),
        .cpu_wdata       (desc_sel ? exmem_rs2       : desc_wdata),
        .desc_fetch_busy (accel_fetching),

        .debug_dense_result_valid (),
        .debug_dense_result_row   (),
        .debug_dense_result_col   (),
        .debug_dense_result_data  (),
        .debug_dense_mac_count    (),

        .debug_sparse_result    (),
        .debug_sparse_mac_count (),

        .result_read_index_in (accel_read_index),
        .result_read_data_out (accel_read_data),

        .debug_current_job_index (),
        .debug_job_status        ()
    );

    wire [31:0] mem_rdata =
    mmul_sel ? mmul_rdata :
               dmem_rdata;
    assign dbg_dmem_load = mem_rdata;

    // ============================================================
    // MEM / WB
    // ============================================================
    wire [31:0] memwb_mem;
    wire [31:0] memwb_alu;
    wire        memwb_mem_to_reg;

    mem_wb mem_wb_inst (
        .clk(clk),
        .rst(rst),
        .enable(!cpu_stall),

        .mem_data_in(mem_rdata),
        .alu_result_in(exmem_alu),
        .rd_in(exmem_rd),
        .mem_to_reg_in(exmem_mem_to_reg),
        .reg_write_in(exmem_reg_write),

        .mem_data_out(memwb_mem),
        .alu_result_out(memwb_alu),
        .rd_out(memwb_rd),
        .mem_to_reg_out(memwb_mem_to_reg),
        .reg_write_out(memwb_reg_write)
    );

    assign wb_we   = memwb_reg_write;
    assign wb_rd   = memwb_rd;
    assign wb_data = memwb_mem_to_reg ? memwb_mem : memwb_alu;

    // ============================================================
    // FORWARDING STAGE
    // ============================================================  

    forwarding_unit forwarding_unit_inst (

    .idex_rs1(idex_rs1_addr),
    .idex_rs2(idex_rs2_addr),

    .exmem_rd(exmem_rd),
    .exmem_reg_write(exmem_reg_write),

    .memwb_rd(memwb_rd),
    .memwb_reg_write(memwb_reg_write),

    .forward_a(forward_a),
    .forward_b(forward_b)

    );

    // ============================================================
    // HAZARD DETECTION (STALLING FOR LOAD-USE HAZARD)
    // ============================================================  
    hazard_detection_unit hazard_unit (

    .ifid_rs1(id_rs1),
    .ifid_rs2(id_rs2),

    .idex_rd(idex_rd),
    .idex_mem_read(idex_mem_read),

    .ifid_branch(id_branch),
    .idex_reg_write(idex_reg_write),

    .pc_write(pc_write),
    .ifid_write(ifid_write),
    .idex_flush(idex_flush)

    );
    // ============================================================
    // PC WORKING SHIFTED FOR SYNTAX PURPOSES
    // ============================================================  
    always @(posedge clk or posedge rst) begin
    if (rst)
        pc_reg <= 32'd0;

    else if (final_pc_write) begin

        if (branch_taken)
            pc_reg <= branch_target;
        else
            pc_reg <= pc_reg + 32'd4;

    end
end

    assign dbg_pc = pc_reg;

    // ============================================================
    // MMIO HAZARD DETECTION LOGIC
    // ============================================================
    assign final_pc_write =
    pc_write & ~accel_raw_hazard;

    assign final_ifid_write =
    ifid_write & ~accel_raw_hazard;

    assign final_idex_flush =
    idex_flush | accel_raw_hazard;

endmodule