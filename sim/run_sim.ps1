# =============================================================================
#  run_sim.ps1 —— 用 ModelSim 跑赛题四的自检仿真
#
#  为什么先复制到临时目录：
#    ModelSim 对含中文的路径（比如 D:\智能体目录\...）兼容性差，
#    vlib/vlog 可能报奇怪的错。脚本先把源码复制到 %TEMP%\yls_sim 再编译。
#
#  用法（在 PowerShell 里）：
#      cd D:\智能体目录\易灵思赛题四\sim
#      .\run_sim.ps1
#
#  若 ModelSim 装在别处，改下面这一行：
# =============================================================================

$MS = "D:\Programs\Moldesim10.6\win64"        # <-- 按你的实际安装路径改

$root  = Split-Path -Parent $PSScriptRoot      # 易灵思赛题四
$rtl   = Join-Path $root "rtl"
$sim   = Join-Path $root "sim"
$tmp   = Join-Path $env:TEMP "yls_sim"
$tmpLB = Join-Path $env:TEMP "yls_lb"
$tmpDV = Join-Path $env:TEMP "yls_dvp"

function Invoke-Sim {
    param([string]$WorkDir, [string]$TopName, [string[]]$Sources)

    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    foreach ($s in $Sources) { Copy-Item $s $WorkDir -Force }
    Set-Location $WorkDir

    & "$MS\vlib.exe" work                        > vlib.log 2>&1
    & "$MS\vlog.exe" -sv *.v                     > vlog.log 2>&1
    & "$MS\vsim.exe" -c -do "run -all; quit -f" "work.$TopName" > vsim.log 2>&1

    # ModelSim 输出是 UTF-16，转成 UTF-8 方便阅读
    Get-Content "$WorkDir\vsim.log" | Out-File "$WorkDir\vsim.txt" -Encoding UTF8
    Get-Content "$WorkDir\vlog.log" | Out-File "$WorkDir\vlog.txt" -Encoding UTF8

    Write-Host "------------- $TopName -------------"
    Get-Content "$WorkDir\vlog.txt" | Select-String -Pattern "Error|Errors:"
    Get-Content "$WorkDir\vsim.txt" | Select-String -Pattern "PASS|FAIL|SKIP|RESULT|mismatches|N0 =|N1 =|before|after|=>"
}

Invoke-Sim -WorkDir $tmpLB -TopName "tb_line_buffer" `
           -Sources @((Join-Path $rtl "line_buffer_3x3.v"), (Join-Path $sim "tb_line_buffer.v"))

Invoke-Sim -WorkDir $tmpDV -TopName "tb_dvp_capture" `
           -Sources @((Join-Path $rtl "dvp_capture.v"), (Join-Path $sim "tb_dvp_capture.v"))

# 全链自检：只需算法链相关文件（显式列举，避免把摄像头/I2C 文件拉进来）
$chain = @("rgb2gray.v","gray_pipeline.v","line_buffer_3x3.v","median_filter_3x3.v",
           "sobel_3x3.v","display_mux.v","debounce.v","threshold_ctrl.v","edge_detect_top.v")
Invoke-Sim -WorkDir $tmp -TopName "tb_edge_detect_top" `
           -Sources (@($chain | ForEach-Object { Join-Path $rtl $_ }) +
                     @(Join-Path $sim "tb_edge_detect_top.v"))

Write-Host ""
Write-Host "日志已生成："
Write-Host "  $tmpDV\vsim.txt      (DVP 采集单元测试)"
Write-Host "  $tmpLB\vsim.txt      (line buffer 单元测试)"
Write-Host "  $tmp\vsim.txt        (全链自检)"
