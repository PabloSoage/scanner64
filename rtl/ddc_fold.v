// ---------------------------------------------------------------------------
// ddc_fold.v - One set of NCO, mixer and integrators for FOLD channels.
//
// THE IDEA
//
// The integrators process one sample per clock cycle. If the clock runs faster
// than the data, that set sits idle most of the time:
//
//     channels per set = floor(Fclk / Fs)
//
// At a 100 MHz clock and a 25 MSPS antenna, three cycles out of four are
// spare. Folded, a single set serves four channels and the area per channel is
// divided by four. It is the trade neither a CPU nor a GPU can offer: here you
// exchange bandwidth for channels, and the choice belongs to whoever
// integrates the thing.
//
// And it attacks exactly the limiting resource. Measured in the N_CH sweep:
// BRAM runs out first (~143 channels) because every channel takes a whole tile
// for its sine ROM. Folded, FOLD channels share ONE ROM.
//
// HOW THE PIPELINE HAZARD IS AVOIDED
//
// The danger in multiplexing a recursive filter is reading one channel's state
// before the state from its previous turn has been written. That cannot happen
// here, by construction:
//
//   - The phase is read AND written in stage 0, on the same cycle.
//   - The CIC state is read AND written in the last stage, on the same cycle.
//
// In between, the pipeline only CARRIES the slot number along. No state is
// ever in flight between its read and its write, so FOLD can be any value >= 1
// with no forwarding needed.
//
//     stage 0   slot s: ROM address from phase[s], phase[s] += ftw[s]
//     stage 1   sine and cosine come out (the ROM is registered)
//     stage 2   the mixer product
//     stage 3   shift and saturation
//     stage 4   slot s integrators, and decimation
//
// WHY THE STATE STAYS IN FLIP-FLOPS, AND NOT FOR LACK OF TRYING
//
// It is 216 bits per channel, nearly half of all the registers in the design,
// so it was worth trying to get them out. Tried and measured, with FOLD=16:
//
//                          LUT      FF
//   registers (this)     2,593   4,747
//   with a clear sweep  12,289   4,654     <- worse on every count
//
// Distributed RAM inference needs a simple pattern: one read address, one
// write address. The CIC cascade reads THREE different positions of the array
// on the same cycle -- acc[k] and acc[k-1] of every stage -- and with that
// Vivado gives up on inference. Replacing the parallel reset with a clearing
// sweep only made things worse: every position then had to choose between
// cleared, updated or held, with TWO address sources, and that decoder
// multiplied the LUTs by five without removing a single register.
//
// For it to pay off, the cascade would have to go to one stage per cycle,
// which leaves one read and one write and IS inferable. But that multiplies
// the round by CIC_N: every sample would cost FOLD*CIC_N cycles and the
// folding arithmetic would become Fs <= Fclk/(FOLD*3), which eats a good part
// of the benefit. Not worth it.
//
// THE RESET DOES CLEAR HERE, UNLIKE comb_bank
//
// comb_bank leaves its state unreset on purpose, so it lives in LUTRAM instead
// of in 7001 flip-flops. Here the opposite choice is made, and it is worth
// saying why: the state is about 1100 bits with FOLD=4, which saves nothing,
// and the alternative already cost us an afternoon -- the first outputs after
// a warm reset were garbage and the design was not. Correctness ahead of a
// saving that does not exist.
// ---------------------------------------------------------------------------

