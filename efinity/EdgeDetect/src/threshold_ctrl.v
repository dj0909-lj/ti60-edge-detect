`timescale 1ns/1ps
//=============================================================================
//  threshold_ctrl.v —— 阈值实时调节寄存器（高阶挑战 2）
//
//  官方技术提示：「阈值调节是性价比最高的加分项」，只需在 Sobel 输出比较前
//                 增加一个可配置寄存器，用按键增减其值。
//
//  行为：
//    - inc 脉冲 -> 阈值 +STEP（边缘变少）
//    - dec 脉冲 -> 阈值 -STEP（边缘变多）
//    - 上下限钳位在 [TH_MIN, TH_MAX]
//
//  阈值范围说明：G = |Gx|+|Gy| 最大 2040，因此阈值 12bit（0~4095）足够，
//                默认上限取 TH_MAX，保证既不恒白也不恒黑。
//=============================================================================
module threshold_ctrl #(
    parameter TW     = 12,
    parameter STEP   = 12'd16,       // 步进，避免一下跳过头
    parameter TH_INIT= 12'd64,       // 上电初值
    parameter TH_MAX = 12'd2040,     // 上限 = 梯度理论最大值
    parameter TH_MIN = 12'd0
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          inc,        // 单周期脉冲
    input  wire          dec,        // 单周期脉冲
    output reg  [TW-1:0] threshold
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            threshold <= TH_INIT;
        end else if (inc) begin
            if (threshold + STEP > TH_MAX) threshold <= TH_MAX;
            else                           threshold <= threshold + STEP;
        end else if (dec) begin
            if (threshold < STEP)          threshold <= TH_MIN;
            else                           threshold <= threshold - STEP;
        end
    end

endmodule
