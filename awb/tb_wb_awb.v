`timescale 1ns/1ns
//=============================================================================
//  tb_wb_awb.v —— 自动白平衡模块验证
//
//  最重要的一条：T0 —— 与它替代的 wb_apply 【逐拍完全等价】
//    顶层 display_mux 的 DELAY_COLOR=12 是按 wb_apply 的延迟标定的。
//    AWB 若延迟/行为不同 => 叠加模式(mode=3)红边错位。
//    硬性要求：把它替换进 wb_apply 的位置后，彩色支路时序必须【一模一样】。
//
//  验证项：
//    T0 等价性：无 vsync 跳变（增益冻结）时，wb_awb 与 wb_apply 输出逐拍相同
//    T1 延迟：输出相对输入恰好 1 拍（用移位参照对比）
//    T2 旁路：en=0 原样透传
//    T3 收敛：偏绿图像下 R/B 增益上升
//    T4 钳位：增益不越界
//    T5 暗场：极暗画面不调整
//    T6 饱和：>255 钳到 255
//=============================================================================
module tb_wb_awb;

    reg         clk = 0;
    reg         rst_n = 0;

    // 两路共用激励
    reg         en = 1;
    reg         in_vsync = 0, in_hsync = 0, in_href = 0;
    reg  [7:0]  r_in = 0, g_in = 0, b_in = 0;

    // ---- DUT: wb_awb ----
    wire        a_vsync, a_hsync, a_href;
    wire [7:0]  a_r, a_g, a_b;
    wire [5:0]  a_rgain, a_bgain;
    wire        a_stat;

    wb_awb #(
        .SAMPLE_SHIFT  (4),
        .GAIN_MIN      (6'd8),
        .GAIN_MAX      (6'd48),
        .R_GAIN_INIT   (6'd24),   // 1.500x
        .B_GAIN_INIT   (6'd20),   // 1.250x
.DEADBAND_SHIFT(4),
        .DARK_LEVEL    (8'd16),
        // ⚠️ 仿真用 400 像素小帧（每 16 采一次 => 25 点/帧）。
        //    真实 1920x1080 是 ~129,600 点，故工程里用默认 1024；
        //    仿真必须调小，否则一帧采样数永远达不到门限。
        .MIN_SAMPLES   (24'd16),
        .SHIFT         (4)
    ) dut (
        .clk(clk), .rst_n(rst_n), .en(en),
        .in_vsync(in_vsync), .in_hsync(in_hsync), .in_href(in_href),
        .r_in(r_in), .g_in(g_in), .b_in(b_in),
        .out_vsync(a_vsync), .out_hsync(a_hsync), .out_href(a_href),
        .r_out(a_r), .g_out(a_g), .b_out(a_b),
        .r_gain_o(a_rgain), .b_gain_o(a_bgain), .awb_stat_o(a_stat)
    );

    // ---- 参照: 被替代的 wb_apply（同参数：R=24, B=20, SHIFT=4）----
    wire        b_vsync, b_hsync, b_href;
    wire [7:0]  b_r, b_g, b_b;

    wb_apply #(
        .R_GAIN (16'd24),
        .B_GAIN (16'd20),
        .SHIFT  (4)
    ) ref_wb (
        .clk(clk), .rst_n(rst_n), .en(en),
        .in_vsync(in_vsync), .in_hsync(in_hsync), .in_href(in_href),
        .r_in(r_in), .g_in(g_in), .b_in(b_in),
        .out_vsync(b_vsync), .out_hsync(b_hsync), .out_href(b_href),
        .r_out(b_r), .g_out(b_g), .b_out(b_b)
    );

    always #5 clk = ~clk;

    integer errors = 0;

    //==========================================================================
    // T0：等价性 —— 无 vsync 跳变 => 增益冻结 => 应与 wb_apply 逐拍相同
    //==========================================================================
    task test_equivalence;
        integer i;
        integer mismatch;
        integer seed;
        reg [7:0] rr, gg, bb;
        begin
            seed = 7;
            $display("[T0] 与 wb_apply 逐拍等价性（DELAY_COLOR=12 的前提）...");
            rst_n = 0;
            in_vsync = 0; in_hsync = 0; in_href = 0;
            r_in = 0; g_in = 0; b_in = 0;
            repeat (4) @(negedge clk);
            rst_n = 1; en = 1;
            @(negedge clk);

            mismatch = 0;
            for (i = 0; i < 2000; i = i + 1) begin
                @(negedge clk);
                // 线性同余伪随机激励（可复现，避免 $random 的种子限制）
                seed = (seed * 1103515245 + 12345) & 32'h7FFFFFFF;
                rr = seed[15:8];
                seed = (seed * 1103515245 + 12345) & 32'h7FFFFFFF;
                gg = seed[15:8];
                seed = (seed * 1103515245 + 12345) & 32'h7FFFFFFF;
                bb = seed[15:8];
                r_in = rr; g_in = gg; b_in = bb;
                in_href  = (i % 7) ? 1'b1 : 1'b0;
                in_hsync = (i % 13) ? 1'b1 : 1'b0;
                // 注意：in_vsync 保持 0 —— 不产生跳变，增益不会更新

                @(posedge clk); #1;
                if (a_r !== b_r || a_g !== b_g || a_b !== b_b ||
                    a_href !== b_href || a_hsync !== b_hsync || a_vsync !== b_vsync) begin
                    if (mismatch < 5) begin
                        $display("  失配 @i=%0d : awb(%0d,%0d,%0d href=%b) vs wb_apply(%0d,%0d,%0d href=%b)",
                                 i, a_r, a_g, a_b, a_href, b_r, b_g, b_b, b_href);
                    end
                    mismatch = mismatch + 1;
                end
            end
            if (mismatch != 0) begin
                $display("  ERROR: 与 wb_apply 不等价，%0d 处失配", mismatch);
                errors = errors + 1;
            end else begin
                $display("  -> 2000 拍逐拍完全一致；延迟与缩放行为与被替代模块等价");
            end
            $display("     增益冻结验证: R=%0d B=%0d (应仍为 24 / 20)", a_rgain, a_bgain);
            if (a_rgain !== 6'd24 || a_bgain !== 6'd20) begin
                $display("  ERROR: 无 vsync 跳变时增益不应变化");
                errors = errors + 1;
            end
        end
    endtask

    //==========================================================================
    // T1：延迟恰好 1 拍
    //   测法：在 negedge 驱动输入 X_i，到【下一个 negedge】（整整一个时钟后）
    //         读输出，应恰好等于 f(X_i)。
    //   若驱动后立刻在同一个 posedge 读，那是 0 拍语义，会误判 —— 勿那样写。
    //==========================================================================
    task test_latency;
        integer i;
        integer mismatch;
        reg [7:0] x_i;
        begin
            $display("[T1] 延迟恰好 1 拍 ...");
            rst_n = 0;
            repeat (4) @(negedge clk);
            rst_n = 1; en = 1;
            @(negedge clk);

            mismatch = 0;
            for (i = 0; i < 300; i = i + 1) begin
                // 在 negedge 驱动本拍输入
                @(negedge clk);
                x_i  = (i * 37) % 256;
                r_in = x_i;
                g_in = x_i;
                b_in = x_i;
                in_href = 1'b1;

                // 等整整一个时钟（下一个 negedge）再读输出
                @(negedge clk);
                begin : calc
                    reg [13:0] p;
                    reg [7:0]  exp;
                    p = x_i * 6'd24;            // R 增益 24 = 1.5x
                    p = p >> 4;
                    exp = (p > 14'd255) ? 8'd255 : p[7:0];
                    if (a_r !== exp) begin
                        if (mismatch < 5)
                            $display("  失配 @i=%0d: a_r=%0d 期望=%0d (本拍输入=%0d)",
                                     i, a_r, exp, x_i);
                        mismatch = mismatch + 1;
                    end
                    // G 不缩放
                    if (a_g !== x_i) begin
                        if (mismatch < 5)
                            $display("  失配 @i=%0d: a_g=%0d 期望=%0d", i, a_g, x_i);
                        mismatch = mismatch + 1;
                    end
                end
            end
            if (mismatch != 0) begin
                $display("  ERROR: 延迟不是恰好 1 拍，%0d 处失配", mismatch);
                errors = errors + 1;
            end else begin
                $display("  -> 延迟恰为 1 拍（300 拍全部吻合）");
            end
        end
    endtask

    //==========================================================================
    // T2：旁路 en=0
    //==========================================================================
    task test_bypass;
        begin
            $display("[T2] 旁路透传 ...");
            rst_n = 0;
            repeat (4) @(negedge clk);
            rst_n = 1; en = 0;
            @(negedge clk);
            @(negedge clk);
            r_in = 8'd100; g_in = 8'd200; b_in = 8'd50; in_href = 1'b1;
            @(posedge clk); #1;
            @(posedge clk); #1;
            if (a_r !== 8'd100 || a_g !== 8'd200 || a_b !== 8'd50) begin
                $display("  ERROR: 旁路应原样输出 100/200/50, 实得 %0d/%0d/%0d",
                         a_r, a_g, a_b);
                errors = errors + 1;
            end else begin
                $display("  -> 旁路透传正确");
            end
            if (a_rgain !== 6'd24 || a_bgain !== 6'd20) begin
                $display("  ERROR: 旁路下增益不应变化");
                errors = errors + 1;
            end
        end
    endtask

    //==========================================================================
    // T6：饱和
    //==========================================================================
    task test_saturate;
        begin
            $display("[T6] 输出饱和 ...");
            rst_n = 0;
            repeat (4) @(negedge clk);
            rst_n = 1; en = 1;
            @(negedge clk);
            @(negedge clk);
            r_in = 8'd200; g_in = 8'd200; b_in = 8'd200; in_href = 1'b1;
            @(posedge clk); #1;
            @(posedge clk); #1;
            if (a_r !== 8'd255) begin
                $display("  ERROR: 200*1.5=300 应饱和到 255, 实得 %0d", a_r);
                errors = errors + 1;
            end else if (a_b !== 8'd250) begin
                $display("  ERROR: 200*1.25=250 应保持, 实得 %0d", a_b);
                errors = errors + 1;
            end else begin
                $display("  -> 饱和钳位正确 (200*1.5->255, 200*1.25->250)");
            end
        end
    endtask

    //==========================================================================
    // 辅助：发一帧（n 个像素 + 帧尾 vsync 跳变）
    //==========================================================================
    task send_frame;
        input [7:0]   rv, gv, bv;
        input integer npix;
        input         vsync_pulse;
        integer k;
        begin
            in_vsync = 1'b0;
            for (k = 0; k < npix; k = k + 1) begin
                @(negedge clk);
                r_in = rv; g_in = gv; b_in = bv; in_href = 1'b1;
            end
            @(negedge clk);
            r_in = 0; g_in = 0; b_in = 0; in_href = 1'b0;
            if (vsync_pulse) begin
                @(negedge clk); in_vsync = 1'b1;
                @(negedge clk); in_vsync = 1'b0;
            end
            @(negedge clk);
        end
    endtask

    //==========================================================================
    // T3：收敛
    //==========================================================================
    task test_converge;
        integer n;
        reg [5:0] r0, b0;
        begin
            $display("[T3] 偏绿图像收敛 ...");
            rst_n = 0;
            repeat (4) @(negedge clk);
            rst_n = 1; en = 1;
            @(negedge clk);
            r0 = a_rgain; b0 = a_bgain;
            $display("  起始 R=%0d (%.3fx) B=%0d (%.3fx)", r0, r0/16.0, b0, b0/16.0);

            for (n = 0; n < 120; n = n + 1) send_frame(8'd80, 8'd200, 8'd80, 400, 1'b1);

            $display("  120 帧后 R=%0d (%.3fx) B=%0d (%.3fx)",
                     a_rgain, a_rgain/16.0, a_bgain, a_bgain/16.0);
            if (a_rgain > r0 && a_bgain > b0)
                $display("  -> R/B 增益均上升，控制环工作正常");
            else begin
                $display("  ERROR: 偏绿场景下 R/B 增益应同时上升");
                errors = errors + 1;
            end
        end
    endtask

    //==========================================================================
    // T4：钳位
    //==========================================================================
    task test_clamp;
        integer n;
        begin
            $display("[T4] 增益钳位 ...");
            rst_n = 0;
            repeat (4) @(negedge clk);
            rst_n = 1; en = 1;
            @(negedge clk);
            for (n = 0; n < 400; n = n + 1) send_frame(8'd1, 8'd250, 8'd1, 400, 1'b1);
            $display("  极端偏绿 400 帧后 R=%0d B=%0d (上限48)", a_rgain, a_bgain);
            if (a_rgain > 6'd48 || a_bgain > 6'd48) begin
                $display("  ERROR: 越过上限");
                errors = errors + 1;
            end else if (a_rgain == 6'd48 && a_bgain == 6'd48)
                $display("  -> 上限钳位正确（冲到 48 后停住）");
            else begin
                $display("  ERROR: 未冲到上限，控制环可能不工作");
                errors = errors + 1;
            end

            // 极端偏红：R/B 都很高、G 很低 => R/B 增益应降到下限。
            // ⚠️ G 必须 >= DARK_LEVEL(16)，否则会触发暗场保护，统计被拒、
            //    增益根本不动 —— 那样测试就是【假通过】。这里用 G=40。
            for (n = 0; n < 400; n = n + 1) send_frame(8'd250, 8'd40, 8'd250, 400, 1'b1);
            $display("  极端偏红 400 帧后 R=%0d B=%0d (下限8)", a_rgain, a_bgain);
            if (a_rgain < 6'd8 || a_bgain < 6'd8) begin
                $display("  ERROR: 越过下限");
                errors = errors + 1;
            end else if (a_rgain == 6'd8 && a_bgain == 6'd8)
                $display("  -> 下限钳位正确（降到 8 后停住）");
            else begin
                $display("  ERROR: 未降到下限（R=%0d B=%0d），控制环可能不工作",
                         a_rgain, a_bgain);
                errors = errors + 1;
            end
        end
    endtask

    //==========================================================================
    // T5：暗场保护
    //==========================================================================
    task test_dark;
        reg [5:0] r0, b0;
        integer n;
        begin
            $display("[T5] 暗场保护 ...");
            rst_n = 0;
            repeat (4) @(negedge clk);
            rst_n = 1; en = 1;
            @(negedge clk);
            for (n = 0; n < 60; n = n + 1) send_frame(8'd80, 8'd200, 8'd80, 400, 1'b1);
            r0 = a_rgain; b0 = a_bgain;
            for (n = 0; n < 60; n = n + 1) send_frame(8'd5, 8'd5, 8'd5, 400, 1'b1);
            $display("  暗场前 R=%0d B=%0d ; 暗场后 R=%0d B=%0d", r0, b0, a_rgain, a_bgain);
            if (a_rgain !== r0 || a_bgain !== b0) begin
                $display("  ERROR: 暗场下增益应保持不变");
                errors = errors + 1;
            end else
                $display("  -> 暗场保护正确");
        end
    endtask

    //==========================================================================
    // T7：收敛后稳定性（防 hunting）
    //   这是最容易漏的一项：只验证"增益会上升"是不够的 ——
    //   若死区小于一档步进，增益会在 N/N+1 之间每帧来回跳，
    //   表现为颜色以帧频轻微闪烁。本测试必须能抓到那种情况。
    //==========================================================================
    task test_stable;
        integer n;
        reg [5:0] rg0, bg0;
        integer    changes;
        reg [5:0]  rg_prev, bg_prev;
        begin
            $display("[T7] 收敛后稳定性（防 hunting）...");
            rst_n = 0;
            repeat (4) @(negedge clk);
            rst_n = 1; en = 1;
            @(negedge clk);

            // 收敛场景必须选【低增益区】才有鉴别力。
            // 由 analyze_deadband.py 穷举得知，hunting 条件是 g < 2^shift/2，
            // 即【增益越小越容易 hunting】。
            //   shift=4 死区 6.25% -> 覆盖全部增益（含最低 8）
            //   shift=5 死区 3.13% -> g<16 时会 hunting
            //   shift=6 死区 1.56% -> g<32 时会 hunting
            // 故本测试喂 (17,16)：目标增益 ≈ 16*16/17 ≈ 15，
            //   shift=5/6 会 hunting，shift=4 稳定 —— 具备真正的鉴别力。
            // （若用 (80,200) 收敛到 g≈40，任何 shift 都不 hunting，测不出问题。）
            for (n = 0; n < 300; n = n + 1) send_frame(8'd17, 8'd16, 8'd17, 400, 1'b1);
            rg0 = a_rgain; bg0 = a_bgain;
            $display("  收敛后 R=%0d (%.3fx) B=%0d (%.3fx)，再跑 60 帧观察是否抖动",
                     rg0, rg0/16.0, bg0, bg0/16.0);

            // 再跑 60 帧，逐帧检查增益是否变化
            changes = 0;
            rg_prev = a_rgain; bg_prev = a_bgain;
            for (n = 0; n < 60; n = n + 1) begin
                send_frame(8'd17, 8'd16, 8'd17, 400, 1'b1);
                if (a_rgain !== rg_prev || a_bgain !== bg_prev) begin
                    changes = changes + 1;
                    if (changes <= 4)
                        $display("    第 %0d 帧变化: R %0d->%0d, B %0d->%0d",
                                 n, rg_prev, a_rgain, bg_prev, a_bgain);
                    rg_prev = a_rgain; bg_prev = a_bgain;
                end
            end
            if (changes != 0) begin
                $display("  ERROR: 收敛后仍有 %0d 次增益变化 => 存在 hunting（颜色会闪）", changes);
                $display("         修法：加大 DEADBAND_SHIFT（死区 >= 半档步进）");
                errors = errors + 1;
            end else begin
                $display("  -> 收敛后 60 帧内增益完全稳定，无 hunting");
            end
        end
    endtask

    //==========================================================================
    initial begin
        $display("=============================================================");
        $display(" wb_awb 自动白平衡 —— 模块级验证");
        $display("=============================================================");
        $display("");
        test_equivalence;
        $display("");
        test_latency;
        $display("");
        test_bypass;
        $display("");
        test_saturate;
        $display("");
        test_converge;
        $display("");
        test_clamp;
        $display("");
        test_dark;
        $display("");
        test_stable;
        $display("");
        $display("=============================================================");
        if (errors == 0) $display(" RESULT: ALL CHECKS PASSED");
        else             $display(" RESULT: %0d ERROR(S)", errors);
        $display("=============================================================");
        $finish;
    end

endmodule
