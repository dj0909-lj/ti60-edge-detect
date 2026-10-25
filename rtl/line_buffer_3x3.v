`timescale 1ns/1ps
//=============================================================================
//  line_buffer_3x3.v —— 3×3 滑动窗口生成器
//  （赛题【基础要求】第 5 条 / 技术提示明确点名的「核心难点」）
//
//  原理：Sobel 需要同时访问 3 行同一列 -> 必须缓存 2 行。
//        本模块用 2 块行缓存 + 列移位寄存器，每来 1 个有效像素窗口滑动一格，
//        每个时钟输出一组完整的 3×3 窗口（p00..p22）。
//
//  数据通路：
//
//      pix_in ──┬──────────────────────────────────► row0_r （当前行，延迟 1 拍）
//               │
//               └─► lb1[col] ──► r1 ──────────────► row1   （上一行）
//                    写            │
//                    地址=当前列    └─► lb2[col] ──► r2 ──► row2 （上两行）
//
//      row0/row1/row2 再各经 2 级列移位，凑出 3 列 -> p00..p22
//
//  输出延迟：1 个时钟（窗口最右列 = 刚进入的像素）
//
//  ⚠️ 铁律 1：必须在 de（href / DE）有效时才写入行缓存！
//     若按像素时钟无条件写，行消隐期的空闲时钟会被当成像素写进去，
//     表现为画面从左到右越斜越多的「斜切」——这是本题最难查的 bug 之一。
//
//  ⚠️ 铁律 2：lb2 必须写入 lb1[rd_addr] 的「组合读值」（本列、上一行），
//     绝不能写已寄存的 r1 —— r1 是上一拍读出的，对应的是 col-1 列，
//     会让整个窗口错位一列。此坑已用 sim/tb_line_buffer.v 复现并验证修复。
//
//  ⚠️ 铁律 3：sof 那一拍同时也是行首，不要把 wr_col 清零，
//     否则第 0 行会整体错位一列（该行恰好被 win_valid 屏蔽，很难发现，
//     但会在第 2 行的输出里冒出来）。此坑同样已在单元测试中暴露。
//
//  资源：2 × IMG_W × DW bit，640 宽 8bit 即 1280 Byte，对 Ti60 可忽略。
//=============================================================================
module line_buffer_3x3 #(
    parameter IMG_W = 640,      // 图像行宽（像素数）
    parameter DW    = 8         // 像素位宽
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            de,          // 像素有效
    input  wire            sof,         // 帧起始脉冲（vsync 边沿）
    input  wire [DW-1:0]   pix_in,
    output wire            win_valid,   // 窗口数据有效
    output wire [DW-1:0]   p00, p01, p02,
    output wire [DW-1:0]   p10, p11, p12,
    output wire [DW-1:0]   p20, p21, p22
);

    localparam AW = $clog2(IMG_W);

    // 两块行缓存，深度 = 行宽（综合工具会推断为 BRAM）
    reg [DW-1:0] lb1 [0:IMG_W-1];
    reg [DW-1:0] lb2 [0:IMG_W-1];

    reg [AW-1:0] wr_col;      // 当前像素列号，同时是读写地址
    reg [15:0]   line_cnt;    // 已完成的行数
    reg          de_d;

    wire line_start = de & ~de_d;     // 行有效起始
    wire line_end   = ~de & de_d;     // 行有效结束

    // 行首那一拍 wr_col 还残留上一行的值，读地址强制回 0
    wire [AW-1:0] rd_addr = line_start ? {AW{1'b0}} : wr_col;

    reg [DW-1:0] r1, r2;      // 上一行 / 上两行 同列像素
    reg [DW-1:0] row0_r;      // 当前行，延迟 1 拍与 r1/r2 对齐

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d     <= 1'b0;
            wr_col   <= {AW{1'b0}};
            line_cnt <= 16'd0;
        end else begin
            de_d <= de;
            // 帧首清零行计数；wr_col 交给下面的 line_start 分支处理，
            // 因为 sof 那一拍同时也是第 0 行的行首（铁律 3）。
            if (sof)           line_cnt <= 16'd0;
            else if (line_end) line_cnt <= line_cnt + 16'd1;

            if (de) begin
                if (line_start) wr_col <= {{(AW-1){1'b0}}, 1'b1};
                else            wr_col <= wr_col + 1'b1;
            end
        end
    end

    // 读写同一地址：非阻塞赋值下 r1/r2 取到「被本行覆盖前」的旧值 —— 这是
    // 行缓存能只用 2 块存储就完成 3 行对齐的关键。
    always @(posedge clk) begin
        if (de && (rd_addr < IMG_W)) begin
            lb1[rd_addr] <= pix_in;
            lb2[rd_addr] <= lb1[rd_addr];   // 本列的「上一行」值；下一行再读出即「上两行」
        end
        r1     <= lb1[rd_addr];
        r2     <= lb2[rd_addr];
        row0_r <= pix_in;
    end

    // ---- 列移位：三行各延迟 2 拍，凑出 3 列 ----
    reg [DW-1:0] a0_d1, a0_d2;
    reg [DW-1:0] a1_d1, a1_d2;
    reg [DW-1:0] a2_d1, a2_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a0_d1 <= 0; a0_d2 <= 0;
            a1_d1 <= 0; a1_d2 <= 0;
            a2_d1 <= 0; a2_d2 <= 0;
        end else begin
            a0_d1 <= row0_r;  a0_d2 <= a0_d1;
            a1_d1 <= r1;      a1_d2 <= a1_d1;
            a2_d1 <= r2;      a2_d2 <= a2_d1;
        end
    end

    assign p00 = a0_d2;  assign p01 = a0_d1;  assign p02 = row0_r;
    assign p10 = a1_d2;  assign p11 = a1_d1;  assign p12 = r1;
    assign p20 = a2_d2;  assign p21 = a2_d1;  assign p22 = r2;

    // ---- 有效标志：与窗口数据同拍（本模块延迟 1 拍）----
    //  line_cnt 在第 3 行（索引 2）时才 >= 2，此时 lb1 存第 1 行、lb2 存第 0 行，
    //  三行数据才真正齐备；前两行输出无效（图像顶部留黑，属正常）。
    wire win_ok = de & (rd_addr >= 2) & (line_cnt >= 2);
    reg  win_ok_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) win_ok_r <= 1'b0;
        else        win_ok_r <= win_ok;
    end

    assign win_valid = win_ok_r;

endmodule
