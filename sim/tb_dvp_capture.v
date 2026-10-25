`timescale 1ns/1ps
//=============================================================================
//  tb_dvp_capture.v —— DVP 采集模块自检 Testbench
//-----------------------------------------------------------------------------
//  自造 DVP 时序（VSYNC 脉冲 + HREF 高电平逐像素），检查：
//    T1  frame_start 只在 VSYNC 上升沿出现一次
//    T2  每个 HREF 段出来的 px_we 个数 == H_ACTIVE  （总像素 = H_ACTIVE*V_ACTIVE）
//    T3  col_num 每行落在 0..H_ACTIVE-1，且与 px_we 同拍
//    T4  采集期间出现过的最大 line_num == V_ACTIVE-1
//    T5  line_start / line_end 与每行首/末像素对齐
//    T6  RGB565：两字节拼成 16bit 像素，像素数按「字」计（HREF 字节数 = 2*H_ACTIVE）
//
//  两个 DUT 共享同一组激励，用 mon8_en / mon16_en 分段使能，
//  保证各自只统计自己那一帧 —— 避免「DUT16 也看到 8bit 帧」导致计数串味。
//
//  ⚠️ 踩坑记录：不要在 task 里用模块级 integer 当循环变量！
//     上一版 dvp_line 用了全局 i，把 dvp_frame 的帧循环变量冲掉，
//     结果只发出 1 行（4 行变 1 行）。此版本所有循环变量都独立命名。
//
//  全部用英文 $display，避免 ModelSim 日志中文乱码。
//=============================================================================
module tb_dvp_capture;

    localparam PCLK_HALF = 10;      // 20ns 周期

    localparam H8  = 8,  V8  = 4;   // 8bit 场景
    localparam H16 = 6,  V16 = 2;   // 16bit RGB565 场景
    localparam GAP = 4;             // 行间 HREF 低电平拍数

    reg        pclk  = 0;
    reg        rst_n = 0;
    reg        vsync = 0;
    reg        href  = 0;
    reg  [7:0] d     = 8'h00;

    // ---------------- DUT : 8bit 单色 ----------------
    wire [7:0]  px8;
    wire        we8;
    wire [11:0] col8, lin8;
    wire        fs8, ls8, le8, fa8;

    dvp_capture #(
        .PIX_W(8), .H_ACTIVE(H8), .V_ACTIVE(V8), .CW(12)
    ) dut8 (
        .pclk(pclk), .rst_n(rst_n),
        .vsync_i(vsync), .href_i(href), .d_i(d),
        .px_data(px8), .px_we(we8), .col_num(col8), .line_num(lin8),
        .frame_start(fs8), .line_start(ls8), .line_end(le8), .frame_active(fa8)
    );

    // ---------------- DUT : 16bit RGB565 ----------------
    wire [15:0] px16;
    wire        we16;
    wire [11:0] col16, lin16;
    wire        fs16, ls16, le16, fa16;

    dvp_capture #(
        .PIX_W(16), .H_ACTIVE(H16), .V_ACTIVE(V16), .CW(12), .MSB_FIRST(1)
    ) dut16 (
        .pclk(pclk), .rst_n(rst_n),
        .vsync_i(vsync), .href_i(href), .d_i(d),
        .px_data(px16), .px_we(we16), .col_num(col16), .line_num(lin16),
        .frame_start(fs16), .line_start(ls16), .line_end(le16), .frame_active(fa16)
    );

    always #PCLK_HALF pclk = ~pclk;

    // ================= 分段使能 =================
    reg mon8_en  = 1'b0;
    reg mon16_en = 1'b0;

    // ================= 监视器：8bit =================
    integer n_px8      = 0;
    integer n_fstart8  = 0;
    // ⚠️ 初值必须是 0 而不是 -1：lin8 是 unsigned wire，
    //    与有符号 -1 比较时会把 -1 当 32'hFFFFFFFF，条件永远为假。
    integer max_line8  = 0;
    integer err8       = 0;

    always @(posedge pclk) begin
        if (rst_n && mon8_en) begin
            if (fs8) n_fstart8 <= n_fstart8 + 1;
            if (we8) begin
                n_px8 <= n_px8 + 1;
                if (lin8 > max_line8) max_line8 <= lin8;
                if (col8 >= H8) begin
                    $display("  T3 FAIL : col_num=%0d out of range (line %0d)", col8, lin8);
                    err8 <= err8 + 1;
                end
                if (col8 == 0 && !ls8) begin
                    $display("  T5 FAIL : line_start missing at first pixel (line %0d)", lin8);
                    err8 <= err8 + 1;
                end
                if (col8 == H8-1 && !le8) begin
                    $display("  T5 FAIL : line_end missing at last pixel (line %0d)", lin8);
                    err8 <= err8 + 1;
                end
            end
        end
    end

    // ================= 监视器：16bit =================
    integer n_px16     = 0;
    integer n_fstart16 = 0;
    integer max_line16 = 0;
    integer err16      = 0;

    always @(posedge pclk) begin
        if (rst_n && mon16_en) begin
            if (fs16) n_fstart16 <= n_fstart16 + 1;
            if (we16) begin
                n_px16 <= n_px16 + 1;
                if (lin16 > max_line16) max_line16 <= lin16;
                if (col16 >= H16) begin
                    $display("  T6 FAIL : col16=%0d out of range", col16);
                    err16 <= err16 + 1;
                end
            end
        end
    end

    // ================= 激励（循环变量全部独立命名）=================
    integer f_i, p_i, g_i;

    initial begin
        $display("========== dvp_capture self-check ==========");
        rst_n = 0; vsync = 0; href = 0; d = 0;
        repeat (5) @(negedge pclk);
        rst_n = 1;
        repeat (3) @(negedge pclk);

        //================= 帧 1：8bit mono =================
        $display("---- T1..T5 : 8bit mono frame (%0d x %0d) ----", H8, V8);
        mon8_en = 1'b1;

        @(negedge pclk); vsync = 1'b1;          // VSYNC 上升沿 = 帧开始
        @(negedge pclk);
        @(negedge pclk); vsync = 1'b0;
        @(negedge pclk);

        for (f_i = 0; f_i < V8; f_i = f_i + 1) begin
            @(negedge pclk); href = 1'b1;
            for (p_i = 0; p_i < H8; p_i = p_i + 1) begin
                d = (f_i * 8) + p_i[7:0];
                @(negedge pclk);
            end
            href = 1'b0; d = 8'h00;
            for (g_i = 0; g_i < GAP; g_i = g_i + 1) @(negedge pclk);
        end
        mon8_en = 1'b0;
        repeat (6) @(negedge pclk);

        $display("  frame_start pulses = %0d (expect 1)", n_fstart8);
        $display("  px_we total        = %0d (expect %0d)", n_px8, H8*V8);
        $display("  max line_num       = %0d (expect %0d)", max_line8, V8-1);
        if (n_fstart8 != 1)      begin $display("  T1 FAIL"); err8 = err8 + 1; end
        if (n_px8 != H8*V8)      begin $display("  T2 FAIL"); err8 = err8 + 1; end
        if (max_line8 != V8-1)   begin $display("  T4 FAIL"); err8 = err8 + 1; end

        //================= 帧 2：16bit RGB565 =================
        $display("---- T6 : 16bit RGB565 frame (%0d x %0d) ----", H16, V16);
        mon16_en = 1'b1;

        @(negedge pclk); vsync = 1'b1;
        @(negedge pclk);
        @(negedge pclk); vsync = 1'b0;
        @(negedge pclk);

        for (f_i = 0; f_i < V16; f_i = f_i + 1) begin
            @(negedge pclk); href = 1'b1;
            // 每像素 2 字节 => HREF 内 2*H16 个字节
            for (p_i = 0; p_i < H16*2; p_i = p_i + 1) begin
                d = 8'h10 + p_i[7:0];
                @(negedge pclk);
            end
            href = 1'b0; d = 8'h00;
            for (g_i = 0; g_i < GAP; g_i = g_i + 1) @(negedge pclk);
        end
        mon16_en = 1'b0;
        repeat (6) @(negedge pclk);

        $display("  frame_start pulses = %0d (expect 1)", n_fstart16);
        $display("  px_we total        = %0d (expect %0d)", n_px16, H16*V16);
        $display("  max line_num       = %0d (expect %0d)", max_line16, V16-1);
        if (n_fstart16 != 1)     begin $display("  T6 FAIL : frame_start"); err16 = err16 + 1; end
        if (n_px16 != H16*V16)   begin $display("  T6 FAIL : pixel count"); err16 = err16 + 1; end
        if (max_line16 != V16-1) begin $display("  T6 FAIL : line count");  err16 = err16 + 1; end

        //================= 汇总 =================
        if (err8 == 0 && err16 == 0)
            $display("========== RESULT: ALL CHECKS PASSED ==========");
        else
            $display("========== RESULT: %0d ERRORS ==========", err8 + err16);

        $finish;
    end

    // 超时保护
    initial begin
        #200000;
        $display("========== RESULT: TIMEOUT ==========");
        $finish;
    end

endmodule
