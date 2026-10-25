`timescale 1ns/1ps
//=============================================================================
//  display_mux.v —— 显示合成（赛题【基础要求】第 4 条「分屏 / 画中画叠加」
//                                     + 高阶挑战 5「边缘叠加彩色输出」）
//
//  mode = 0：分屏显示 —— 左半屏原始灰度图，右半屏边缘检测结果，中间绿线分隔
//  mode = 1：画中画   —— 右上角 1/4 尺寸窗口显示边缘图，其余显示灰度图
//  mode = 2：彩色叠加 —— 检测到的边缘以红色叠加到「原始彩色图」上（高阶 5）
//  mode = 3：纯边缘图（调试用，便于观察 Sobel 效果）
//
//  ⚠️ 输入必须已经做过延迟对齐：
//      gray / edge_pix 与 rgb_src 三路要在同一拍上对应同一个源像素，
//      否则分屏两侧、或彩色叠加的颜色与边缘会错位。
//      对齐拍数由 edge_detect_top 统一计算（当前为 10 拍）。
//
//  ⚠️ 坐标 x/y 用的是「显示侧」的像素计数器。因为整条链路已被延迟对齐，
//      输出出现的时刻正好就是显示读取该像素的时刻，所以直接用显示坐标即可。
//
//  ⚠️ 命名注意：Verilog 里 `edge` 是保留字（posedge / negedge），
//      所以二值边缘信号统一叫 edge_pix。
//=============================================================================
module display_mux #(
    parameter H_ACT = 640,
    parameter V_ACT = 480,
    parameter CW    = 12
)(
    input  wire [CW-1:0] x,           // 显示横坐标
    input  wire [CW-1:0] y,           // 显示纵坐标
    input  wire [23:0]   rgb_src,     // 原始彩色（已对齐）
    input  wire [7:0]    gray,        // 原始灰度（已对齐）
    input  wire          edge_pix,    // 二值边缘（已对齐）
    input  wire          valid,       // 数据有效
    input  wire [1:0]    mode,
    output reg  [23:0]   rgb_out
);

    wire [23:0] gray3 = {gray, gray, gray};
    wire [7:0]  e8    = edge_pix ? 8'hFF : 8'h00;
    wire [23:0] edge3 = {e8, e8, e8};

    wire split    = (x <  H_ACT/2);                             // 左半屏
    wire on_split = (x == H_ACT/2);                             // 分界线所在列
    wire in_pip   = (x >= H_ACT - H_ACT/4) && (y < V_ACT/4);    // 画中画窗口

    always @(*) begin
        if (!valid) begin
            rgb_out = 24'h000000;
        end else begin
            case (mode)
                // ---- 分屏：左灰度 / 右边缘 ----
                2'd0: begin
                    if (on_split)    rgb_out = 24'h00FF00;
                    else if (split)  rgb_out = gray3;
                    else             rgb_out = edge3;
                end

                // ---- 画中画：右上角边缘小窗 ----
                2'd1: begin
                    rgb_out = in_pip ? edge3 : gray3;
                end

                // ---- 彩色叠加：红色边缘压在原彩图上 ----
                2'd2: begin
                    rgb_out = { edge_pix ? 8'hFF : rgb_src[23:16],
                                edge_pix ? 8'h00 : rgb_src[15:8],
                                edge_pix ? 8'h00 : rgb_src[7:0]  };
                end

                // ---- 纯边缘 ----
                default: rgb_out = edge3;
            endcase
        end
    end

endmodule
