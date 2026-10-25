`timescale 1ns/1ps
//=============================================================================
//  sobel_3x3.v —— Sobel 边缘检测 + 四级流水线
//  （赛题【基础要求】第 3 条 / 官方「Sobel 计算流水线设计」）
//
//      窗口：  p00 p01 p02
//              p10 p11 p12
//              p20 p21 p22
//
//      Gx = (p02 + 2*p12 + p22) - (p00 + 2*p10 + p20)
//      Gy = (p20 + 2*p21 + p22) - (p00 + 2*p01 + p02)
//      G  = |Gx| + |Gy|                 (用绝对值代替开方，省 DSP)
//      edge = (G > threshold) ? 1 : 0
//
//  四级流水线（官方技术提示的划分方式，延迟固定 4 拍）：
//      ① 行/列三项部分和（cr / cl / tr / br）
//      ② Gx、Gy 完整计算
//      ③ 梯度幅值 G = |Gx| + |Gy|
//      ④ 阈值比较，输出二值边缘
//
//  位宽核算：|Gx| <= 4*255 = 1020，|Gy| 同理 -> G <= 2040 -> 12bit 足够
//  ×2 用 {x,1'b0} 实现，零乘法器开销。
//
//  官方提示：四级流水线优化后最高频率可达 220MHz，而像素时钟只有 25MHz，
//            时序余量极其充足，不必过度优化。
//=============================================================================
module sobel_3x3 #(
    parameter DW = 8,          // 像素位宽
    parameter TW = 12          // 梯度/阈值位宽
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            in_valid,
    input  wire [DW-1:0]   p00, p01, p02,
    input  wire [DW-1:0]   p10, p11, p12,
    input  wire [DW-1:0]   p20, p21, p22,
    input  wire [TW-1:0]   threshold,
    output reg             out_valid,
    output reg  [TW-1:0]   grad_out,     // 梯度幅值（调试用）
    output reg             edge_out      // 二值边缘
);

    // -------------------- 第 1 级：部分和 --------------------
    wire [10:0] cr = {3'd0, p02} + {2'd0, p12, 1'b0} + {3'd0, p22};  // p02+2*p12+p22
    wire [10:0] cl = {3'd0, p00} + {2'd0, p10, 1'b0} + {3'd0, p20};  // p00+2*p10+p20
    wire [10:0] tr = {3'd0, p00} + {2'd0, p01, 1'b0} + {3'd0, p02};  // p00+2*p01+p02
    wire [10:0] br = {3'd0, p20} + {2'd0, p21, 1'b0} + {3'd0, p22};  // p20+2*p21+p22

    reg [10:0] cr_r, cl_r, tr_r, br_r;
    reg        v1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cr_r <= 11'd0; cl_r <= 11'd0; tr_r <= 11'd0; br_r <= 11'd0;
            v1   <= 1'b0;
        end else begin
            cr_r <= cr;  cl_r <= cl;  tr_r <= tr;  br_r <= br;
            v1   <= in_valid;
        end
    end

    // -------------------- 第 2 级：Gx / Gy --------------------
    // 用 12bit 无符号承载补码，第 11 位即符号位
    reg [11:0] gx_r, gy_r;
    reg        v2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gx_r <= 12'd0; gy_r <= 12'd0; v2 <= 1'b0;
        end else begin
            gx_r <= {1'b0, cr_r} - {1'b0, cl_r};   // 水平梯度
            gy_r <= {1'b0, br_r} - {1'b0, tr_r};   // 垂直梯度
            v2   <= v1;
        end
    end

    // -------------------- 第 3 级：梯度幅值 --------------------
    wire [11:0] abs_gx = gx_r[11] ? (~gx_r + 12'd1) : gx_r;
    wire [11:0] abs_gy = gy_r[11] ? (~gy_r + 12'd1) : gy_r;

    reg [11:0] grad_r;
    reg        v3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_r <= 12'd0; v3 <= 1'b0;
        end else begin
            grad_r <= abs_gx + abs_gy;             // G = |Gx| + |Gy|
            v3     <= v2;
        end
    end

    // -------------------- 第 4 级：阈值比较 --------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_out <= 12'd0;
            edge_out <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            grad_out <= grad_r;
            edge_out <= (grad_r > threshold) ? 1'b1 : 1'b0;
            out_valid <= v3;
        end
    end

endmodule
