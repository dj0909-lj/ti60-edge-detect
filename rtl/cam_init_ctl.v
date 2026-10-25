`timescale 1ns/1ps
//=============================================================================
//  cam_init_ctl.v —— 摄像头寄存器初始化序列器
//-----------------------------------------------------------------------------
//  工作方式：
//    1) 复位后处于 IDLE，等待 start 拉高；
//    2) 依次读取寄存器表 LUT_INDEX = 0,1,2,...LUT_SIZE-1；
//    3) 每条经 i2c_master 写完（done）后，等待 GAP_MS 毫秒再写下一条
//       —— OV5640 写 0x3008=0x82（软复位）后必须等 5ms 才能继续，
//          统一留 5ms 间隔最省心；
//    4) 全部写完 → done 拉高，busy 拉低。
//
//  寄存器表直接复用厂商验证过的 LUT 模块（case 查表，综合成 LUT/ROM）：
//    CAM_MODEL = 0 : I2C_OV5640_1280720_Config   彩色 RGB565, 252 条
//    CAM_MODEL = 1 : I2C_AR0135_1280720_Config   黑白 8/16bit, 24 条
//  两张表接口一致（LUT_INDEX→LUT_DATA/LUT_SIZE），差别只在 24bit / 32bit 打包：
//    OV5640: {reg[15:0], data[7:0]}      → 16bit 地址 + 8bit 数据
//    AR0135: {reg[15:0], data[15:0]}     → 16bit 地址 + 16bit 数据
//
//  ⚠️ 换摄像头时只需改 CAM_MODEL + 把对应 LUT 文件加入工程，RTL 零改动。
//=============================================================================
module cam_init_ctl #(
    parameter CLK_FREQ  = 50_000_000,
    parameter SCL_FREQ  = 100_000,
    parameter CAM_MODEL = 0,          // 0 = OV5640(彩色), 1 = AR0135(黑白)
    parameter GAP_MS    = 5           // 条目间延时（ms）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,          // 拉高启动一次配置
    output wire        scl,
    input  wire        sda_i,          // I2C SDA 读（拆分式，Efinity 顶层无 inout）
    output wire        sda_o,          // I2C SDA 写
    output wire        sda_oe,         // I2C SDA 输出使能
    output wire        busy,           // 配置进行中
    output reg         done,           // 配置完成（1 拍）
    output reg         ack_err,        // 出现过 NACK
    output wire [7:0]  prog            // 进度索引（可送 LED 观察）
);

    localparam DEV_ADDR = (CAM_MODEL == 0) ? 7'h3C : 7'h10;  // 0x78>>1 / 0x20>>1
    localparam REG_AW   = 16;
    localparam DATA_W   = (CAM_MODEL == 0) ? 8 : 16;
    localparam integer GAP_CYC = (CLK_FREQ / 1000) * GAP_MS;

    //====================== ① 寄存器表（厂商 LUT）======================
    reg  [7:0]        idx;
    wire [7:0]        lut_size;
    wire [REG_AW-1:0] reg_addr;
    wire [DATA_W-1:0] wr_data;

    generate
    if (CAM_MODEL == 0) begin : g_color
        wire [23:0] lut_data;
        I2C_OV5640_1280720_Config u_tbl (
            .LUT_INDEX (idx),
            .LUT_DATA  (lut_data),
            .LUT_SIZE  (lut_size)
        );
        assign reg_addr = lut_data[23:8];
        assign wr_data  = lut_data[7:0];
    end else begin : g_mono
        wire [31:0] lut_data;
        I2C_AR0135_1280720_Config u_tbl (
            .LUT_INDEX (idx),
            .LUT_DATA  (lut_data),
            .LUT_SIZE  (lut_size)
        );
        assign reg_addr = lut_data[31:16];
        assign wr_data  = lut_data[15:0];
    end
    endgenerate

    //====================== ② I2C 主机 ======================
    reg         i2c_start;
    wire        i2c_done;
    wire        i2c_ackerr;

    i2c_master #(
        .CLK_FREQ (CLK_FREQ),
        .SCL_FREQ (SCL_FREQ),
        .REG_AW   (REG_AW),
        .DATA_W   (DATA_W)
    ) u_i2c (
        .clk       (clk),
        .rst_n     (rst_n),
        .cmd_start (i2c_start),
        .dev_addr  (DEV_ADDR),
        .reg_addr  (reg_addr),
        .wr_data   (wr_data),
        .done      (i2c_done),
        .ack_err   (i2c_ackerr),
        .scl       (scl),
        .sda_i     (sda_i),
        .sda_o     (sda_o),
        .sda_oe    (sda_oe)
    );

    //====================== ③ 序列器 FSM ======================
    localparam S_IDLE = 3'd0, S_REQ = 3'd1, S_WAIT = 3'd2,
               S_GAP  = 3'd3, S_FIN = 3'd4;
    reg [2:0]  st;
    reg        busy_r;
    reg [31:0] gap_cnt;

    assign busy = busy_r;
    assign prog = idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            idx       <= 8'd0;
            i2c_start <= 1'b0;
            busy_r    <= 1'b0;
            done      <= 1'b0;
            ack_err   <= 1'b0;
            gap_cnt   <= 32'd0;
        end else begin
            i2c_start <= 1'b0;
            done      <= 1'b0;
            case (st)
                //---- 等待启动 ----
                S_IDLE: begin
                    idx     <= 8'd0;
                    busy_r  <= 1'b0;
                    ack_err <= 1'b0;
                    if (start) begin
                        st     <= S_REQ;
                        busy_r <= 1'b1;
                    end
                end
                //---- 发起一条 I2C 写 ----
                S_REQ: begin
                    i2c_start <= 1'b1;
                    st        <= S_WAIT;
                end
                //---- 等 I2C 完成 ----
                S_WAIT: begin
                    if (i2c_done) begin
                        ack_err <= ack_err | i2c_ackerr;
                        if (idx + 1'b1 >= lut_size) begin
                            st <= S_FIN;              // 全部写完
                        end else begin
                            st      <= S_GAP;         // 先等 GAP 再写下一条
                            gap_cnt <= 32'd0;
                        end
                    end
                end
                //---- 条目间延时（软复位 / PLL 锁定需要）----
                S_GAP: begin
                    gap_cnt <= gap_cnt + 1'b1;
                    if (gap_cnt >= GAP_CYC - 1) begin
                        idx <= idx + 1'b1;
                        st  <= S_REQ;
                    end
                end
                //---- 完成 ----
                S_FIN: begin
                    busy_r <= 1'b0;
                    done   <= 1'b1;
                    st     <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
