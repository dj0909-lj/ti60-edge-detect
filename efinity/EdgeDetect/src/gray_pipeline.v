`timescale 1ns/1ps
//=============================================================================
//  gray_pipeline.v —— 边缘检测核心流水线（算法链主体）
//
//  链路（与赛题「全流水线处理」示意图一致）：
//      灰度像素 -> [行缓存 3×3] -> [中值滤波] -> [行缓存 3×3] -> [Sobel] -> 二值边缘
//                                        |            |
//                                        |            └─ 可旁路（median_en=0，延迟不变）
//                                        └─ 位置：灰度化之后、边缘检测之前
//
//  延迟：行缓存 1 + 中值 3 + 行缓存 1 + Sobel 4 = 9 拍
//        再把输入灰度延迟 9 拍输出（gray_aligned），供分屏/叠加显示与原图对齐。
//        加上前级 rgb2gray 的 1 拍，全链 = 10 拍。
//
//  ⚠️ 对齐基准约定：本流水线统一以「3×3 窗口的最新角 p02」作为输出像素的
//     空间基准（不是窗口中心 p11）。三处必须一致，否则会出现 (1 列, 1 行) 偏移：
//       ① 中值旁路通道必须取 p02 延迟 3 拍，绝不能取 p11；
//          p11 是窗口中心，比最新角滞后 (1 列, 1 行)，
//          会让边缘特征整体右下平移 1 个像素（已由 tb 定量复现：单竖线
//          @x=16 的 Sobel 响应本应在 x=16/18，却出现在 x=17/19）。
//       ② Sobel 用 p02 列与 p00 列做差分（Gx = 4·col(c) − 4·col(c−2)），
//          响应基准即最新角 c；
//       ③ 灰度对齐延迟链的总拍数与边缘链严格相等。
//
//  ⚠️ 命名注意：Verilog 里 `edge` 是保留字，二值边缘信号统一叫 edge_pix。
//=============================================================================
module gray_pipeline #(
    parameter IMG_W = 640,
    parameter DW    = 8,
    parameter TW    = 12
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            sof,
    input  wire            de,             // 灰度像素有效
    input  wire [DW-1:0]   gray_in,
    input  wire [TW-1:0]   threshold,
    input  wire            median_en,      // 1 = 插入中值滤波
    output wire            out_valid,
    output wire [DW-1:0]   gray_aligned,   // 与 edge_out 同拍的原始灰度
    output wire            edge_out        // 二值边缘
);

    localparam LB_LAT  = 1;
    localparam MED_LAT = 3;
    localparam SOB_LAT = 4;
    localparam TOTAL   = LB_LAT + MED_LAT + LB_LAT + SOB_LAT;   // 9

    // ==================== ① 行缓存 + 3×3 窗口 ====================
    wire [DW-1:0] w_p00, w_p01, w_p02;
    wire [DW-1:0] w_p10, w_p11, w_p12;
    wire [DW-1:0] w_p20, w_p21, w_p22;
    wire          win_valid;

    line_buffer_3x3 #(.IMG_W(IMG_W), .DW(DW)) u_lb1 (
        .clk(clk), .rst_n(rst_n), .de(de), .sof(sof), .pix_in(gray_in),
        .win_valid(win_valid),
        .p00(w_p00), .p01(w_p01), .p02(w_p02),
        .p10(w_p10), .p11(w_p11), .p12(w_p12),
        .p20(w_p20), .p21(w_p21), .p22(w_p22)
    );

    // ==================== ② 中值滤波（可旁路） ====================
    wire [DW-1:0] med_pix;
    wire          med_valid_own;

    median_filter_3x3 #(.DW(DW)) u_med (
        .clk(clk), .rst_n(rst_n), .in_valid(win_valid),
        .p00(w_p00), .p01(w_p01), .p02(w_p02),
        .p10(w_p10), .p11(w_p11), .p12(w_p12),
        .p20(w_p20), .p21(w_p21), .p22(w_p22),
        .out_valid(med_valid_own), .med_out(med_pix)
    );

    // 旁路通道：取窗口「最新角 p02」延迟 3 拍（与中值输出同延迟、同空间基准）
    wire [DW-1:0] newest_d3;
    wire          valid_d3;

    shift_delay #(.W(DW), .DEPTH(MED_LAT)) u_newest_dly (
        .clk(clk), .rst_n(rst_n), .din(w_p02), .dout(newest_d3)
    );
    shift_delay #(.W(1),  .DEPTH(MED_LAT)) u_valid_dly0 (
        .clk(clk), .rst_n(rst_n), .din(win_valid), .dout(valid_d3)
    );

    wire [DW-1:0] med_stage_pix   = median_en ? med_pix    : newest_d3;
    wire          med_stage_valid = valid_d3;    // 中值 / 旁路 延迟同为 3 拍

    // ==================== ③ 第二级行缓存（喂 Sobel） ====================
    wire [DW-1:0] s_p00, s_p01, s_p02;
    wire [DW-1:0] s_p10, s_p11, s_p12;
    wire [DW-1:0] s_p20, s_p21, s_p22;
    wire          s_win_valid;

    line_buffer_3x3 #(.IMG_W(IMG_W), .DW(DW)) u_lb2 (
        .clk(clk), .rst_n(rst_n), .de(med_stage_valid), .sof(sof),
        .pix_in(med_stage_pix), .win_valid(s_win_valid),
        .p00(s_p00), .p01(s_p01), .p02(s_p02),
        .p10(s_p10), .p11(s_p11), .p12(s_p12),
        .p20(s_p20), .p21(s_p21), .p22(s_p22)
    );

    // ==================== ④ Sobel ====================
    wire [TW-1:0] grad;
    wire          edge_pix;
    wire          edge_valid;

    sobel_3x3 #(.DW(DW), .TW(TW)) u_sobel (
        .clk(clk), .rst_n(rst_n), .in_valid(s_win_valid),
        .p00(s_p00), .p01(s_p01), .p02(s_p02),
        .p10(s_p10), .p11(s_p11), .p12(s_p12),
        .p20(s_p20), .p21(s_p21), .p22(s_p22),
        .threshold(threshold),
        .out_valid(edge_valid), .grad_out(grad), .edge_out(edge_pix)
    );

    assign out_valid = edge_valid;
    assign edge_out  = edge_pix;

    // ==================== ⑤ 灰度对齐延迟 ====================
    shift_delay #(.W(DW), .DEPTH(TOTAL)) u_gray_dly (
        .clk(clk), .rst_n(rst_n), .din(gray_in), .dout(gray_aligned)
    );

endmodule


//=============================================================================
//  shift_delay.v —— 参数化打拍延迟链
//=============================================================================
module shift_delay #(
    parameter W     = 8,
    parameter DEPTH = 1
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire [W-1:0]  din,
    output wire [W-1:0]  dout
);
    reg [W-1:0] sr [0:DEPTH-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < DEPTH; i = i + 1) sr[i] <= {W{1'b0}};
        end else begin
            sr[0] <= din;
            for (i = 1; i < DEPTH; i = i + 1) sr[i] <= sr[i-1];
        end
    end

    assign dout = sr[DEPTH-1];
endmodule
