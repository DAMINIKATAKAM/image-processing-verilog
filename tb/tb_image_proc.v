`timescale 1ns/1ps
// =============================================================================
// tb_image_proc.v  -  Reads a real .bmp image, streams it through image_proc,
//                     writes one output .bmp per mode, and checks every pixel.
// -----------------------------------------------------------------------------
// * Pure Verilog file I/O: $fopen / $fgetc to read, $fwrite("%c") to write.
// * Supports uncompressed 24-bit and 32-bit BMP files.
// * Each output pixel is compared against a reference function written
//   independently in the testbench (integer maths).
//
// Run with a different picture:
//   vvp tb.out +IMAGE=../images/my_photo.bmp
// =============================================================================
module tb_image_proc;

    localparam MAX_BYTES = 4_000_000;     // ~1150 x 1150 pixels at 24-bit

    reg clk = 0;
    always #5 clk = ~clk;                 // 100 MHz

    reg        rst_n = 0;
    reg  [2:0] mode  = 0;
    reg  [7:0] param = 0;
    reg        valid_in = 0;
    reg  [7:0] r_in = 0, g_in = 0, b_in = 0;
    wire       valid_out;
    wire [7:0] r_out, g_out, b_out;

    image_proc dut (
        .clk(clk), .rst_n(rst_n), .mode(mode), .param(param),
        .valid_in(valid_in), .r_in(r_in), .g_in(g_in), .b_in(b_in),
        .valid_out(valid_out), .r_out(r_out), .g_out(g_out), .b_out(b_out)
    );

    // ------------------------------------------------------------------
    // Image storage
    // ------------------------------------------------------------------
    reg [7:0] in_bytes  [0:MAX_BYTES-1];
    reg [7:0] out_bytes [0:MAX_BYTES-1];
    integer   file_size;
    integer   data_offset, width, height, bpp, bytes_pp, row_stride, n_pixels;

    // Byte offset of pixel number p (file order)
    function integer pix_addr;
        input integer p;
        begin
            pix_addr = data_offset + (p / width) * row_stride + (p % width) * bytes_pp;
        end
    endfunction

    function integer le32;              // little-endian 32-bit read
        input integer a;
        begin
            le32 = in_bytes[a] | (in_bytes[a+1] << 8) |
                   (in_bytes[a+2] << 16) | (in_bytes[a+3] << 24);
        end
    endfunction

    // ------------------------------------------------------------------
    // Reference model (independent integer implementation)
    // ------------------------------------------------------------------
    function integer clip;
        input integer v;
        begin
            clip = (v < 0) ? 0 : (v > 255) ? 255 : v;
        end
    endfunction

    function integer ref_channel;       // returns expected value of one channel
        input integer m, prm, r, g, b, ch;  // ch: 0 = R, 1 = G, 2 = B
        integer y, p;
        begin
            p = (ch == 0) ? r : (ch == 1) ? g : b;
            y = (77*r + 150*g + 29*b) / 256;
            case (m)
                1: ref_channel = 255 - p;
                2: ref_channel = y;
                3: ref_channel = clip(p + prm);
                4: ref_channel = clip(p - prm);
                5: ref_channel = (y >= prm) ? 255 : 0;
                6: ref_channel = (ch == 0) ? clip((101*r + 197*g + 48*b) / 256) :
                                 (ch == 1) ? clip(( 89*r + 176*g + 43*b) / 256) :
                                             clip(( 70*r + 137*g + 34*b) / 256);
                7: ref_channel = clip(2*(p - 128) + 128);
                default: ref_channel = p;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // Load BMP
    // ------------------------------------------------------------------
    reg [8*256:1] in_name;
    integer fd, c, i;

    task load_bmp;
        begin
            fd = $fopen(in_name, "rb");
            if (fd == 0) begin
                $display("ERROR: cannot open %0s", in_name);
                $finish;
            end
            file_size = 0;
            c = $fgetc(fd);
            while (c != -1 && file_size < MAX_BYTES) begin
                in_bytes[file_size] = c;
                file_size = file_size + 1;
                c = $fgetc(fd);
            end
            $fclose(fd);

            if (in_bytes[0] != "B" || in_bytes[1] != "M") begin
                $display("ERROR: %0s is not a BMP file", in_name);
                $finish;
            end

            data_offset = le32(10);
            width       = le32(18);
            height      = le32(22);
            if (height < 0) height = -height;   // top-down BMP
            bpp         = in_bytes[28] | (in_bytes[29] << 8);
            bytes_pp    = bpp / 8;
            row_stride  = ((width * bytes_pp) + 3) / 4 * 4;   // rows padded to 4 bytes
            n_pixels    = width * height;

            if (bpp != 24 && bpp != 32) begin
                $display("ERROR: only 24/32-bit BMP supported (got %0d-bit)", bpp);
                $finish;
            end
            $display("Loaded %0s: %0d x %0d, %0d-bit, %0d bytes",
                     in_name, width, height, bpp, file_size);
        end
    endtask

    // ------------------------------------------------------------------
    // Save BMP (header and padding copied from the input)
    // ------------------------------------------------------------------
    task save_bmp;
        input [8*256:1] name;
        begin
            fd = $fopen(name, "wb");
            for (i = 0; i < file_size; i = i + 1)
                $fwrite(fd, "%c", out_bytes[i]);
            $fclose(fd);
        end
    endtask

    // ------------------------------------------------------------------
    // Stream one image through the DUT for the given mode
    // ------------------------------------------------------------------
    integer out_count, mismatches, total_errors = 0;
    integer cycles;

    // Output collector + checker: outputs arrive in the same order as inputs
    always @(posedge clk) begin
        if (valid_out) begin : collect
            integer a, er, eg, eb, rr, gg, bb;
            a  = pix_addr(out_count);
            bb = in_bytes[a]; gg = in_bytes[a+1]; rr = in_bytes[a+2];   // BMP stores B,G,R
            er = ref_channel(mode, param, rr, gg, bb, 0);
            eg = ref_channel(mode, param, rr, gg, bb, 1);
            eb = ref_channel(mode, param, rr, gg, bb, 2);
            if (r_out != er || g_out != eg || b_out != eb) begin
                if (mismatches < 5)
                    $display("  mismatch at pixel %0d: got (%0d,%0d,%0d) expected (%0d,%0d,%0d)",
                             out_count, r_out, g_out, b_out, er, eg, eb);
                mismatches = mismatches + 1;
            end
            out_bytes[a]   = b_out;
            out_bytes[a+1] = g_out;
            out_bytes[a+2] = r_out;
            out_count = out_count + 1;
        end
    end

    task run_mode;
        input [2:0]     m;
        input [7:0]     prm;
        input [8*24:1]  label;
        input [8*256:1] out_name;
        integer p, a;
        begin
            mode = m; param = prm;
            for (i = 0; i < file_size; i = i + 1) out_bytes[i] = in_bytes[i];
            out_count = 0; mismatches = 0; cycles = 0;

            // one pixel per clock, inputs driven on the falling edge
            for (p = 0; p < n_pixels; p = p + 1) begin
                @(negedge clk);
                a = pix_addr(p);
                valid_in = 1'b1;
                b_in = in_bytes[a]; g_in = in_bytes[a+1]; r_in = in_bytes[a+2];
                cycles = cycles + 1;
            end
            @(negedge clk) valid_in = 1'b0;
            while (out_count < n_pixels) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            save_bmp(out_name);
            if (mismatches == 0)
                $display("  PASS  mode %0d %-16s %0d pixels in %0d cycles -> %0s",
                         m, label, out_count, cycles, out_name);
            else
                $display("  FAIL  mode %0d %-16s %0d mismatching pixels", m, label, mismatches);
            total_errors = total_errors + mismatches;
        end
    endtask

    // ------------------------------------------------------------------
    // Main
    // ------------------------------------------------------------------
    initial begin
        if (!$value$plusargs("IMAGE=%s", in_name))
            in_name = "../images/input.bmp";

        $display("\n=== Image processing pipeline testbench ===");
        load_bmp;

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        $display("");
        run_mode(3'd0,  8'd0,   "pass-through",    "../output/0_passthrough.bmp");
        run_mode(3'd1,  8'd0,   "invert",          "../output/1_invert.bmp");
        run_mode(3'd2,  8'd0,   "grayscale",       "../output/2_grayscale.bmp");
        run_mode(3'd3,  8'd70,  "brightness +70",  "../output/3_brighter.bmp");
        run_mode(3'd4,  8'd70,  "brightness -70",  "../output/4_darker.bmp");
        run_mode(3'd5,  8'd110, "threshold 110",   "../output/5_threshold.bmp");
        run_mode(3'd6,  8'd0,   "sepia",           "../output/6_sepia.bmp");
        run_mode(3'd7,  8'd0,   "contrast x2",     "../output/7_contrast.bmp");

        $display("\n=========================================");
        if (total_errors == 0) $display("  ALL TESTS PASSED (8 modes, every pixel checked)");
        else                   $display("  TESTS FAILED: %0d pixel error(s)", total_errors);
        $display("=========================================\n");
        $finish;
    end

endmodule
