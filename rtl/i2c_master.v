`timescale 1ns/1ps
//=============================================================================
//  i2c_master.v —— 通用 I2C 主机（摄像头寄存器配置用）
//-----------------------------------------------------------------------------
//  一次传输 = [START] [从机地址+W] [ACK] [寄存器地址 n 字节] [ACK] [数据 m 字节] [ACK] [STOP]
//
//  为什么寄存器地址/数据要参数化：
//    OV5640 (彩色) ：16bit 寄存器地址 + 8bit  数据  → REG_AW=16, DATA_W=8
//    AR0135 (黑白) ：16bit 寄存器地址 + 16bit 数据  → REG_AW=16, DATA_W=16
//    MT9M001(黑白) ： 8bit 寄存器地址 + 16bit 数据  → REG_AW=8,  DATA_W=16
//
//  用法：
//    拉高 cmd_start 单拍（同时 dev_addr/reg_addr/wr_data 已有效），
//    等待 done 拉高一拍即完成一条；传输过程中不要改参数。
//    ack_err 在整条传输结束时给出累计结果（从机没应答 → 1）。
//
//  时序：SCL 由 CLK_FREQ/SCL_FREQ 分频产生，半周期 = CLK_FREQ/(SCL_FREQ*2) 拍。
//        字节 MSB 先出；SCL 高电平期间从机采样，主机在 SCL 低电平换数据。
//=============================================================================
module i2c_master #(
    parameter CLK_FREQ = 50_000_000,   // 输入时钟频率
    parameter SCL_FREQ = 100_000,      // I2C 时钟频率（标准 100kHz）
    parameter REG_AW   = 8,            // 寄存器地址位宽：8 / 16
    parameter DATA_W   = 8             // 数据位宽：8 / 16
)(
    input  wire                clk,
    input  wire                rst_n,
    // ---- 命令接口 ----
    input  wire                cmd_start,   // 启动一次传输（单拍）
    input  wire [6:0]          dev_addr,    // 从机 7bit 地址
    input  wire [REG_AW-1:0]   reg_addr,    // 寄存器地址
    input  wire [DATA_W-1:0]   wr_data,     // 写入数据
    output reg                 done,        // 传输完成（1 拍）
    output reg                 ack_err,     // 出现 NACK
    // ---- I2C 物理总线 ----
    //  ⚠️ Efinity/Titanium 顶层不支持 inout（EFX-0265），
    //     所以 SDA 在这里就拆成 i/o/oe 三根线。上板时由 Interface Designer
    //     把这三根合并到同一个双向 PAD（厂商 Ti60_Demo 也是这么做的：
    //     端口名 cmos_sdat_IN / cmos_sdat_OUT / cmos_sdat_OE）。
    output reg                 scl,
    input  wire                sda_i,
    output reg                 sda_o,
    output reg                 sda_oe
);

    // 一条传输要发送的总字节数 = 地址(1) + 寄存器地址 + 数据
    localparam NB_REG  = REG_AW / 8;
    localparam NB_DAT  = DATA_W / 8;
    localparam NBYTES  = 1 + NB_REG + NB_DAT;
    localparam TXW     = 8 * NBYTES;      // 发送移位寄存器总位宽
    localparam integer HALF = CLK_FREQ / (SCL_FREQ * 2);   // SCL 半周期计数值

    // ---- 三态 SDA（已拆分为 i/o/oe 三线，无需内部 inout）----
    // oe=1 时由 sda_o 驱动总线，oe=0 时外部上拉使总线为高（读 sda_i）

    // ---- 状态机 ----
    localparam IDLE = 3'd0, START = 3'd1, BITS = 3'd2, ACK = 3'd3, STOP = 3'd4;
    reg [2:0]    state;
    reg [31:0]   cnt;        // 半周期计时
    reg [2:0]    bit_n;      // 当前字节内位序号 0..7
    reg [3:0]    sent;       // 已发送字节数
    reg [TXW-1:0] tx_sh;     // 待发送序列：{dev_addr,W}{reg_addr}{wr_data}
    reg          nack;       // 累计 NACK

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= IDLE;
            scl     <= 1'b1;
            sda_o   <= 1'b1;
            sda_oe  <= 1'b0;
            done    <= 1'b0;
            ack_err <= 1'b0;
            cnt     <= 32'd0;
            bit_n   <= 3'd0;
            sent    <= 4'd0;
            tx_sh   <= {TXW{1'b1}};
            nack    <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                //----------------- 空闲 -----------------
                IDLE: begin
                    scl    <= 1'b1;
                    sda_oe <= 1'b0;
                    sda_o  <= 1'b1;
                    nack   <= 1'b0;
                    if (cmd_start) begin
                        // 组装发送序列：MSB 先出
                        tx_sh <= {dev_addr, 1'b0, reg_addr, wr_data};
                        sent  <= 4'd0;
                        cnt   <= 32'd0;
                        state <= START;
                    end
                end
                //----------------- START：SCL 高时 SDA 1->0 -----------------
                START: begin
                    scl <= 1'b1;
                    if (cnt == 0) begin
                        sda_oe <= 1'b1;
                        sda_o  <= 1'b1;
                    end
                    if (cnt == HALF - 1) sda_o <= 1'b0;     // 拉低 SDA = START
                    cnt <= cnt + 1'b1;
                    if (cnt == 2*HALF - 1) begin
                        scl   <= 1'b0;
                        bit_n <= 3'd0;
                        cnt   <= 32'd0;
                        state <= BITS;
                    end
                end
                //----------------- 逐位发送一个字节（MSB 先出）-----------------
                BITS: begin
                    if (cnt < HALF) begin
                        scl <= 1'b0;                        // SCL 低：换数据
                        if (cnt == 0) sda_o <= tx_sh[TXW-1];
                    end else begin
                        scl <= 1'b1;                        // SCL 高：从机采样
                        if (cnt == 2*HALF - 1) begin
                            tx_sh <= tx_sh << 1;            // 移出下一位
                            cnt   <= 32'd0;
                            if (bit_n == 3'd7) begin
                                sda_oe <= 1'b0;             // 释放 SDA 等 ACK
                                state  <= ACK;
                            end else begin
                                bit_n <= bit_n + 1'b1;
                            end
                        end else begin
                            cnt <= cnt + 1'b1;
                        end
                    end
                end
                //----------------- 采样 ACK -----------------
                ACK: begin
                    if (cnt < HALF) begin
                        scl <= 1'b0;
                        cnt <= cnt + 1'b1;
                    end else begin
                        scl <= 1'b1;
                        if (cnt == HALF) begin
                            if (sda_i) nack <= 1'b1;       // SDA 高 = NACK
                        end
                        cnt <= cnt + 1'b1;
                        if (cnt == 2*HALF - 1) begin
                            sda_oe <= 1'b1;                 // 重新驱动 SDA
                            cnt    <= 32'd0;
                            bit_n  <= 3'd0;
                            if (sent == NBYTES - 1) begin
                                state <= STOP;              // 全部发完 → STOP
                            end else begin
                                sent  <= sent + 1'b1;
                                state <= BITS;
                            end
                        end
                    end
                end
                //----------------- STOP：SCL 高时 SDA 0->1 -----------------
                STOP: begin
                    if (cnt == 0) begin
                        scl    <= 1'b0;
                        sda_o  <= 1'b0;
                        sda_oe <= 1'b1;
                    end
                    if (cnt == HALF)   scl   <= 1'b1;
                    if (cnt == 2*HALF) sda_o <= 1'b1;       // 拉高 SDA = STOP
                    cnt <= cnt + 1'b1;
                    if (cnt == 3*HALF - 1) begin
                        state   <= IDLE;
                        sda_oe  <= 1'b0;
                        done    <= 1'b1;
                        ack_err <= nack;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
