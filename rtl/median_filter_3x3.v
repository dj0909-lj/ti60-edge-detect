`timescale 1ns/1ps
//=============================================================================
//  median_filter_3x3.v —— 3×3 中值滤波去噪（高阶挑战 1）
//
//  输入 3×3 窗口 9 个 8bit 像素，输出中位数。
//  官方技术提示：先对 3 行各自排序，再对列排序；用并行比较网络，
//                避免串行排序（串行排序会拖垮流水线）。
//
//  采用 Smith 中值网络：
//      第 1 级：每行 3 个像素排序 -> (min, med, max)     3 行 × 4 比较器
//      第 2 级：三个候选量各取「跨行中值」：
//                cand_min = med(min0, min1, min2)
//                cand_med = med(med0, med1, med2)
//                cand_max = med(max0, max1, max2)        3 × 2 比较器
//      第 3 级：result = med(cand_min, cand_med, cand_max)   2 比较器
//
//  合计约 20 个 8bit 比较器，3 级流水，每个时钟输出 1 个中值。
//  位置：灰度化之后、Sobel 之前。延迟固定 3 拍。
//=============================================================================
module median_filter_3x3 #(
    parameter DW = 8
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            in_valid,
    input  wire [DW-1:0]   p00, p01, p02,
    input  wire [DW-1:0]   p10, p11, p12,
    input  wire [DW-1:0]   p20, p21, p22,
    output reg             out_valid,
    output reg  [DW-1:0]   med_out
);

    // ---- 3 输入取最小 / 最大 / 中值组合逻辑 ----
    function [DW-1:0] f_min3;
        input [DW-1:0] a, b, c;
        reg   [DW-1:0] lo;
        begin
            lo = (a < b) ? a : b;
            f_min3 = (lo < c) ? lo : c;
        end
    endfunction

    function [DW-1:0] f_max3;
        input [DW-1:0] a, b, c;
        reg   [DW-1:0] hi;
        begin
            hi = (a < b) ? b : a;
            f_max3 = (hi < c) ? c : hi;
        end
    endfunction

    function [DW-1:0] f_med3;
        input [DW-1:0] a, b, c;
        reg   [DW-1:0] lo, hi, t;
        begin
            lo = (a < b) ? a : b;
            hi = (a < b) ? b : a;
            t  = (hi < c) ? hi : c;       // min(hi, c)
            f_med3 = (lo > t) ? lo : t;   // max(lo, min(hi,c))
        end
    endfunction

    // ---- 第 1 级：逐行排序 ----
    reg [DW-1:0] r0_min, r0_med, r0_max;
    reg [DW-1:0] r1_min, r1_med, r1_max;
    reg [DW-1:0] r2_min, r2_med, r2_max;
    reg          v1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r0_min <= 0; r0_med <= 0; r0_max <= 0;
            r1_min <= 0; r1_med <= 0; r1_max <= 0;
            r2_min <= 0; r2_med <= 0; r2_max <= 0;
            v1     <= 1'b0;
        end else begin
            r0_min <= f_min3(p00, p01, p02);
            r0_med <= f_med3(p00, p01, p02);
            r0_max <= f_max3(p00, p01, p02);
            r1_min <= f_min3(p10, p11, p12);
            r1_med <= f_med3(p10, p11, p12);
            r1_max <= f_max3(p10, p11, p12);
            r2_min <= f_min3(p20, p21, p22);
            r2_med <= f_med3(p20, p21, p22);
            r2_max <= f_max3(p20, p21, p22);
            v1     <= in_valid;
        end
    end

    // ---- 第 2 级：三个候选量各取跨行中值 ----
    reg [DW-1:0] cand_min, cand_med, cand_max;
    reg          v2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cand_min <= 0; cand_med <= 0; cand_max <= 0;
            v2       <= 1'b0;
        end else begin
            cand_min <= f_med3(r0_min, r1_min, r2_min);
            cand_med <= f_med3(r0_med, r1_med, r2_med);
            cand_max <= f_med3(r0_max, r1_max, r2_max);
            v2       <= v1;
        end
    end

    // ---- 第 3 级：最终中值输出 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            med_out   <= {DW{1'b0}};
            out_valid <= 1'b0;
        end else begin
            med_out   <= f_med3(cand_min, cand_med, cand_max);
            out_valid <= v2;
        end
    end

endmodule
