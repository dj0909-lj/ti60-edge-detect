`timescale 1ns/1ps
//=============================================================================
//  edge_detect_syn_top.v —— 赛题四「综合验证顶层」（含摄像头采集的完整链路）
//-----------------------------------------------------------------------------
//  与 edge_detect_top.v（纯算法链顶层）的区别：
//    本模块把「DVP 摄像头采集 + I2C 初始化」也纳进来，用于 Efinity 综合 / 上板，
//    是真正意义上的整机顶层。
//
//      ┌─────────────┐   RGB565    ┌──────────┐
//      │ dvp_capture ├────────────►│ 565→888  │
//      └──────┬──────┘             └────┬─────┘
//             │ px_we / sof / col / line │ r,g,b
//             │                          ▼
//             │            ┌──────────────────────────────┐
//             │            │        edge_detect_top       │
//             │            │  灰度化→行缓存→中值→行缓存→Sobel │
//             │            │        →阈值→显示合成          │
//             │            └──────────────┬───────────────┘
//             │                           │ rgb_out[23:0]
//      ┌──────▼────────┐                  ▼
//      │ cam_init_ctl  ├─ scl/sda ─► 摄像头      显示器（HDMI）
//      │ (I2C 寄存器表) │
//      └───────────────┘
//
//  ⚠️ 时钟说明（重要）：
//    本文件为「综合验证」用途，全链路统一用单时钟 clk（方案 A：单时钟域）。
//    上板若摄像头 PCLK 与显示像素时钟不同频（例如 OV5640 RGB565 24/48MHz
//    vs HDMI 25.175MHz），必须在 cam_pclk 与 clk 之间插入**像素级异步 FIFO**
//    （方案 B）—— 否则就是跨时钟域直接连，属于功能隐患。
//    当前把 cam_pclk 作为独立输入保留，正是为将来插 FIFO 留好接口。
//
//  ⚠️ 上板还需要（不在本文件内）：
//    HDMI TMDS 编码 / 显示时序发生器 / PLL；见 04 文档「上板集成清单」。
//=============================================================================
module edge_detect_syn_top #(
    parameter H_ACTIVE  = 640,          // 采集行宽（也作为显示宽度）
    parameter V_ACTIVE  = 480,          // 采集行数
    parameter CAM_PIX_W = 16,           // 16 = RGB565 彩色(OV5640) / 8 = 黑白(AR0135)
    parameter CAM_MODEL = 0,            // 0 = OV5640 / 1 = AR0135
    parameter CW        = 12,           // 坐标位宽
    parameter TW        = 12,           // 梯度/阈值位宽
    parameter CLK_FREQ  = 50_000_000,   // clk 频率（I2C 分频用）
    parameter DEB_CNT_W = 19            // 按键消抖计数位宽
)(
    // ---- 时钟与复位 ----
    input  wire          clk,           // 系统 / 像素时钟
    input  wire          rst_n,
    // ---- DVP 摄像头接口 ----
    input  wire          cam_pclk,      // 摄像头像素时钟（本文件内暂不使用时序，留待插 FIFO）
    input  wire          cam_vsync,
    input  wire          cam_href,
    input  wire [7:0]    cam_data,
    // ---- 摄像头 I2C 配置总线 ----
    output wire          cam_scl,
    inout  wire          cam_sda,
    // ---- 板载控制 ----
    input  wire [1:0]    key,           // key[0]=阈值+  key[1]=阈值-
    input  wire          median_en,     // 1 = 打开中值滤波
    input  wire [1:0]    disp_mode,     // 0=分屏 1=画中画 2=彩色叠加 3=纯边缘
    // ---- 输出 ----
    output wire [23:0]   rgb_out,       // 送显示（HDMI TMDS 编码前）
    output wire          out_valid,     // 输出像素有效
    output wire [TW-1:0] threshold_o,   // 当前阈值
    output wire [3:0]    led            // 状态指示
);

    //=================================================================
    // ① 摄像头采集（DVP）
    //=================================================================
    wire [CAM_PIX_W-1:0] px_data;
    wire                 px_we;
    wire [CW-1:0]        col_num;
    wire [CW-1:0]        line_num;
    wire                 frame_start;
    wire                 line_start_unused;
    wire                 line_end_unused;
    wire                 frame_active;

    dvp_capture #(
        .PIX_W          (CAM_PIX_W),
        .H_ACTIVE       (H_ACTIVE),
        .V_ACTIVE       (V_ACTIVE),
        .VSYNC_ACT_HIGH (1),
        .HREF_ACT_HIGH  (1),
        .MSB_FIRST      (1),
        .CW             (CW)
    ) u_cap (
        .pclk         (cam_pclk),
        .rst_n        (rst_n),
        .vsync_i      (cam_vsync),
        .href_i       (cam_href),
        .d_i          (cam_data),
        .px_data      (px_data),
        .px_we        (px_we),
        .col_num      (col_num),
        .line_num     (line_num),
        .frame_start  (frame_start),
        .line_start   (line_start_unused),
        .line_end     (line_end_unused),
        .frame_active (frame_active)
    );

    //=================================================================
    // ② RGB565 → RGB888（8bit 单色则三分量同值）
    //=================================================================
    wire [7:0] r8, g8, b8;

    generate
    if (CAM_PIX_W == 16) begin : g_color
        // RGB565 扩展：R/B 高 3 位回填、G 高 2 位回填（误差 <1 LSB）
        wire [4:0] r5 = px_data[15:11];
        wire [5:0] g6 = px_data[10:5];
        wire [4:0] b5 = px_data[4:0];
        assign r8 = {r5, r5[4:2]};
        assign g8 = {g6, g6[5:4]};
        assign b8 = {b5, b5[4:2]};
    end else begin : g_mono
        assign r8 = px_data[7:0];
        assign g8 = px_data[7:0];
        assign b8 = px_data[7:0];
    end
    endgenerate

    //=================================================================
    // ③ 完整算法链 + 显示合成（已通过 8 轮自检仿真）
    //=================================================================
    edge_detect_top #(
        .IMG_W     (H_ACTIVE),
        .H_ACT      (H_ACTIVE),
        .V_ACT      (V_ACTIVE),
        .TW         (TW),
        .CW         (CW),
        .DEB_CNT_W  (DEB_CNT_W)
    ) u_core (
        .clk         (clk),
        .rst_n       (rst_n),
        .sof         (frame_start),
        .de          (px_we),
        .r           (r8),
        .g           (g8),
        .b           (b8),
        .x           (col_num),
        .y           (line_num),
        .key         (key),
        .median_en   (median_en),
        .disp_mode   (disp_mode),
        .rgb_out     (rgb_out),
        .out_valid   (out_valid),
        .threshold_o (threshold_o)
    );

    //=================================================================
    // ④ 摄像头 I2C 初始化（上电约 1ms 后自动启动）
    //=================================================================
    reg [19:0] pwr_cnt;
    reg        init_start;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pwr_cnt    <= 20'd0;
            init_start <= 1'b0;
        end else if (!init_start) begin
            pwr_cnt <= pwr_cnt + 1'b1;
            if (pwr_cnt == 20'hFFFFF)          // ≈1ms @50MHz，等电源与 PLL 稳定
                init_start <= 1'b1;
        end else begin
            init_start <= 1'b0;                // 单拍脉冲
        end
    end

    wire cam_busy, cam_done, cam_ackerr;

    cam_init_ctl #(
        .CLK_FREQ  (CLK_FREQ),
        .SCL_FREQ  (100_000),
        .CAM_MODEL (CAM_MODEL),
        .GAP_MS    (5)
    ) u_init (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (init_start),
        .scl     (cam_scl),
        .sda     (cam_sda),
        .busy    (cam_busy),
        .done    (cam_done),
        .ack_err (cam_ackerr),
        .prog    ()
    );

    //=================================================================
    // ⑤ 状态指示
    //=================================================================
    reg        hb;                 // 帧心跳：每来一帧翻转一次
    reg        cam_done_lat;
    reg        cam_err_lat;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hb           <= 1'b0;
            cam_done_lat <= 1'b0;
            cam_err_lat  <= 1'b0;
        end else begin
            if (frame_start)  hb           <= ~hb;
            if (cam_done)     cam_done_lat <= 1'b1;
            if (cam_ackerr)   cam_err_lat  <= 1'b1;
        end
    end

    assign led = {cam_err_lat, cam_done_lat, cam_busy, hb};

endmodule