`default_nettype none

module ddc_fold #(
    parameter integer FOLD       = 4,       // channels per set
    parameter integer IN_W       = 16,
    parameter integer PHASE_W    = 32,
    parameter integer LUT_ADDR_W = 10,
    parameter integer LUT_W      = 16,
    parameter integer MIX_W      = 18,
    parameter integer CIC_N      = 3,
    parameter integer CIC_R      = 64,
    parameter integer CIC_W      = 36,
    parameter         LUT_FILE   = "sin_lut.mem",
    // Derived from FOLD, but it has to live in the parameter list: a body
    // localparam cannot be used in the port list.
    parameter integer SLOT_W     = (FOLD > 1) ? $clog2(FOLD) : 1
) (
    input  wire                      clk,
    input  wire                      rst_n,

    // Tuning, one per slot.
    input  wire                      cfg_we,
    input  wire [SLOT_W-1:0]         cfg_slot,
    input  wire [PHASE_W-1:0]        cfg_ftw,

    // One sample every FOLD cycles at most: that is how long the round takes.
    input  wire                      in_valid,
    input  wire signed [IN_W-1:0]    in_data,
    output wire                      ready,      // can take another sample

    // Decimated output, with the slot it belongs to.
    output reg                       out_valid,
    output reg  [SLOT_W-1:0]         out_slot,
    output reg  signed [CIC_W-1:0]   tap_i,
    output reg  signed [CIC_W-1:0]   tap_q,

    // Sticks high if a sample arrives while the previous round is still in
    // progress. Folding REQUIRES Fs <= Fclk/FOLD; fed any faster it drops
    // samples, and it would do so silently. A decimated output with missing
    // samples still looks like a signal, so the only way to find out is for
    // the hardware itself to say so.
    output reg                       overrun
);

    localparam integer CNT_W   = $clog2(CIC_R);
    localparam integer QUARTER = 1 << (LUT_ADDR_W - 2);
    localparam integer DEPTH   = 1 << LUT_ADDR_W;

    // ---- The ROM the FOLD slots share --------------------------------------
    (* rom_style = "block" *)
    reg signed [LUT_W-1:0] lut [0:DEPTH-1];
    initial $readmemh(LUT_FILE, lut);

    // ---- Per-slot state ----------------------------------------------------
    reg [PHASE_W-1:0] phase [0:FOLD-1];
    reg [PHASE_W-1:0] ftw   [0:FOLD-1];
    reg [CNT_W-1:0]   cnt   [0:FOLD-1];
    // Flattened: [slot*CIC_N + stage]
    reg signed [CIC_W-1:0] acc_i [0:FOLD*CIC_N-1];
    reg signed [CIC_W-1:0] acc_q [0:FOLD*CIC_N-1];

    integer k;

    // ---- Round control -----------------------------------------------------
    reg               busy;
    reg [SLOT_W-1:0]  slot;
    reg signed [IN_W-1:0] x_hold;

    assign ready = !busy;

    // ---- Pipeline: valid and slot carried along ----------------------------
    reg              v1, v2, v3, v4;
    reg [SLOT_W-1:0] s1, s2, s3, s4;

    reg signed [LUT_W-1:0] cos_r, sin_r;
    reg signed [IN_W-1:0]  x1;

    reg signed [IN_W+LUT_W-1:0] prod_i_r, prod_q_r;

    localparam signed [MIX_W-1:0] MIX_MAX =  (1 <<< (MIX_W-1)) - 1;
    localparam signed [MIX_W-1:0] MIX_MIN = -(1 <<< (MIX_W-1));

    wire signed [IN_W+LUT_W-1:0] shr_i = prod_i_r >>> (LUT_W-1);
    wire signed [IN_W+LUT_W-1:0] shr_q = prod_q_r >>> (LUT_W-1);

    reg signed [MIX_W-1:0] mix_i, mix_q;

    // ROM address for the slot being issued in stage 0.
    wire [LUT_ADDR_W-1:0] addr_cos = phase[slot][PHASE_W-1 -: LUT_ADDR_W];
    wire [LUT_ADDR_W-1:0] addr_sin = addr_cos - QUARTER[LUT_ADDR_W-1:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            busy      <= 1'b0;
            slot      <= {SLOT_W{1'b0}};
            x_hold    <= {IN_W{1'b0}};
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v4 <= 1'b0;
            s1 <= {SLOT_W{1'b0}}; s2 <= {SLOT_W{1'b0}};
            s3 <= {SLOT_W{1'b0}}; s4 <= {SLOT_W{1'b0}};
            cos_r <= {LUT_W{1'b0}}; sin_r <= {LUT_W{1'b0}};
            x1    <= {IN_W{1'b0}};
            prod_i_r <= {(IN_W+LUT_W){1'b0}};
            prod_q_r <= {(IN_W+LUT_W){1'b0}};
            mix_i <= {MIX_W{1'b0}}; mix_q <= {MIX_W{1'b0}};
            out_valid <= 1'b0;
            out_slot  <= {SLOT_W{1'b0}};
            tap_i <= {CIC_W{1'b0}};
            tap_q <= {CIC_W{1'b0}};
            overrun <= 1'b0;
            for (k = 0; k < FOLD; k = k + 1) begin
                phase[k] <= {PHASE_W{1'b0}};
                ftw[k]   <= {PHASE_W{1'b0}};
                cnt[k]   <= {CNT_W{1'b0}};
            end
            for (k = 0; k < FOLD*CIC_N; k = k + 1) begin
                acc_i[k] <= {CIC_W{1'b0}};
                acc_q[k] <= {CIC_W{1'b0}};
            end
        end else begin
            if (cfg_we) ftw[cfg_slot] <= cfg_ftw;
            if (in_valid && busy) overrun <= 1'b1;

            // --- Stage 0: round start and ROM addressing --------------------
            v1 <= 1'b0;
            if (in_valid && !busy) begin
                busy   <= 1'b1;
                x_hold <= in_data;
                // Slot 0 is issued right away, with the sample just arrived.
                cos_r <= lut[phase[0][PHASE_W-1 -: LUT_ADDR_W]];
                sin_r <= lut[(phase[0][PHASE_W-1 -: LUT_ADDR_W])
                             - QUARTER[LUT_ADDR_W-1:0]];
                phase[0] <= phase[0] + ftw[0];
                x1 <= in_data;
                v1 <= 1'b1;
                s1 <= {SLOT_W{1'b0}};
                slot <= (FOLD > 1) ? {{(SLOT_W-1){1'b0}}, 1'b1} : {SLOT_W{1'b0}};
                if (FOLD == 1) busy <= 1'b0;
            end else if (busy) begin
                cos_r <= lut[addr_cos];
                sin_r <= lut[addr_sin];
                phase[slot] <= phase[slot] + ftw[slot];
                x1 <= x_hold;
                v1 <= 1'b1;
                s1 <= slot;
                if (slot == FOLD[SLOT_W-1:0] - 1'b1) busy <= 1'b0;
                else slot <= slot + 1'b1;
            end

            // --- Stage 2: the product ---------------------------------------
            prod_i_r <= x1 *  cos_r;
            prod_q_r <= -x1 * sin_r;
            v2 <= v1;
            s2 <= s1;

            // --- Stage 3: shift and saturation ------------------------------
            mix_i <= (shr_i > MIX_MAX) ? MIX_MAX :
                     (shr_i < MIX_MIN) ? MIX_MIN : shr_i[MIX_W-1:0];
            mix_q <= (shr_q > MIX_MAX) ? MIX_MAX :
                     (shr_q < MIX_MIN) ? MIX_MIN : shr_q[MIX_W-1:0];
            v3 <= v2;
            s3 <= s2;

            // --- Stage 4: slot s3 integrators -------------------------------
            // REGISTERED cascade: every stage uses the PREVIOUS value of the
            // one before it. Reading and writing on the same cycle is what
            // makes the pipeline hazard-free for any FOLD.
            v4 <= v3;
            s4 <= s3;
            out_valid <= 1'b0;
            if (v3) begin
                acc_i[s3*CIC_N + 0] <= acc_i[s3*CIC_N + 0] + mix_i;
                acc_q[s3*CIC_N + 0] <= acc_q[s3*CIC_N + 0] + mix_q;
                for (k = 1; k < CIC_N; k = k + 1) begin
                    acc_i[s3*CIC_N + k] <= acc_i[s3*CIC_N + k]
                                         + acc_i[s3*CIC_N + k - 1];
                    acc_q[s3*CIC_N + k] <= acc_q[s3*CIC_N + k]
                                         + acc_q[s3*CIC_N + k - 1];
                end

                if (cnt[s3] == CIC_R[CNT_W-1:0] - 1'b1) begin
                    cnt[s3]   <= {CNT_W{1'b0}};
                    out_valid <= 1'b1;
                    out_slot  <= s3;
                    // The output is the NEW state of the last stage, the same
                    // as in cic_integ: the one just computed above.
                    tap_i <= acc_i[s3*CIC_N + CIC_N-1]
                           + acc_i[s3*CIC_N + CIC_N-2];
                    tap_q <= acc_q[s3*CIC_N + CIC_N-1]
                           + acc_q[s3*CIC_N + CIC_N-2];
                end else begin
                    cnt[s3] <= cnt[s3] + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
