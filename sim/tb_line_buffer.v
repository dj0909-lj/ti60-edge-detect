`timescale 1ns/1ps
//=============================================================================
//  tb_line_buffer.v —— line_buffer_3x3 单元测试（定位窗口对齐问题）
//
//  喂入规则图案：像素值 = 行号*10 + 列号
//      行 0:  0  1  2  3  4  5  6  7
//      行 1: 10 11 12 13 14 15 16 17
//      行 2: 20 21 22 23 24 25 26 27
//      ...
//  这样窗口里 9 个像素的值一眼就能看出是哪一行哪一列，对齐错位无处遁形。
//
//  期望：窗口最右列 p02/p12/p22 对应行 vc-1 / vc-2 / vc-3 的 hc-1 列
//        （本模块延迟 1 拍）
//=============================================================================
module tb_line_buffer;

    localparam W     = 8;      // 行宽
    localparam H     = 6;      // 行数
    localparam BLANK = 4;      // 行消隐时钟数

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg [11:0] hc = 0, vc = 0;

    wire de  = (hc < W) && (vc < H);
    wire sof = (hc == 0) && (vc == 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin hc <= 0; vc <= 0; end
        else if (hc == W + BLANK - 1) begin
            hc <= 0;
            vc <= (vc == H - 1) ? 12'd0 : vc + 1'b1;
        end else hc <= hc + 1'b1;
    end

    // 源像素：行号*10 + 列号
    wire [7:0] pix_in = vc * 8'd10 + hc[7:0];

    // 与窗口输出同拍（延迟 1 拍）的源坐标
    reg [11:0] hc_d = 0, vc_d = 0;
    always @(posedge clk) begin hc_d <= hc; vc_d <= vc; end

    wire        win_valid;
    wire [7:0]  p00, p01, p02, p10, p11, p12, p20, p21, p22;

    line_buffer_3x3 #(.IMG_W(W), .DW(8)) dut (
        .clk(clk), .rst_n(rst_n), .de(de), .sof(sof), .pix_in(pix_in),
        .win_valid(win_valid),
        .p00(p00), .p01(p01), .p02(p02),
        .p10(p10), .p11(p11), .p12(p12),
        .p20(p20), .p21(p21), .p22(p22)
    );

    function [7:0] f;
        input [11:0] xx, yy;
        begin f = yy * 8'd10 + xx[7:0]; end
    endfunction

    integer errs = 0, shown = 0;

    always @(posedge clk) begin
        if (rst_n && win_valid) begin
            if (hc_d >= 2 && vc_d >= 2) begin
                if (shown < 40) begin
                    $display("row=%0d col=%0d | p00=%2d p01=%2d p02=%2d | p10=%2d p11=%2d p12=%2d | p20=%2d p21=%2d p22=%2d",
                        vc_d, hc_d, p00,p01,p02, p10,p11,p12, p20,p21,p22);
                    $display("                expect | p00=%2d p01=%2d p02=%2d | p10=%2d p11=%2d p12=%2d | p20=%2d p21=%2d p22=%2d",
                        f(hc_d-2,vc_d), f(hc_d-1,vc_d), f(hc_d,vc_d),
                        f(hc_d-2,vc_d-1), f(hc_d-1,vc_d-1), f(hc_d,vc_d-1),
                        f(hc_d-2,vc_d-2), f(hc_d-1,vc_d-2), f(hc_d,vc_d-2));
                    shown = shown + 1;
                end
                if (p00 !== f(hc_d-2,vc_d) || p01 !== f(hc_d-1,vc_d) || p02 !== f(hc_d,vc_d) ||
                    p10 !== f(hc_d-2,vc_d-1) || p11 !== f(hc_d-1,vc_d-1) || p12 !== f(hc_d,vc_d-1) ||
                    p20 !== f(hc_d-2,vc_d-2) || p21 !== f(hc_d-1,vc_d-2) || p22 !== f(hc_d,vc_d-2)) begin
                    if (errs < 15) $display("  ** MISMATCH at row=%0d col=%0d", vc_d, hc_d);
                    errs = errs + 1;
                end
            end
        end
    end

    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat ((W+BLANK) * H * 3) @(posedge clk);
        $display("");
        $display("line_buffer_3x3 : total window mismatches = %0d", errs);
        $display("");
        $finish;
    end

endmodule
