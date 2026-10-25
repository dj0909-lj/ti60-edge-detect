#=============================================================================
#  EdgeDetect.pt.sdc —— 赛题四 综合/时序约束
#  Device: Ti60F225    Timing Model: C4
#-----------------------------------------------------------------------------
#  本设计是「综合验证」版本，包含两个时钟：
#    clk      ：系统 / 像素时钟，驱动算法链（灰度→行缓存→中值→Sobel→显示合成）
#               以及 I2C 初始化状态机
#    cam_pclk ：DVP 摄像头像素时钟，只驱动采集前端
#
#  ⚠️ 上板前必读：clk 与 cam_pclk 之间目前**没有**异步 FIFO，
#     这里先按 false_path 占位（照搬厂商 Ti60_Demo 的做法）。
#     正式版必须在两域之间插入**像素级异步 FIFO**，否则是真实的 CDC 隐患。
#=============================================================================

# ---- 主时钟 ----
create_clock -period 20 [get_ports {clk}]          # 50MHz
create_clock -period 20 [get_ports {cam_pclk}]     # 摄像头 PCLK 50MHz

# ---- 跨时钟域（占位：上板前换成 FIFO）----
set_false_path -from [get_clocks {cam_pclk}] -to [get_clocks {clk}]
set_false_path -from [get_clocks {clk}] -to [get_clocks {cam_pclk}]

# ---- I2C 是开漏慢速总线，给个宽松约束 ----
set_false_path -from [get_ports {cam_sda}]
