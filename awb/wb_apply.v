`timescale 1ns/1ns
//=============================================================================
//  rgb2gray_t.v 已在上一步生成（彩色转灰度，带时序透传）
//  本文件：白平衡（AWB 的定点近似）  赛题【基础要求 2】相关
//
//  为什么需要：
//    RAW Bayer 直接 demosaic 而不做白平衡，画面会明显【偏绿】——
//    因为 Bayer 阵列里绿像素数量是红/蓝的 2 倍，且绿通道量子效率通常更高。
//    这是所有未做 AWB 的 RAW 通路的典型症状。
//
//  实现：对 R/B 通道施加固定增益（G 保持 1.0），Q4.4 定点
//      R_out = saturate( R_in * R_GAIN / 16 )
//      B_out = saturate( B_in * B_GAIN / 16 )
//    增益为编译期常数，综合器会优化成移位加法；即便用 DSP 也符合赛题
//    （赛题明确允许"用 DSP 块或移位加法实现乘法"），全程无除法器。
//
//  时序：1 拍（vsync/hsync/href 一起延 1 拍）
//  旁路：en=0 时原样输出（同样是 1 拍延迟，保证不改变时序）
//=============================================================================
module wb_apply #(
    parameter [15:0] R_GAIN = 16'd28,   // 1.75x  (28/16)
    parameter [15:0] B_GAIN = 16'd24,   // 1.50x  (24/16)
    parameter        SHIFT  = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,

    input  wire        in_vsync,
    input  wire        in_hsync,
    input  wire        in_href,
    input  wire [7:0]  r_in,
    input  wire [7:0]  g_in,
    input  wire [7:0]  b_in,

    output reg         out_vsync,
    output reg         out_hsync,
    output reg         out_href,
    output reg  [7:0]  r_out,
    output reg  [7:0]  g_out,
    output reg  [7:0]  b_out
);

    // 乘法 + 饱和
    function [7:0] scale_sat;
        input [7:0]  v;
        input [15:0] gain;
        reg   [23:0] prod;
        begin
            prod = v * gain;
            prod = prod >> SHIFT;
            scale_sat = (prod > 24'd255) ? 8'd255 : prod[7:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vsync <= 1'b0;
            out_hsync <= 1'b0;
            out_href  <= 1'b0;
            r_out     <= 8'd0;
            g_out     <= 8'd0;
            b_out     <= 8'd0;
        end else begin
            out_vsync <= in_vsync;
            out_hsync <= in_hsync;
            out_href  <= in_href;
            if (en) begin
                r_out <= scale_sat(r_in, R_GAIN);
                b_out <= scale_sat(b_in, B_GAIN);
            end else begin
                r_out <= r_in;
                b_out <= b_in;
            end
            g_out <= g_in;      // 绿通道保持 1.0
        end
    end

endmodule
