#!/usr/bin/env python3
"""
AWB 死区参数（DEADBAND_SHIFT）的 hunting 风险穷举分析。

背景：wb_awb.v 用"积分控制器"逐帧调整 R/B 增益（Q4.4，16 = 1.0x），
      判据是 sum_r 与 sum_g 比较，带死区 deadband = sum_g >> DEADBAND_SHIFT。
      若死区过小，增益可能在 N 与 N+1 之间每帧来回跳（hunting），
      表现为颜色以帧频闪烁。

本脚本：对所有合理的 (R_in, G_in) 组合，模拟控制环收敛过程，
        检查收敛后是否稳定，并统计 hunting 发生率。
目的：用数据决定 DEADBAND_SHIFT 取 5 还是 6（而不是凭感觉）。
"""

def simulate(r_in, g_in, deadband_shift, gain_init=24, gain_min=8, gain_max=48,
             max_frames=600, settle_frames=400, observe_frames=200):
    """
    模拟 wb_awb 的控制环（每帧更新一次）。
    返回 (收敛后增益, 观察期内的变化次数)
    """
    gain = gain_init
    history = []
    for f in range(max_frames):
        # 帧内统计（增益后 R）
        r_scaled = min(255, (r_in * gain) >> 4)
        sum_r = r_scaled
        sum_g = g_in
        sum_b = min(255, (r_in * gain) >> 4)   # B 同 R 处理（本分析只看 R 通道）
        dead = sum_g >> deadband_shift

        if f >= settle_frames:
            history.append(gain)

        # 帧末更新
        if sum_r + dead < sum_g:
            if gain < gain_max:
                gain += 1
        elif sum_r > sum_g + dead:
            if gain > gain_min:
                gain -= 1

    changes = sum(1 for i in range(1, len(history)) if history[i] != history[i-1])
    return gain, changes


def analyze(deadband_shift, r_range=range(1, 256), g_range=range(16, 256)):
    hunting_cases = []
    total = 0
    for g in g_range:
        for r in r_range:
            total += 1
            gain, changes = simulate(r, g, deadband_shift)
            if changes > 0:
                hunting_cases.append((r, g, gain, changes))
    return total, hunting_cases


if __name__ == "__main__":
    print("=" * 72)
    print(" AWB 死区参数 hunting 风险穷举")
    print("=" * 72)

    for shift in (4, 5, 6, 7):
        total, hunt = analyze(shift)
        rate = 100.0 * len(hunt) / total
        print(f"\nDEADBAND_SHIFT = {shift}  (死区 = sum_g >> {shift} = {100.0/(2**shift):.3f}%)")
        print(f"  测试组合数 : {total}")
        print(f"  hunting 数 : {len(hunt)}  ({rate:.2f}%)")
        if hunt:
            print("  样例 (R_in, G_in, 收敛增益, 变化次数):")
            for c in hunt[:6]:
                print(f"      {c}")

    # 针对"偏绿"典型场景单独看
    print("\n" + "=" * 72)
    print(" 典型偏绿场景逐项对照")
    print("=" * 72)
    scenarios = [(60, 100), (80, 200), (40, 90), (100, 150), (30, 70), (120, 180)]
    print(f"{'R_in':>6} {'G_in':>6} | {'shift=5 增益/变化':>20} | {'shift=6 增益/变化':>20}")
    print("-" * 72)
    for r, g in scenarios:
        g5, c5 = simulate(r, g, 5)
        g6, c6 = simulate(r, g, 6)
        flag5 = "  <-- HUNT" if c5 else ""
        flag6 = "  <-- HUNT" if c6 else ""
        print(f"{r:>6} {g:>6} | {g5:>8} / {c5:<8}{flag5:>3} | {g6:>8} / {c6:<8}{flag6:>3}")
