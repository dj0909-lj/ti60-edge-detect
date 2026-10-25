`timescale 1ns/1ps
//=============================================================================
//  tb_edge_detect_top.v —— 赛题四 全链自检仿真
//
//  R1 : mode=0 净条纹 中值开    -> 分屏左右两半检查
//  R2a: mode=1 单竖线@x=16      -> 灰度通路落点
//  R2b: mode=3 单竖线@x=16      -> 边缘通路落点（决定性：必须 x=16 与 x=18）
//  R3 : mode=3 净条纹 中值关    -> 边缘图 + 位置断言
//  R4 : mode=3 净条纹 中值开    -> 观察中值对阶跃的固有 1 像素推移
//  R5 : mode=3 椒盐 中值关      -> 伪边缘 N0
//  R6 : mode=3 椒盐 中值开      -> 伪边缘 N1（应显著小于 N0）
//  R7 : 按键阈值调节链路        -> 连续按 + 后阈值上升、边缘数下降
//
//  所有 $display 用英文，避免 ModelSim 控制台中文乱码。
//=============================================================================
module tb_edge_detect_top;

    localparam IMG_W = 32;
    localparam IMG_H = 16;
    localparam H_SYNC = 2, H_BP = 2, H_FP = 2;
    localparam H_TOTAL = H_SYNC + H_BP + IMG_W + H_FP;   // 38
    localparam V_SYNC = 1, V_BP = 1, V_FP = 1;
    localparam V_TOTAL = V_SYNC + V_BP + IMG_H + V_FP;   // 19
    localparam CLK_P   = 10;
    localparam LAT     = 10;     // must equal edge_detect_top RGB_LAT

    integer i, j, k, errs, cnt0, cnt1, cnt2;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_P/2) clk = ~clk;

    reg [11:0] hcnt = 12'd0, vcnt = 12'd0;
    wire de  = (hcnt < IMG_W) && (vcnt < IMG_H);
    wire sof = (hcnt == 12'd0) && (vcnt == 12'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt <= 12'd0; vcnt <= 12'd0;
        end else if (hcnt == H_TOTAL-1) begin
            hcnt <= 12'd0;
            vcnt <= (vcnt == V_TOTAL-1) ? 12'd0 : vcnt + 12'd1;
        end else hcnt <= hcnt + 12'd1;
    end

    wire [11:0] x_dly, y_dly;
    shift_delay #(.W(12), .DEPTH(LAT)) u_xdly (.clk(clk), .rst_n(rst_n), .din(hcnt), .dout(x_dly));
    shift_delay #(.W(12), .DEPTH(LAT)) u_ydly (.clk(clk), .rst_n(rst_n), .din(vcnt), .dout(y_dly));

    // ---------------- patterns ----------------
    function [7:0] barv;                 // inverted bars
        input [11:0] xx, yy;
        begin
            if (yy < IMG_H/2)
                barv = (xx < IMG_W/4)   ? 8'd40  :
                       (xx < IMG_W/2)   ? 8'd200 :
                       (xx < 3*IMG_W/4) ? 8'd40  : 8'd200;
            else
                barv = (xx < IMG_W/4)   ? 8'd200 :
                       (xx < IMG_W/2)   ? 8'd40  :
                       (xx < 3*IMG_W/4) ? 8'd200 : 8'd40;
        end
    endfunction

    function [7:0] linev;                // single vertical line @ x=16
        input [11:0] xx, yy;
        begin linev = (xx == 12'd16) ? 8'd200 : 8'd0; end
    endfunction

    function [7:0] hash8;
        input [11:0] xx, yy;
        reg [15:0] h;
        begin
            h = (xx * 16'd13) + (yy * 16'd97) + (xx * xx) + (yy * yy * 16'd7);
            hash8 = h[7:0];
        end
    endfunction

    wire [7:0] hsh = hash8(hcnt, vcnt);
    wire [7:0] noisy = (hsh < 8'd14) ? (hsh[0] ? 8'hFF : 8'h00) : barv(hcnt, vcnt);

    reg  [1:0] pat_sel = 2'd0;    // 0=bars 1=line 2=bars+noise
    wire [7:0] src_pix = (pat_sel == 2'd1) ? linev(hcnt, vcnt) :
                         (pat_sel == 2'd2) ? noisy : barv(hcnt, vcnt);

    reg  [1:0]  disp_mode = 2'd0;
    reg         median_en = 1'b1;
    reg  [1:0]  key       = 2'b00;

    wire [23:0] rgb_out;
    wire        out_valid;
    wire [11:0] thr;

    edge_detect_top #(
        .IMG_W(IMG_W), .H_ACT(IMG_W), .V_ACT(IMG_H),
        .TW(12), .CW(12), .DEB_CNT_W(6)
    ) dut (
        .clk(clk), .rst_n(rst_n), .sof(sof), .de(de),
        .r(src_pix), .g(src_pix), .b(src_pix),
        .x(x_dly), .y(y_dly),
        .key(key), .median_en(median_en), .disp_mode(disp_mode),
        .rgb_out(rgb_out), .out_valid(out_valid), .threshold_o(thr)
    );

    // ---------------- capture ----------------
    reg [23:0] map_dly [0:IMG_W*IMG_H-1];
    reg        vma_dly [0:IMG_W*IMG_H-1];

    always @(posedge clk) begin
        if (rst_n && out_valid && (x_dly < IMG_W) && (y_dly < IMG_H)) begin
            map_dly[y_dly*IMG_W + x_dly] <= rgb_out;
            vma_dly[y_dly*IMG_W + x_dly] <= 1'b1;
        end
    end

    task clear_maps;
        begin
            for (i = 0; i < IMG_W*IMG_H; i = i + 1) begin
                map_dly[i] = 24'h0; vma_dly[i] = 1'b0;
            end
        end
    endtask

    task print_edge_map;
        begin
            for (j = 0; j < IMG_H; j = j + 1) begin
                $write("y=%2d |", j);
                for (i = 0; i < IMG_W; i = i + 1) begin
                    if      (!vma_dly[j*IMG_W+i])     $write("?");
                    else if (map_dly[j*IMG_W+i] != 0) $write("#");
                    else                              $write(".");
                end
                $write("|\n");
            end
        end
    endtask

    task print_marks;
        input integer yy;
        input [255:0] tag;
        begin
            $write("  [%0s] row %0d non-zero cols:", tag, yy);
            for (i = 0; i < IMG_W; i = i + 1)
                if (vma_dly[yy*IMG_W+i] && (map_dly[yy*IMG_W+i] != 24'h0))
                    $write(" x=%0d(v=%0d)", i, map_dly[yy*IMG_W+i][7:0]);
            $write("\n");
        end
    endtask

    task count_edges;
        output integer n;
        begin
            n = 0;
            for (i = 0; i < IMG_W*IMG_H; i = i + 1)
                if (vma_dly[i] && map_dly[i] != 24'h0) n = n + 1;
        end
    endtask

    task check;
        input [11:0] xx, yy;
        input [23:0] exp;
        input [255:0] tag;
        begin
            if (!vma_dly[yy*IMG_W+xx])
                $display("  SKIP  (%0d,%0d) outside valid window  [%0s]", xx, yy, tag);
            else if (map_dly[yy*IMG_W+xx] !== exp) begin
                $display("  FAIL  (%0d,%0d) got %h expect %h  [%0s]", xx, yy, map_dly[yy*IMG_W+xx], exp, tag);
                errs = errs + 1;
            end else
                $display("  PASS  (%0d,%0d) = %h  [%0s]", xx, yy, exp, tag);
        end
    endtask

    task press_inc;
        begin
            key[0] = 1'b1; repeat (100) @(posedge clk);
            key[0] = 1'b0; repeat (100) @(posedge clk);
        end
    endtask

    // ---------------- main ----------------
    initial begin
        errs = 0;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        // ===== R1 =====
        $display("");
        $display("========== R1 : mode=0 SPLIT SCREEN ==========");
        clear_maps; pat_sel = 2'd0; disp_mode = 2'd0; median_en = 1'b1;
        repeat (H_TOTAL*V_TOTAL*3) @(posedge clk);
        check(12, 10, {barv(12,10),barv(12,10),barv(12,10)}, "left half = gray");
        check(28, 10, 24'hFFFFFF,                            "right half = edge");

        // ===== R2a: gray path location =====
        $display("");
        $display("========== R2a : SINGLE LINE @x=16 , mode=1 (GRAY) ==========");
        clear_maps; pat_sel = 2'd1; disp_mode = 2'd1; median_en = 1'b1;
        repeat (H_TOTAL*V_TOTAL*3) @(posedge clk);
        print_marks(6,  "GRAY");
        print_marks(10, "GRAY");

        // ===== R2b: edge path location =====
        $display("");
        $display("========== R2b : SINGLE LINE @x=16 , mode=3 (EDGE) ==========");
        clear_maps; disp_mode = 2'd3; median_en = 1'b0;
        repeat (H_TOTAL*V_TOTAL*3) @(posedge clk);
        print_edge_map;
        print_marks(6, "EDGE");
        $display("  theory: Sobel Gx = 4*col(c) - 4*col(c-2), so response ONLY at x=16 and x=18");
        check(16, 6, 24'hFFFFFF, "resp x=16");
        check(17, 6, 24'h000000, "gap  x=17");
        check(18, 6, 24'hFFFFFF, "resp x=18");

        // ===== R3 =====
        $display("");
        $display("========== R3 : BARS , median OFF ==========");
        $display("  steps at x=7|8,15|16,23|24 and y=7|8  =>  responses at x=8,9/16,17/24,25 ; y=8,9");
        clear_maps; pat_sel = 2'd0; median_en = 1'b0;
        repeat (H_TOTAL*V_TOTAL*3) @(posedge clk);
        print_edge_map;
        $display("");
        check(8,  6, 24'hFFFFFF, "V x=8");
        check(9,  6, 24'hFFFFFF, "V x=9");
        check(10, 6, 24'h000000, "flat x=10");
        check(12, 6, 24'h000000, "flat x=12");
        check(16, 6, 24'hFFFFFF, "V x=16");
        check(17, 6, 24'hFFFFFF, "V x=17");
        check(18, 6, 24'h000000, "flat x=18");
        check(24, 6, 24'hFFFFFF, "V x=24");
        check(25, 6, 24'hFFFFFF, "V x=25");
        check(26, 6, 24'h000000, "flat x=26");
        check(12, 8, 24'hFFFFFF, "H y=8");
        check(12, 9, 24'hFFFFFF, "H y=9");
        check(12,10, 24'h000000, "flat y=10");

        // ===== R4 =====
        $display("");
        $display("========== R4 : BARS , median ON (inherent 1px shift) ==========");
        clear_maps; median_en = 1'b1;
        repeat (H_TOTAL*V_TOTAL*3) @(posedge clk);
        print_edge_map;
        $display("");

        // ===== R5 / R6 =====
        $display("========== R5 : SALT&PEPPER , median OFF ==========");
        clear_maps; disp_mode = 2'd3; pat_sel = 2'd2; median_en = 1'b0;
        repeat (H_TOTAL*V_TOTAL*3) @(posedge clk);
        count_edges(cnt0);
        $display("  N0 = %0d", cnt0);

        $display("========== R6 : SALT&PEPPER , median ON ==========");
        clear_maps; median_en = 1'b1;
        repeat (H_TOTAL*V_TOTAL*3) @(posedge clk);
        count_edges(cnt1);
        $display("  N1 = %0d", cnt1);
        if (cnt0 > 0 && cnt1 < cnt0) $display("  => median filter works: spurious edges -%0d%%", ((cnt0-cnt1)*100)/cnt0);
        else begin $display("  => ERROR: median did not reduce spurious edges"); errs = errs + 1; end

        // ===== R7 : threshold key chain =====
        $display("");
        $display("========== R7 : THRESHOLD KEY CHAIN ==========");
        clear_maps; disp_mode = 2'd3; pat_sel = 2'd2; median_en = 1'b0;
        repeat (H_TOTAL*V_TOTAL*3) @(posedge clk);
        count_edges(cnt2);
        $display("  before: threshold=%0d  edges=%0d", thr, cnt2);

        for (k = 0; k < 20; k = k + 1) press_inc;      // 20 presses, STEP=16
        clear_maps;
        repeat (H_TOTAL*V_TOTAL*3) @(posedge clk);
        count_edges(cnt1);
        $display("  after : threshold=%0d  edges=%0d", thr, cnt1);

        if (thr > 12'd64 && cnt1 < cnt2) $display("  => threshold key chain works: edges decreased");
        else begin $display("  => ERROR: threshold key chain failed"); errs = errs + 1; end

        $display("");
        if (errs == 0) $display("========== RESULT: ALL CHECKS PASSED ==========");
        else           $display("========== RESULT: %0d CHECK(S) FAILED ==========", errs);
        $display("");
        $finish;
    end

    initial begin
        #(CLK_P * H_TOTAL * V_TOTAL * 60);
        $display("TIMEOUT");
        $finish;
    end

endmodule
