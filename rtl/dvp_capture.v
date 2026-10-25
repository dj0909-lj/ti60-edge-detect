`timescale 1ns/1ps
//=============================================================================
//  dvp_capture.v —— DVP 摄像头采集模块（赛题四「摄像头采集」）
//-----------------------------------------------------------------------------
//  支持两种像素格式（用 PIX_W 选择）：
//    PIX_W = 8  ：8bit 单色 / YUV  —— AR0135(黑白)、MT9M001(黑白) 等
//    PIX_W = 16 ：16bit RGB565    —— OV5640(彩色) 等，两个字节拼成一个像素
//
//  时序约定（DVP 通用）：
//    VSYNC 上升沿 = 新帧开始；HREF 高电平期间 PCLK 逐像素有效
//    VSYNC / HREF 极性、每行像素数、行数、字节序全部参数化
//
//  输出（全部与 pclk 同域；px_we 与 px_data / col_num 严格同拍）：
//    px_data / px_we / col_num / line_num / frame_start / line_start / line_end
//
//  ⚠️ 三条铁律（防斜切 / 防错位，与行缓存同源的坑）：
//    1. 只在 href 有效时写入 —— 消隐期的空闲时钟绝不能当像素
//    2. 列计数越界即丢弃 —— 有些模组一行会多给几个像素
//    3. 行计数越界后关闭帧窗口 —— 防止多余行污染下一帧
//
//  与厂商参考实现的关系：
//    行为等价于 Ti60_Demo 的 src/cmos_i2c/CMOS_Capture_RAW_Gray.v，
//    但把「行宽 / 行数 / 极性 / 像素位宽」全部提成参数，
//    以便在黑白 AR0135 与彩色 OV5640 之间零改动切换。
//=============================================================================
module dvp_capture #(
    parameter PIX_W          = 8,      // 8 = 单色/YUV,  16 = RGB565
    parameter H_ACTIVE       = 640,    // 每行有效像素数
    parameter V_ACTIVE       = 480,    // 有效行数
    parameter VSYNC_ACT_HIGH = 1,      // VSYNC 有效极性：1=高有效
    parameter HREF_ACT_HIGH  = 1,      // HREF  有效极性：1=高有效
    parameter MSB_FIRST      = 1,      // RGB565 字节序：1=高字节先出
    parameter CW             = 12      // 行列坐标位宽
)(
    input  wire              pclk,
    input  wire              rst_n,
    // ---- DVP 输入 ----
    input  wire              vsync_i,
    input  wire              href_i,
    input  wire [7:0]        d_i,
    // ---- 像素流输出（与 pclk 同域）----
    output reg  [PIX_W-1:0]  px_data,
    output reg               px_we,        // 像素有效（单拍）
    output reg  [CW-1:0]     col_num,      // 像素列号，与 px_we 同拍
    output reg  [CW-1:0]     line_num,     // 当前行号
    // ---- 帧 / 行同步脉冲 ----
    output reg               frame_start,  // VSYNC 上升沿（新帧）
    output reg               line_start,   // 每行第一个有效像素
    output reg               line_end,     // 每行最后一个有效像素
    output reg               frame_active  // 处于有效帧窗口内
);

    localparam BPW = (PIX_W > 8) ? 2 : 1;  // 每像素字节数

    wire vsync_act = VSYNC_ACT_HIGH ? vsync_i : ~vsync_i;
    wire href_act  = HREF_ACT_HIGH  ? href_i  : ~href_i;

    // ---- VSYNC 上升沿检测 ----
    reg vsync_ff;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) vsync_ff <= 1'b0;
        else        vsync_ff <= vsync_act;

    wire vsync_rise = vsync_act & ~vsync_ff;

    reg          byte_sel;              // RGB565：0=第 1 字节, 1=第 2 字节
    reg [7:0]    byte_lo;               // RGB565：暂存第一个字节
    reg [15:0]   px16;                  // RGB565 组装缓冲（避免对 px_data 做越界分片）
    reg [CW-1:0] col_cnt;               // 内部列计数器

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            frame_active <= 1'b0;
            frame_start  <= 1'b0;
            line_start   <= 1'b0;
            line_end     <= 1'b0;
            px_we        <= 1'b0;
            px_data      <= {PIX_W{1'b0}};
            px16         <= 16'd0;
            col_cnt      <= {CW{1'b0}};
            col_num      <= {CW{1'b0}};
            line_num     <= {CW{1'b0}};
            byte_sel     <= 1'b0;
            byte_lo      <= 8'd0;
        end else begin
            // 脉冲默认拉低
            frame_start <= 1'b0;
            line_start  <= 1'b0;
            line_end    <= 1'b0;
            px_we       <= 1'b0;

            //=========== 帧同步：VSYNC 上升沿开启新帧窗口 ===========
            if (vsync_rise) begin
                frame_active <= 1'b1;
                frame_start  <= 1'b1;
                col_cnt      <= {CW{1'b0}};
                line_num     <= {CW{1'b0}};
                byte_sel     <= 1'b0;
            end

            if (frame_active) begin
                if (href_act) begin
                    //---------- 一行内的有效像素 ----------
                    if ((col_cnt < H_ACTIVE) && (line_num < V_ACTIVE)) begin
                        if (BPW == 1) begin
                            // 8bit：每拍一个像素
                            px_data    <= {{(PIX_W-8){1'b0}}, d_i};
                            px_we      <= 1'b1;
                            col_num    <= col_cnt;
                            line_start <= (col_cnt == {CW{1'b0}});
                            line_end   <= (col_cnt == H_ACTIVE - 1);
                            col_cnt    <= col_cnt + 1'b1;
                        end else begin
                            // 16bit RGB565：两字节拼一个像素
                            if (!byte_sel) begin
                                byte_lo  <= d_i;
                                byte_sel <= 1'b1;
                            end else begin
                                px16[15:8] <= MSB_FIRST ? d_i     : byte_lo;
                                px16[7:0]  <= MSB_FIRST ? byte_lo : d_i;
                                px_data    <= px16[PIX_W-1:0];
                                px_we         <= 1'b1;
                                col_num       <= col_cnt;
                                line_start    <= (col_cnt == {CW{1'b0}});
                                line_end      <= (col_cnt == H_ACTIVE - 1);
                                col_cnt       <= col_cnt + 1'b1;
                                byte_sel      <= 1'b0;
                            end
                        end
                    end
                    // col_cnt >= H_ACTIVE：多余像素直接丢弃，不改列计数（防错位）
                end else begin
                    //---------- HREF 下降沿 = 一行结束 ----------
                    byte_sel <= 1'b0;
                    if (col_cnt != {CW{1'b0}}) begin
                        col_cnt  <= {CW{1'b0}};
                        line_num <= line_num + 1'b1;
                        // 采满 V_ACTIVE 行后关闭帧窗口
                        if (line_num + 1'b1 >= V_ACTIVE)
                            frame_active <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
