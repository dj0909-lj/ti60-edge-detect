`timescale 1ns/1ps
//=============================================================================
//  debounce.v —— 按键消抖（配合高阶挑战 2「实时阈值调节」）
//
//  原理：按键抖动通常 < 10ms。用一个计数器连续采样到同一个电平达到
//        CNT_MAX 个时钟才认为电平稳定。25MHz 下取 2^19 = 524288 约 21ms。
//
//  输出：
//    key_out   —— 消抖后的稳定电平
//    key_press —— 按下瞬间的单周期脉冲（上升沿），阈值步进用它
//=============================================================================
module debounce #(
    parameter CNT_W = 19
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,      // 原始按键输入（低有效或高有效均可，此处按高有效处理）
    output reg  key_out,
    output wire key_press
);

    reg [CNT_W-1:0] cnt;
    reg             key_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= {CNT_W{1'b0}};
            key_out <= 1'b0;
        end else if (key_in == key_out) begin
            cnt <= {CNT_W{1'b0}};               // 电平一致，清计数
        end else begin
            cnt <= cnt + 1'b1;
            if (cnt == {CNT_W{1'b1}}) begin     // 稳定够久，认可新电平
                key_out <= key_in;
                cnt     <= {CNT_W{1'b0}};
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) key_d <= 1'b0;
        else        key_d <= key_out;
    end

    assign key_press = key_out & ~key_d;        // 按下瞬间的单周期脉冲

endmodule
