// ---------------------------------------------------------------------------
// scanner_axi.v - scanner_top + sig_source, with an AXI4-Lite interface.
//
// What it takes to get the scanner into the KV260's PL and talk to it from
// Linux. No DMA: to VALIDATE the design in silicon, registers are enough.
//
//   sig_source  generates the stimulus INSIDE the PL, at clock rate. This is
//               variant (a) of METODOLOGIA.md: the samples are born in the PL
//               and the generator is separate hardware that does not steal a
//               single cycle from the DDC. On a CPU, generating costs half the
//               time; here, nothing.
//   scanner_top the N channels.
//   AXI4-Lite   configuration and power readout.
//
// The sample and output counters are the proof that nothing gets lost: at
// 100 MSPS, smp_cnt has to advance exactly one step per cycle with the
// generator running, and out_cnt one per CIC_R samples. If the PL dropped a
// single sample, the relation would stop adding up.
//
// ONE SINGLE CLOCK DOMAIN. The AXI and the scanner run off the same `clk`,
// which will be the PS pl_clk0 (100 MHz by default). There is no domain
// crossing to reason about, and 100 MHz fits comfortably inside the 170 MHz
// the design closes at.
//
// REGISTER MAP (byte offsets)
//
//   0x00  ID        RO  0x5CA44E64, to check the bitstream is this one
//   0x04  CTRL      RW  [0] run (scanner active-low reset)
//                       [1] src_en      generator running
//                       [2] noise_en    add LFSR noise
//                       [3] clear       pulse: reset the accumulators
//   0x08  SRC_FTWA  RW  frequency tuning word of the generator's tone A
//   0x0C  SRC_FTWB  RW  same for tone B
//   0x10  SRC_SH    RW  [3:0] shift_a  [7:4] shift_b  [11:8] shift_n
//   0x14  CFG_CH    RW  channel the next tuning write goes to
//   0x18  CFG_FTW   RW  writing here loads the tuning into channel CFG_CH
//   0x1C  PWR_LEN   RW  samples per power measurement window
//   0x20  RD_CH     RW  channel whose power is read
//   0x24  PWR_LO    RO  power of channel RD_CH, bits 31:0
//   0x28  PWR_HI    RO  bits 47:32
//   0x2C  READY     RO  pwr_ready, one bit per channel (up to 32)
//   0x30  SMP_LO    RO  samples fed into the scanner, bits 31:0
//   0x34  SMP_HI    RO  bits 63:32
//   0x38  OUT_CNT   RO  outputs produced by channel 0
//   0x3C  NCH       RO  number of channels synthesised
//   0x40  TAP_I     RO  last I sample of channel RD_CH (signed, 18 b)
//   0x44  TAP_Q     RO  last Q sample
//   0x48  TAP_CNT   RO  how many I/Q samples that channel has emitted
//   0x4C  STATUS    RO  [0] fold_overrun   [5:1] FOLD synthesised
//
// The TAPs are no good for dumping data -- they change at 1.5 MSPS and
// AXI-Lite cannot keep up -- but they are good for seeing that there is
// activity and that the values are sensible. Continuous dumping is what will
// call for a DMA, later on.
// ---------------------------------------------------------------------------

