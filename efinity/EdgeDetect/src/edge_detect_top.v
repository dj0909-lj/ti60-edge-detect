`timescale 1ns/1ps
//=============================================================================
//  edge_detect_top.v —— 赛题四顶层：完整算法链 + 显示合成
//
//      摄像头 RGB ──► [灰度化] ──► [行缓存 3×3] ──► [中值滤波] ──► [行缓存 3×3]
//                        │                                              │
//                        │                                              ▼
//                        │                                          [Sobel]
//                        │                                              │
//                        │                                   [阈值二值化] ◄── 按键阈值
//                        │                                              │
//                        └──► (延迟 10 拍对齐) ────────────────► [显示合成] ──► HDMI
//                                                                     ▲
//                                                    分屏 / 画中画 / 彩色叠加
//
//  延迟核算：灰度化 1 + 行缓存 1 + 中值 3 + 行缓存 1 + Sobel 4 = 10 拍
//            原始 RGB 与灰度都延迟 10 拍，保证与 edge_pix 同拍。
//
//  ⚠️ 本模块不含摄像头驱动与 HDMI 时序发生器，便于纯仿真验证算法链。
//     上板时：DVP 采集模块输出 (de, vsync/sof, r/g/b) 接进来，
//             rgb_out 送 HDMI TMDS 编码模块。见 video_timing_640x480.v。
//
//  ⚠️ 命名注意：Verilog 里 `edge` 是保留字，二值边缘信号统一叫 edge_pix。
//=============================================================================
module edge_detect_top #(
    parameter IMG_W      = 640,      // 行缓存深度 = 图像行宽
    parameter H_ACT      = 640,      // 显示有效宽度
    parameter V_ACT      = 480,      // 显示有效高度
    parameter TW         = 12,       // 梯度 / 阈值位宽
    parameter CW         = 12,       // 坐标位宽
    parameter DEB_CNT_W  = 19        // 按键消抖计数位宽（25MHz 下 19bit ≈ 21ms）
)(
    input  wire          clk,        // 像素时钟
    input  wire          rst_n,
    input  wire          sof,        // 帧起始脉冲（vsync 边沿）
    input  wire          de,         // 像素有效
    input  wire [7:0]    r,
    input  wire [7:0]    g,
    input  wire [7:0]    b,
    input  wire [CW-1:0] x,          // 显示横坐标
    input  wire [CW-1:0] y,          // 显示纵坐标
    input  wire [1:0]    key,        // key[0] = 阈值+ , key[1] = 阈值−
    input  wire          median_en,  // 1 = 使能中值滤波
    input  wire [1:0]    disp_mode,  // 0=分屏 1=画中画 2=彩色叠加 3=纯边缘
    output wire [23:0]   rgb_out,
    output wire          out_valid,
    output wire [TW-1:0] threshold_o // 当前阈值（可送屏幕字符叠加显示）
);

    localparam GRAY_LAT = 1;
    localparam PIPE_LAT = 9;
    localparam RGB_LAT  = GRAY_LAT + PIPE_LAT;      // 10

    // ==================== ① 彩色转灰度 ====================
    wire [7:0] gray;
    wire       gray_valid;

    rgb2gray u_g2g (
        .clk(clk), .rst_n(rst_n), .in_valid(de),
        .r(r), .g(g), .b(b),
        .out_valid(gray_valid), .y(gray)
    );

    // ==================== ② 阈值实时调节（按键 + 消抖） ====================
    wire inc_p, dec_p;

    debounce #(.CNT_W(DEB_CNT_W)) u_db_inc (
        .clk(clk), .rst_n(rst_n), .key_in(key[0]),
        .key_out(), .key_press(inc_p)
    );
    debounce #(.CNT_W(DEB_CNT_W)) u_db_dec (
        .clk(clk), .rst_n(rst_n), .key_in(key[1]),
        .key_out(), .key_press(dec_p)
    );

    threshold_ctrl #(.TW(TW)) u_th (
        .clk(clk), .rst_n(rst_n),
        .inc(inc_p), .dec(dec_p),
        .threshold(threshold_o)
    );

    // ==================== ③ 主体流水线 ====================
    wire [7:0] gray_al;
    wire       edge_pix;
    wire       edge_valid;

    gray_pipeline #(.IMG_W(IMG_W), .DW(8), .TW(TW)) u_pipe (
        .clk(clk), .rst_n(rst_n), .sof(sof),
        .de(gray_valid), .gray_in(gray),
        .threshold(threshold_o), .median_en(median_en),
        .out_valid(edge_valid),
        .gray_aligned(gray_al), .edge_out(edge_pix)
    );

    // ==================== ④ 原始 RGB 延迟对齐 ====================
    wire [23:0] rgb_src = {r, g, b};
    wire [23:0] rgb_al;

    shift_delay #(.W(24), .DEPTH(RGB_LAT)) u_rgb_dly (
        .clk(clk), .rst_n(rst_n), .din(rgb_src), .dout(rgb_al)
    );

    // ==================== ⑤ 显示合成 ====================
    display_mux #(.H_ACT(H_ACT), .V_ACT(V_ACT), .CW(CW)) u_mux (
        .x(x), .y(y),
        .rgb_src(rgb_al), .gray(gray_al), .edge_pix(edge_pix),
        .valid(edge_valid), .mode(disp_mode),
        .rgb_out(rgb_out)
    );

    assign out_valid = edge_valid;

endmodule
