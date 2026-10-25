`timescale 1ns/1ns
//=============================================================================
//  wb_awb.v —— 自动白平衡（AWB，灰度世界法 + 无除法器积分控制）
//  赛题【基础要求 2】相关扩展；替代 v5 的固定增益 wb_apply
//
//  ═══════════ 为什么需要 ═══════════
//  SC2210 输出 RAW Bayer。Bayer 阵列(RGGB)里绿像素数量是红/蓝的 2 倍，
//  且绿通道量子效率通常更高 —— 不做白平衡时白光必然【偏绿】。
//  厂商 04-1 HDMI 基线【完全没有白平衡】，所以它发绿是必然现象。
//
//  v2/v3/v5 用【固定增益】盲调，实测过程：
//      v2: R1.75x/B1.50x -> 偏粉（红加多了）
//      v3: R1.25x/B1.125x -> 偏绿（红加少了）
//      v5: R1.50x/B1.25x -> 折中，仍偏绿
//  三轮盲调都不到位 => 改用【自动】白平衡，适应不同光源。
//
//  ═══════════ 算法：灰度世界法（Gray World）═══════════
//  假设：一幅自然图像的平均颜色应为灰色 => R_avg = G_avg = B_avg
//  令 G 通道保持 1.0x，则目标增益 R_gain = G_avg/R_avg, B_gain = G_avg/B_avg
//
//  ⚠️ 关键：怎样【不用除法器】求出这个比值
//      直接做 G_avg/R_avg 需要除法（赛题要求避免除法器）。
//      本模块改用【有符号积分控制器】逐帧逼近：
//          帧末比较 R_avg(增益后) 与 G_avg
//            if (R_avg + 死区 < G_avg)  R_gain <= R_gain + 1;   // 红不够，加红
//            if (R_avg > G_avg + 死区)  R_gain <= R_gain - 1;   // 红过多，减红
//          R_avg 与 G_avg 采样数相同 => 可直接相减比较，无需归一化、无需除法。
//      增益为 Q4.4 定点（16 = 1.0x），每帧步进 1 LSB (1/16 = 6.25%)。
//      收敛速度：需调整 ±16 档时约 16~30 帧 ≈ 0.3~0.5s @60fps。
//
//  ═══════════ 稳定性设计 ═══════════
//  1) 死区 DEADBAND = sum_g >> DEADBAND_SHIFT（默认 1/64 ≈ 1.6%）
//     => 进入死区后不再调整，防止在目标点附近来回抖动。
//  2) 增益钳位 GAIN_MIN..GAIN_MAX（默认 0.5x..3.0x），防止极端场景跑飞。
//  3) 暗场保护：仅在 G >= DARK_LEVEL 时采样，避免暗场噪声主导统计。
//  4) 帧边界：检测 vsync 跳变沿触发一次增益更新 —— 对极性不敏感。
//  5) 采样抽稀：每 2^SAMPLE_SHIFT 个像素采一次，降低累加器位宽与翻转率。
//     1920x1080 下每行 120 个采样点，整帧约 129,600 点
//     => 累加和最大 129600*255 = 33.05e6 < 2^26，用 28bit 留足余量。
//  6) 足够性检查：统计量太低（刚上电/极暗）时不调整。
//
//  ═══════════ 时序（⚠️ 不可更改）═══════════
//  延迟【严格 1 拍】—— 与它替代的 wb_apply 完全一致。
//  顶层 display_mux 的 DELAY_COLOR=12 是按彩色支路深度标定的，
//  AWB 若改变延迟会造成叠加模式（mode=3）红边错位。
//  旁路 en=0 时同样延 1 拍输出，保证时序不变。
//=============================================================================
module wb_awb
#(
    parameter        SAMPLE_SHIFT   = 4,        // 每 2^4 = 16 个像素采一次
    parameter [5:0]  GAIN_MIN       = 6'd8,     // 0.500x  (8/16)
    parameter [5:0]  GAIN_MAX       = 6'd48,    // 3.000x  (48/16)
    parameter [5:0]  R_GAIN_INIT    = 6'd24,    // 1.500x 起始值（继承 v5 经验值）
    parameter [5:0]  B_GAIN_INIT    = 6'd20,    // 1.250x 起始值
    parameter        DEADBAND_SHIFT = 4,        // 死区 = sum_g >> 4（见下方推导，勿随意改）
    parameter [7:0]  DARK_LEVEL     = 8'd16,    // 暗场保护门限
    parameter [23:0] MIN_SAMPLES    = 24'd1024, // 每帧最少有效采样点数（见下）
    parameter        SHIFT          = 4         // Q4.4 定点
)
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,          // 1 = 启用自动白平衡; 0 = 旁路

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
    output reg  [7:0]  b_out,

    // 调试：当前生效增益（Q4.4，16 = 1.0x）。可接 LED 观察收敛过程。
    output wire [5:0]  r_gain_o,
    output wire [5:0]  b_gain_o,
    output wire        awb_stat_o    // 1 = 本拍统计有效（非暗场）
);

//=============================================================================
// 1. 增益寄存器（Q4.4）
//=============================================================================
reg [5:0] r_gain = R_GAIN_INIT;
reg [5:0] b_gain = B_GAIN_INIT;

assign r_gain_o = r_gain;
assign b_gain_o = b_gain;

//=============================================================================
// 2. 逐像素乘法 + 饱和（组合）
//    prod = v * gain >> SHIFT ，上限 255
//
//  ⚠️ 为什么【不用 `*` 运算符】而要显式写成移位加法树：
//     用 `v * gain` 时，因 gain 是【运行时寄存器】、综合器无法常量折叠，
//     会推断出真实的 DSP 乘法器（实测占 2 个 EFX_DSP24）。
//     但 gain 只有 6 位，完全可以用移位加法展开：
//         v * gain = Σ (gain[k] ? v<<k : 0)   k = 0..5
//     ⇒ 6 个条件加法 + 5 个移位，无乘法器、无 DSP。
//     这正合赛题原文要求：「使用 DSP 块【或移位加法】实现乘法运算，避免除法器」。
//     改用移位加法后 DSP 占用回到 0（见 19 号文档 §3.2）。
//
//     代价：多消耗少量 LUT/ADD（见 24 号文档 §6.2 实测对比）。
//=============================================================================
function [7:0] scale_sat;
    input [7:0]  v;
    input [5:0]  gain;
    reg   [13:0] prod;          // v*gain 最大 255*48 = 12240 < 2^14
    begin
        // ---- 移位加法树：逐位条件累加 ----
        prod = 14'd0;
        if (gain[0]) prod = prod + {6'd0, v};                    // v << 0
        if (gain[1]) prod = prod + {5'd0, v, 1'b0};              // v << 1
        if (gain[2]) prod = prod + {4'd0, v, 2'b0};              // v << 2
        if (gain[3]) prod = prod + {3'd0, v, 3'b0};              // v << 3
        if (gain[4]) prod = prod + {2'd0, v, 4'b0};              // v << 4
        if (gain[5]) prod = prod + {1'd0, v, 5'b0};              // v << 5
        // ---- Q4.4 -> 整数，并饱和到 255 ----
        prod = prod >> SHIFT;
        scale_sat = (prod > 14'd255) ? 8'd255 : prod[7:0];
    end
endfunction

wire [7:0] r_scaled = en ? scale_sat(r_in, r_gain) : r_in;
wire [7:0] b_scaled = en ? scale_sat(b_in, b_gain) : b_in;
wire [7:0] g_scaled = g_in;                 // G 为基准通道，保持 1.0x

//=============================================================================
// 3. 输出寄存 —— 严格 1 拍延迟（与 wb_apply 一致，勿改）
//=============================================================================
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
        r_out     <= r_scaled;
        g_out     <= g_scaled;
        b_out     <= b_scaled;
    end
end

//=============================================================================
// 4. 抽样脉冲（每 2^SAMPLE_SHIFT 个像素一次）+ 暗场保护
//=============================================================================
reg  [SAMPLE_SHIFT-1:0] sample_cnt = 0;
wire sample_tick = (sample_cnt == {SAMPLE_SHIFT{1'b0}});

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) sample_cnt <= 0;
    else        sample_cnt <= sample_cnt + 1'b1;
end

wire stat_en = en & in_href & sample_tick & (g_scaled >= DARK_LEVEL);

assign awb_stat_o = stat_en;

//=============================================================================
// 5. 帧统计累加 + 增益更新（单一 always 块，避免多驱动）
//    帧边界：vsync 跳变沿
//=============================================================================
localparam integer AW = 28;                 // 累加器位宽（见文件头核算）

reg [AW-1:0] sum_r = 0;
reg [AW-1:0] sum_g = 0;
reg [AW-1:0] sum_b = 0;
reg [23:0]   sample_num = 0;                // 本帧有效采样点数

reg vsync_d = 1'b0;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) vsync_d <= 1'b0;
    else        vsync_d <= in_vsync;
end

wire frame_tick = (in_vsync != vsync_d);    // 任意跳变沿

// 比较量（扩展 1 bit 防加法截断）
//
// ═══ 死区取值的推导（不要凭感觉改）═══
// 判据：hunting（增益在 N/N+1 间每帧来回跳 -> 颜色以帧频闪烁）
//       发生在  死区 < r_in/32 。
// 代入 死区 ≈ sum_g >> shift ≈ (r_in*g/16) >> shift ：
//       r_in*g/(16*2^shift) < r_in/32   =>   g < 2^shift / 2
// 增益最小值为 GAIN_MIN=8，故要求 2^shift/2 <= 8 => 2^shift <= 16
//       =>  shift <= 4
// 取 shift=4（死区 6.25%）可覆盖全部增益范围。
//
// 穷举验证（analyze_deadband.py，61200 组 (R_in,G_in) 组合）：
//       shift=4 -> hunting 0.01%    ← 采用
//       shift=5 -> hunting 6.80%
//       shift=6 -> hunting 24.83%
//       shift=7 -> hunting 42.36%
//
// 代价：死区 6.25% 意味着收敛精度约 ±6%，与 Q4.4 增益本身 1 LSB(6.25%) 的
//       量化精度同阶，故不额外损失有效精度。
wire [AW:0] deadband  = {1'b0, (sum_g >> DEADBAND_SHIFT)};
wire [AW:0] sum_g_x   = {1'b0, sum_g};
wire [AW:0] sum_r_x   = {1'b0, sum_r};
wire [AW:0] sum_b_x   = {1'b0, sum_b};

wire [AW:0] r_plus_db = sum_r_x + deadband;
wire [AW:0] g_plus_db = sum_g_x + deadband;

wire r_too_low  = (r_plus_db < sum_g_x);        // 红偏低 => 加红
wire r_too_high = (sum_r_x  > g_plus_db);       // 红偏高 => 减红
wire b_too_low  = (sum_b_x + deadband < sum_g_x);
wire b_too_high = (sum_b_x > g_plus_db);

// 最少有效采样点数：低于此值认为统计不可信，不调整增益。
// 1920x1080 每 16 像素采一次 => 每行 120 点、整帧约 129,600 点，
// 故默认 1024（约 8.5 行）足够宽松。
// ⚠️ 该值按【真实分辨率】设定；仿真里用小帧时必须相应调小，
//    否则一帧采样数达不到门限、控制环看起来"不工作"。
wire enough = (sample_num >= MIN_SAMPLES);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sum_r <= 0; sum_g <= 0; sum_b <= 0; sample_num <= 0;
        r_gain <= R_GAIN_INIT;
        b_gain <= B_GAIN_INIT;
    end else if (frame_tick) begin
        // ---- 帧末：按本帧统计调整增益，然后清统计 ----
        sum_r <= 0;
        sum_g <= 0;
        sum_b <= 0;
        sample_num <= 0;

        if (en && enough) begin
            // R 通道
            if (r_too_low) begin
                if (r_gain < GAIN_MAX) r_gain <= r_gain + 1'b1;
            end else if (r_too_high) begin
                if (r_gain > GAIN_MIN) r_gain <= r_gain - 1'b1;
            end
            // B 通道
            if (b_too_low) begin
                if (b_gain < GAIN_MAX) b_gain <= b_gain + 1'b1;
            end else if (b_too_high) begin
                if (b_gain > GAIN_MIN) b_gain <= b_gain - 1'b1;
            end
        end
    end else if (stat_en) begin
        // ---- 帧内：累加抽样像素（增益后值 => 闭环反馈）----
        sum_r      <= sum_r + {{(AW-8){1'b0}}, r_scaled};
        sum_g      <= sum_g + {{(AW-8){1'b0}}, g_scaled};
        sum_b      <= sum_b + {{(AW-8){1'b0}}, b_scaled};
        sample_num <= sample_num + 1'b1;
    end
end

endmodule