`default_nettype none

module scanner_axi #(
    parameter integer N_CH       = 16,
    parameter integer IN_W       = 16,
    parameter integer OUT_W      = 18,
    parameter integer PHASE_W    = 32,
    parameter integer LUT_ADDR_W = 10,
    parameter integer LUT_W      = 16,
    parameter integer MIX_W      = 18,
    parameter integer CIC_N      = 3,
    parameter integer CIC_R      = 64,
    parameter integer CIC_W      = 36,
    parameter integer CIC_GROWTH = 18,
    parameter integer PWR_W      = 48,
    parameter integer UNITS_PER_BANK = 32,
    parameter integer FOLD       = 1,
    parameter         LUT_FILE   = "sin_lut.mem",
    parameter integer C_S_AXI_ADDR_WIDTH = 7      // 128 bytes = 32 registers
) (
    // --- AXI4-Lite slave, same clock as the scanner ------------------------
    input  wire                                 s_axi_aclk,
    input  wire                                 s_axi_aresetn,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_awaddr,
    input  wire [2:0]                           s_axi_awprot,
    input  wire                                 s_axi_awvalid,
    output reg                                  s_axi_awready,

    input  wire [31:0]                          s_axi_wdata,
    input  wire [3:0]                           s_axi_wstrb,
    input  wire                                 s_axi_wvalid,
    output reg                                  s_axi_wready,

    output reg  [1:0]                           s_axi_bresp,
    output reg                                  s_axi_bvalid,
    input  wire                                 s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_araddr,
    input  wire [2:0]                           s_axi_arprot,
    input  wire                                 s_axi_arvalid,
    output reg                                  s_axi_arready,

    output reg  [31:0]                          s_axi_rdata,
    output reg  [1:0]                           s_axi_rresp,
    output reg                                  s_axi_rvalid,
    input  wire                                 s_axi_rready
);

    localparam [31:0] MAGIC_ID = 32'h5CA4_4E64;
    localparam integer CH_W = (N_CH > 1) ? $clog2(N_CH) : 1;

    wire clk   = s_axi_aclk;
    wire rst_n = s_axi_aresetn;

    // ---- Write registers ---------------------------------------------------
    reg        r_run, r_src_en, r_noise_en;
    reg [31:0] r_ftw_a, r_ftw_b;
    reg [11:0] r_shift;
    reg [31:0] r_cfg_ch, r_cfg_ftw, r_pwr_len, r_rd_ch;
    reg        r_cfg_we, r_clear;      // one-cycle pulses

    // ---- Generator inside the PL -------------------------------------------
    wire                    src_valid;
    wire signed [IN_W-1:0]  src_data;

    sig_source #(
        .OUT_W (IN_W), .PHASE_W (PHASE_W), .LUT_ADDR_W (LUT_ADDR_W),
        .LUT_W (LUT_W), .LUT_FILE (LUT_FILE)
    ) u_src (
        .clk (clk), .rst_n (rst_n && r_run), .en (r_src_en),
        .ftw_a (r_ftw_a), .ftw_b (r_ftw_b),
        .shift_a (r_shift[3:0]), .shift_b (r_shift[7:4]),
        .shift_n (r_shift[11:8]), .noise_en (r_noise_en),
        .out_valid (src_valid), .out_data (src_data)
    );

    // ---- The scanner -------------------------------------------------------
    wire [PWR_W-1:0]        rd_pwr;
    wire [N_CH-1:0]         pwr_ready;
    wire                    tap_valid;
    wire signed [OUT_W-1:0] tap_i, tap_q;
    wire                    fold_overrun;

    scanner_top #(
        .N_CH (N_CH), .IN_W (IN_W), .OUT_W (OUT_W), .PHASE_W (PHASE_W),
        .LUT_ADDR_W (LUT_ADDR_W), .LUT_W (LUT_W), .MIX_W (MIX_W),
        .CIC_N (CIC_N), .CIC_R (CIC_R), .CIC_W (CIC_W),
        .CIC_GROWTH (CIC_GROWTH), .PWR_W (PWR_W),
        .UNITS_PER_BANK (UNITS_PER_BANK), .FOLD (FOLD), .LUT_FILE (LUT_FILE)
    ) u_scan (
        .clk (clk), .rst_n (rst_n && r_run),
        .in_valid (src_valid), .in_data (src_data),
        .cfg_we (r_cfg_we), .cfg_ch (r_cfg_ch[CH_W-1:0]),
        .cfg_ftw (r_cfg_ftw), .cfg_pwr_len (r_pwr_len), .cfg_clear (r_clear),
        .rd_ch (r_rd_ch[CH_W-1:0]), .rd_pwr (rd_pwr), .pwr_ready (pwr_ready),
        .tap_ch (r_rd_ch[CH_W-1:0]), .tap_valid (tap_valid),
        .tap_i (tap_i), .tap_q (tap_q), .fold_overrun (fold_overrun)
    );

    // ---- Counters: the proof that not one sample is lost -------------------
    reg [63:0] smp_cnt;
    reg [31:0] out_cnt;
    reg signed [OUT_W-1:0] tap_i_r, tap_q_r;

    always @(posedge clk) begin
        if (!rst_n || !r_run || r_clear) begin
            smp_cnt <= 64'd0;
            out_cnt <= 32'd0;
            tap_i_r <= {OUT_W{1'b0}};
            tap_q_r <= {OUT_W{1'b0}};
        end else begin
            if (src_valid)  smp_cnt <= smp_cnt + 64'd1;
            if (tap_valid) begin
                out_cnt <= out_cnt + 32'd1;
                // The selected channel's last sample is frozen here, so it can
                // be inspected over AXI without needing a DMA.
                tap_i_r <= tap_i;
                tap_q_r <= tap_q;
            end
        end
    end

    // ---- AXI4-Lite: write --------------------------------------------------
    reg [C_S_AXI_ADDR_WIDTH-1:0] waddr;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            waddr         <= {C_S_AXI_ADDR_WIDTH{1'b0}};

            r_run      <= 1'b0;
            r_src_en   <= 1'b0;
            r_noise_en <= 1'b0;
            r_ftw_a    <= 32'h1999_999A;   // 10 MHz at 100 MSPS
            r_ftw_b    <= 32'h2666_6666;   // 15 MHz at 100 MSPS
            r_shift    <= 12'h022;         // both tones at 1/4: the sum will not saturate
            r_cfg_ch   <= 32'd0;
            r_cfg_ftw  <= 32'd0;
            r_pwr_len  <= 32'd1024;
            r_rd_ch    <= 32'd0;
            r_cfg_we   <= 1'b0;
            r_clear    <= 1'b0;
        end else begin
            r_cfg_we <= 1'b0;            // single-cycle pulses
            r_clear  <= 1'b0;

            // Address and data arrive together: they are accepted together.
            if (!s_axi_awready && s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid) begin
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
                waddr         <= s_axi_awaddr;
            end else begin
                s_axi_awready <= 1'b0;
                s_axi_wready  <= 1'b0;
            end

            if (s_axi_awready && s_axi_wready) begin
                case (waddr[C_S_AXI_ADDR_WIDTH-1:2])
                    5'h01: begin                       // CTRL
                        r_run      <= s_axi_wdata[0];
                        r_src_en   <= s_axi_wdata[1];
                        r_noise_en <= s_axi_wdata[2];
                        r_clear    <= s_axi_wdata[3];
                    end
                    5'h02: r_ftw_a   <= s_axi_wdata;
                    5'h03: r_ftw_b   <= s_axi_wdata;
                    5'h04: r_shift   <= s_axi_wdata[11:0];
                    5'h05: r_cfg_ch  <= s_axi_wdata;
                    5'h06: begin                       // CFG_FTW: load and fire
                        r_cfg_ftw <= s_axi_wdata;
                        r_cfg_we  <= 1'b1;
                    end
                    5'h07: r_pwr_len <= s_axi_wdata;
                    5'h08: r_rd_ch   <= s_axi_wdata;
                    default: ;                        // RO or unused
                endcase
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;                // OKAY
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ---- AXI4-Lite: read ---------------------------------------------------
    reg [C_S_AXI_ADDR_WIDTH-1:0] raddr;
    reg [31:0] rmux;

    // pwr_ready may be narrower than 32 bits: it gets zero-padded. This goes
    // through a generate because a replication of width ZERO is illegal in
    // Verilog, and with N_CH >= 32 that is what would come out.
    wire [31:0] ready_ext;
    generate
        if (N_CH >= 32) assign ready_ext = pwr_ready[31:0];
        else            assign ready_ext = {{(32-N_CH){1'b0}}, pwr_ready};
    endgenerate

    always @(*) begin
        case (raddr[C_S_AXI_ADDR_WIDTH-1:2])
            5'h00: rmux = MAGIC_ID;
            5'h01: rmux = {28'd0, r_clear, r_noise_en, r_src_en, r_run};
            5'h02: rmux = r_ftw_a;
            5'h03: rmux = r_ftw_b;
            5'h04: rmux = {20'd0, r_shift};
            5'h05: rmux = r_cfg_ch;
            5'h06: rmux = r_cfg_ftw;
            5'h07: rmux = r_pwr_len;
            5'h08: rmux = r_rd_ch;
            5'h09: rmux = rd_pwr[31:0];
            5'h0A: rmux = {{(32 - (PWR_W - 32)){1'b0}}, rd_pwr[PWR_W-1:32]};
            5'h0B: rmux = ready_ext;
            5'h0C: rmux = smp_cnt[31:0];
            5'h0D: rmux = smp_cnt[63:32];
            5'h0E: rmux = out_cnt;
            5'h0F: rmux = N_CH;
            5'h10: rmux = {{(32-OUT_W){tap_i_r[OUT_W-1]}}, tap_i_r};
            5'h11: rmux = {{(32-OUT_W){tap_q_r[OUT_W-1]}}, tap_q_r};
            5'h12: rmux = out_cnt;
            // STATUS. The overflow bit matters more than its size suggests:
            // with folding, feeding faster than Fs = Fclk/FOLD drops samples
            // and the output still looks like a signal. Without this bit, that
            // loss is invisible from software.
            5'h13: rmux = {26'd0, FOLD[4:0], fold_overrun};
            default: rmux = 32'd0;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= 32'd0;
            raddr         <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (!s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                raddr         <= s_axi_araddr;
            end else begin
                s_axi_arready <= 1'b0;
            end

            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;                // OKAY
                s_axi_rdata  <= rmux;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
