`timescale 1ns/1ps
// =============================================================================
// image_proc.v  -  Streaming RGB pixel-processing pipeline
// -----------------------------------------------------------------------------
// One pixel enters per clock (valid_in), one processed pixel leaves per clock
// (valid_out) after a fixed latency of 2 cycles. This is the same streaming
// style used for camera and video pipelines on FPGAs.
//
//   mode | operation        | param
//   -----+------------------+---------------------------
//    0   | pass-through     | -
//    1   | invert (negative)| -
//    2   | grayscale        | -
//    3   | brightness up    | amount to add (saturates at 255)
//    4   | brightness down  | amount to subtract (saturates at 0)
//    5   | threshold (B/W)  | threshold level
//    6   | sepia            | -
//    7   | contrast x2      | -
//
// Grayscale uses the standard luminance weights in fixed point (x/256):
//     Y = (77 R + 150 G + 29 B) >> 8        (0.299, 0.587, 0.114)
// No division or floating point: only multiply-by-constant, add and shift.
// =============================================================================
module image_proc (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [2:0] mode,
    input  wire [7:0] param,

    input  wire       valid_in,
    input  wire [7:0] r_in,
    input  wire [7:0] g_in,
    input  wire [7:0] b_in,

    output reg        valid_out,
    output reg  [7:0] r_out,
    output reg  [7:0] g_out,
    output reg  [7:0] b_out
);

    localparam M_PASS     = 3'd0,
               M_INVERT   = 3'd1,
               M_GRAY     = 3'd2,
               M_BRIGHT   = 3'd3,
               M_DARK     = 3'd4,
               M_THRESH   = 3'd5,
               M_SEPIA    = 3'd6,
               M_CONTRAST = 3'd7;

    // ------------------------------------------------------------------
    // Helper functions
    // ------------------------------------------------------------------
    // Clamp a 17-bit fixed-point sum (value x 256) to an 8-bit pixel
    function [7:0] clamp_fx;
        input [16:0] sum;
        begin
            clamp_fx = (sum[16:8] > 9'd255) ? 8'd255 : sum[15:8];
        end
    endfunction

    // Saturating add / subtract
    function [7:0] sat_add;
        input [7:0] a, b;
        reg   [8:0] s;
        begin
            s       = a + b;
            sat_add = s[8] ? 8'd255 : s[7:0];
        end
    endfunction

    function [7:0] sat_sub;
        input [7:0] a, b;
        begin
            sat_sub = (a > b) ? (a - b) : 8'd0;
        end
    endfunction

    // Contrast x2 around mid-grey: out = 2*(p - 128) + 128, clamped
    function [7:0] contrast2;
        input [7:0] p;
        reg signed [10:0] v;
        begin
            v = ($signed({3'b000, p}) - 11'sd128) * 2 + 11'sd128;
            if (v < 0)         contrast2 = 8'd0;
            else if (v > 255)  contrast2 = 8'd255;
            else               contrast2 = v[7:0];
        end
    endfunction

    // ------------------------------------------------------------------
    // Stage 1: register the pixel and compute weighted sums
    // ------------------------------------------------------------------
    reg        v1;
    reg [7:0]  r1, g1, b1;
    reg [16:0] gray_sum;
    reg [16:0] sep_r, sep_g, sep_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0;
            r1 <= 8'd0; g1 <= 8'd0; b1 <= 8'd0;
            gray_sum <= 17'd0;
            sep_r <= 17'd0; sep_g <= 17'd0; sep_b <= 17'd0;
        end else begin
            v1 <= valid_in;
            r1 <= r_in; g1 <= g_in; b1 <= b_in;

            gray_sum <=  77 * r_in + 150 * g_in +  29 * b_in;

            // Sepia matrix (x256):  R' = .393R + .769G + .189B
            //                       G' = .349R + .686G + .168B
            //                       B' = .272R + .534G + .131B
            sep_r <= 101 * r_in + 197 * g_in + 48 * b_in;
            sep_g <=  89 * r_in + 176 * g_in + 43 * b_in;
            sep_b <=  70 * r_in + 137 * g_in + 34 * b_in;
        end
    end

    // ------------------------------------------------------------------
    // Stage 2: select the operation and clamp
    // ------------------------------------------------------------------
    wire [7:0] gray = gray_sum[15:8];   // max 256*255/256 -> fits in 8 bits

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            r_out <= 8'd0; g_out <= 8'd0; b_out <= 8'd0;
        end else begin
            valid_out <= v1;
            case (mode)
                M_INVERT: begin
                    r_out <= ~r1; g_out <= ~g1; b_out <= ~b1;
                end
                M_GRAY: begin
                    r_out <= gray; g_out <= gray; b_out <= gray;
                end
                M_BRIGHT: begin
                    r_out <= sat_add(r1, param);
                    g_out <= sat_add(g1, param);
                    b_out <= sat_add(b1, param);
                end
                M_DARK: begin
                    r_out <= sat_sub(r1, param);
                    g_out <= sat_sub(g1, param);
                    b_out <= sat_sub(b1, param);
                end
                M_THRESH: begin
                    r_out <= (gray >= param) ? 8'd255 : 8'd0;
                    g_out <= (gray >= param) ? 8'd255 : 8'd0;
                    b_out <= (gray >= param) ? 8'd255 : 8'd0;
                end
                M_SEPIA: begin
                    r_out <= clamp_fx(sep_r);
                    g_out <= clamp_fx(sep_g);
                    b_out <= clamp_fx(sep_b);
                end
                M_CONTRAST: begin
                    r_out <= contrast2(r1);
                    g_out <= contrast2(g1);
                    b_out <= contrast2(b1);
                end
                default: begin                 // M_PASS
                    r_out <= r1; g_out <= g1; b_out <= b1;
                end
            endcase
        end
    end

endmodule
