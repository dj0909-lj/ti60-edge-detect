`timescale 1ns/1ps
//=============================================================================
//  video_timing_640x480.v —— 标准 640×480@60Hz 视频时序发生器
//
//  用途一：调试步骤 ①「显示彩条（验证显示通路）」—— 用它产生 de/hsync/vsync，
//          再把固定色值送出去，先证明显示通路是好的。
//  用途二：HDMI 与 VGA 的时序部分完全一致，区别只在后级：
//            VGA  -> 直接 DAC 输出 RGB + 行场同步
//            HDMI -> 加 TMDS 编码（8b/10b）+ 串行化
//          所以本模块写一次，两条路都能用。
//
//  时序参数（VGA 工业标准 640×480@60Hz，像素时钟 25.175MHz）：
//      H：有效 640 | 前肩 16 | 同步 96 | 后肩 48  -> 总 800
//      V：有效 480 | 前肩 10 | 同步  2 | 后肩 33  -> 总 525
//      行频 31.47kHz，场频 59.94Hz
//
//  ⚠️ 上板时若用 Xilinx/易灵思的 demo 改，请以厂商 07 号 HDMI demo 的
//     参数为准；本模块参数是标准 VGA 值，用于自建通路。
//=============================================================================
module video_timing_640x480 (
    input  wire        clk,           // 像素时钟 25.175MHz
    input  wire        rst_n,
    output reg         hsync,         // 负极性
    output reg         vsync,         // 负极性
    output reg         de,            // 数据有效
    output wire [11:0] x,             // 有效区横坐标 0..639
    output wire [11:0] y,             // 有效区纵坐标 0..479
    output reg         sof            // 帧起始（用于行缓存复位）
);

    localparam H_ACT  = 640, H_FP = 16, H_SYNC = 96, H_BP = 48;
    localparam H_TOTAL= H_ACT + H_FP + H_SYNC + H_BP;      // 800
    localparam V_ACT  = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33;
    localparam V_TOTAL= V_ACT + V_FP + V_SYNC + V_BP;      // 525

    reg [11:0] hcnt, vcnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt <= 12'd0;
            vcnt <= 12'd0;
        end else if (hcnt == H_TOTAL-1) begin
            hcnt <= 12'd0;
            vcnt <= (vcnt == V_TOTAL-1) ? 12'd0 : vcnt + 12'd1;
        end else begin
            hcnt <= hcnt + 12'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hsync <= 1'b1;
            vsync <= 1'b1;
            de    <= 1'b0;
            sof   <= 1'b0;
        end else begin
            hsync <= ~((hcnt >= H_ACT + H_FP) && (hcnt < H_ACT + H_FP + H_SYNC));
            vsync <= ~((vcnt >= V_ACT + V_FP) && (vcnt < V_ACT + V_FP + V_SYNC));
            de    <= (hcnt < H_ACT) && (vcnt < V_ACT);
            sof   <= (hcnt == 12'd0) && (vcnt == 12'd0);
        end
    end

    assign x = hcnt;
    assign y = vcnt;

endmodule
