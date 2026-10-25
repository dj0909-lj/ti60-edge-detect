`timescale 1ns/1ns
// Verify median networks against the TRUE 9-point median.
//   A) separable  : med3(med3(row0), med3(row1), med3(row2))      <- current edge_detect_3x3
//   B) rtl/Smith  : med(med(min*), med(med*), med(max*))          <- rtl/median_filter_3x3.v
//   C) textbook   : med(max(min*), med(med*), min(max*))          <- true Smith network
module tb_med_cmp;

    function [7:0] med3f;
        input [7:0] a, b, c;
        reg [7:0] lo, hi, t;
        begin
            lo = (a < b) ? a : b;
            hi = (a < b) ? b : a;
            t  = (hi < c) ? hi : c;
            med3f = (lo > t) ? lo : t;
        end
    endfunction

    function [7:0] min3f;
        input [7:0] a, b, c;
        reg [7:0] lo;
        begin lo = (a<b)?a:b; min3f = (lo<c)?lo:c; end
    endfunction

    function [7:0] max3f;
        input [7:0] a, b, c;
        reg [7:0] hi;
        begin hi = (a<b)?b:a; max3f = (hi<c)?c:hi; end
    endfunction

    // ---- A) separable ----
    function [7:0] sep_med9;
        input [7:0] v0,v1,v2,v3,v4,v5,v6,v7,v8;
        begin
            sep_med9 = med3f(med3f(v0,v1,v2), med3f(v3,v4,v5), med3f(v6,v7,v8));
        end
    endfunction

    // ---- B) rtl/Smith variant (medians of mins/meds/maxes) ----
    function [7:0] smith_b;
        input [7:0] v0,v1,v2,v3,v4,v5,v6,v7,v8;
        reg [7:0] cmin, cmed, cmax;
        begin
            cmin = med3f(min3f(v0,v1,v2), min3f(v3,v4,v5), min3f(v6,v7,v8));
            cmed = med3f(med3f(v0,v1,v2), med3f(v3,v4,v5), med3f(v6,v7,v8));
            cmax = med3f(max3f(v0,v1,v2), max3f(v3,v4,v5), max3f(v6,v7,v8));
            smith_b = med3f(cmin, cmed, cmax);
        end
    endfunction

    // ---- C) textbook Smith: max(min*), med(med*), min(max*) ----
    function [7:0] smith_c;
        input [7:0] v0,v1,v2,v3,v4,v5,v6,v7,v8;
        reg [7:0] a, b, c;
        begin
            a = max3f(min3f(v0,v1,v2), min3f(v3,v4,v5), min3f(v6,v7,v8));
            b = med3f(med3f(v0,v1,v2), med3f(v3,v4,v5), med3f(v6,v7,v8));
            c = min3f(max3f(v0,v1,v2), max3f(v3,v4,v5), max3f(v6,v7,v8));
            smith_c = med3f(a, b, c);
        end
    endfunction

    // ---- reference: insertion sort of 9 ----
    function [7:0] true_med9;
        input [7:0] v0,v1,v2,v3,v4,v5,v6,v7,v8;
        reg [7:0] a [0:8];
        reg [7:0] t;
        integer i, j;
        begin
            a[0]=v0;a[1]=v1;a[2]=v2;a[3]=v3;a[4]=v4;
            a[5]=v5;a[6]=v6;a[7]=v7;a[8]=v8;
            for (i=1;i<9;i=i+1) begin
                t=a[i]; j=i-1;
                while (j>=0 && a[j]>t) begin a[j+1]=a[j]; j=j-1; end
                a[j+1]=t;
            end
            true_med9 = a[4];
        end
    endfunction

    integer i, n, seed;
    reg [7:0] v [0:8];
    reg [7:0] t_ref, t_a, t_b, t_c;
    integer bad_a, bad_b, bad_c;

    initial begin
        $display("=============================================================");
        $display(" 3x3 median network verification (vs TRUE 9-point median)");
        $display("=============================================================");
        seed = 1; n = 300000;
        bad_a = 0; bad_b = 0; bad_c = 0;
        for (i = 0; i < n; i = i + 1) begin
            v[0]=$random(seed); v[1]=$random(seed); v[2]=$random(seed);
            v[3]=$random(seed); v[4]=$random(seed); v[5]=$random(seed);
            v[6]=$random(seed); v[7]=$random(seed); v[8]=$random(seed);
            t_ref = true_med9(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8]);
            t_a = sep_med9 (v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8]);
            t_b = smith_b  (v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8]);
            t_c = smith_c  (v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8]);
            if (t_a !== t_ref) bad_a = bad_a + 1;
            if (t_b !== t_ref) bad_b = bad_b + 1;
            if (t_c !== t_ref) bad_c = bad_c + 1;
        end
        $display("");
        $display(" trials = %0d", n);
        $display(" A) separable (current edge_detect) : mismatches = %0d  (%.2f%%)",
                 bad_a, 100.0*bad_a/n);
        $display(" B) rtl/median_filter_3x3 (Smith)   : mismatches = %0d  (%.2f%%)",
                 bad_b, 100.0*bad_b/n);
        $display(" C) textbook Smith (max/med/min)    : mismatches = %0d  (%.2f%%)",
                 bad_c, 100.0*bad_c/n);
        $display("");
        if (bad_c == 0) $display(" => C is EXACT, use it");
        else            $display(" => C is not exact, do not use");
        if (bad_a == 0) $display(" => A is exact");
        else            $display(" => A is NOT exact (should be replaced)");
        if (bad_b == 0) $display(" => B is exact");
        else            $display(" => B is NOT exact (do not use as-is)");
        $display("=============================================================");
        $finish;
    end

endmodule
