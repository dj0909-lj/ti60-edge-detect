#!/usr/bin/env python3
"""
严格解析 Efinity 时序报告，提取所有涉及自研模块的路径及其 slack。

为什么需要专门脚本：timing.rpt 里有多层子报告（Max/Min Critical Paths、
每个 clock pair 一个 "Path Detail Report"），简单地"遇到 Path Begin/Path End
就记、遇到 Slack 就配对"会错配 —— 一个 Path 头部与后面的 Slack 之间有若干
中间小节，容易张冠李戴。本脚本按块解析，只在同一个 "++++ Path N" 块内配对。
"""

import re
import sys
import io

# 强制 UTF-8 输出
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

RPT = r"D:\fpga_edge_detect\VF2026_HDMI_V6\outflow\Ti60_Demo.timing.rpt"

OURS = re.compile(r'u_wb|wb_awb|u_edge_detect|u_med9|u_display_mux|u_key_ctrl|u_rgb2gray')

def main():
    with open(RPT, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.readlines()

    # 定位两个章节
    sec_max = sec_min = None
    for i, l in enumerate(lines):
        if '3. Path Details for Max Critical Paths (begin)' in l:
            sec_max = i
        elif '4. Path Details for Min Critical Paths (begin)' in l:
            sec_min = i
    print(f"报告共 {len(lines)} 行")
    print(f"  setup(Max) 章节起于行 {sec_max+1}")
    print(f"  hold(Min)  章节起于行 {sec_min+1 if sec_min else 'N/A'}")

    # 按 "++++ Path N" 切块
    blocks = []          # (start_line, [lines])
    cur_start = None
    cur = []
    for i, l in enumerate(lines):
        if re.match(r'^\s*\+{4} Path \d+', l):
            if cur_start is not None:
                blocks.append((cur_start, cur))
            cur_start = i
            cur = [l]
        elif cur_start is not None:
            cur.append(l)
    if cur_start is not None:
        blocks.append((cur_start, cur))
    print(f"  共解析出 {len(blocks)} 个 Path 块\n")

    def which_section(lineno):
        if sec_min is not None and lineno >= sec_min:
            return 'hold'
        return 'setup'

    ours = []
    for start, blk in blocks:
        text = ''.join(blk)
        m_begin = re.search(r'Path Begin\s*:\s*(\S+)', text)
        m_end   = re.search(r'Path End\s*:\s*(\S+)', text)
        m_slack = re.search(r'Slack\s*:\s*(-?[\d.]+)\s*\((required time|arrival time)', text)
        if not (m_begin and m_end and m_slack):
            continue
        b, e, s = m_begin.group(1), m_end.group(1), float(m_slack.group(1))
        if OURS.search(b) or OURS.search(e):
            ours.append((which_section(start+1), start+1, s, b, e))

    print("=" * 78)
    print(" 涉及自研模块的时序路径")
    print("=" * 78)
    if not ours:
        print("  (无)")
    for sec, ln, s, b, e in sorted(ours, key=lambda x: x[2]):
        flag = "  <== 最紧" if s == min(x[2] for x in ours) else ""
        print(f"\n  [{sec}] 行 {ln}   slack = {s:+.3f} ns{flag}")
        print(f"      起点: {b}")
        print(f"      终点: {e}")

    # 全局最紧的 setup / hold
    print("\n" + "=" * 78)
    print(" 全局最紧路径（不论归属）")
    print("=" * 78)

    allpaths = []          # (section, lineno, slack, begin, end)
    for start, blk in blocks:
        text = ''.join(blk)
        m_b = re.search(r'Path Begin\s*:\s*(\S+)', text)
        m_e = re.search(r'Path End\s*:\s*(\S+)', text)
        m_s = re.search(r'Slack\s*:\s*(-?[\d.]+)\s*\(', text)
        if m_b and m_e and m_s:
            allpaths.append((which_section(start + 1), start + 1,
                             float(m_s.group(1)), m_b.group(1), m_e.group(1)))

    for want in ('setup', 'hold'):
        sub = [p for p in allpaths if p[0] == want]
        if not sub:
            print(f"\n  [{want}] 无路径")
            continue
        sec, ln, s, b, e = min(sub, key=lambda x: x[2])
        print(f"\n  [{want}] 行 {ln}  slack = {s:+.3f} ns")
        print(f"      起点: {b[:110]}")
        print(f"      终点: {e[:110]}")

    # 负 slack 统计
    print("\n" + "=" * 78)
    negs = [x for x in allpaths if x[2] < 0]
    print(f" 全局负 slack 条数: {len(negs)}")
    ours_neg = [x for x in ours if x[2] < 0]
    print(f" 自研模块负 slack 条数: {len(ours_neg)}")
    print("=" * 78)


if __name__ == '__main__':
    main()
