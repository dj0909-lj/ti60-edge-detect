# =============================================================================
#  build_efinity.ps1 —— 一键把赛题四 RTL 送进 Efinity 综合/布局布线
#
#  ⚠️ 为什么要有 "ASCII 构建目录"：
#     Efinity 的 C++ 工具（efx_map / efx_pnr）**无法读取非 ASCII 路径**，
#     在工作区 D:\智能体目录\易灵思赛题四\... 下直接构建会报：
#         filesystem error: Cannot convert character sequence: Illegal byte sequence
#     所以本脚本把源码同步到纯英文路径再做构建。源码的唯一权威副本仍在
#     D:\智能体目录\易灵思赛题四\rtl\，构建目录只是镜像。
#
#  用法（PowerShell）：
#      cd D:\智能体目录\易灵思赛题四\efinity
#      .\build_efinity.ps1                 # 默认只跑综合(map)
#      .\build_efinity.ps1 -Flow pnr       # 综合 + 布局布线
#      .\build_efinity.ps1 -Flow compile   # 综合 + 布局布线 + 生成码流
#
#  若 Efinity 装在别处，改下面这一行。
# =============================================================================

param(
    [ValidateSet("map","pnr","compile","pgm","full")]
    [string]$Flow = "map"
)

$EFX_BIN   = "C:\Efinity\2025.2\bin\efx_run.bat"
$PROJ_NAME = "EdgeDetect"

# 工作区里的项目根（含 rtl / sim / efinity）
$WorkRoot  = Split-Path -Parent $PSScriptRoot          # 易灵思赛题四

# 纯英文构建根目录（Efinity 硬性要求）
$BuildRoot = "D:\fpga_edge_detect\EdgeDetect"
$BuildSrc  = Join-Path $BuildRoot "src"

Write-Host "== 1/3 准备构建目录 ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $BuildSrc | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $BuildRoot "work_syn") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $BuildRoot "outflow") | Out-Null

Write-Host "== 2/3 同步 RTL 源码 ==" -ForegroundColor Cyan
$rtl = Join-Path $WorkRoot "rtl"
Copy-Item (Join-Path $rtl "*.v") $BuildSrc -Force

# 厂商摄像头寄存器表（必须一起进来，否则 cam_init_ctl 会缺模块）
$vendorTable = "C:\Users\<user>\Desktop\边缘检测\src\cmos_i2c\I2C_OV5640_1280720_Config.v"
$vendorDst   = Join-Path $BuildSrc "I2C_OV5640_1280720_Config.v"
if ((Test-Path $vendorTable) -and -not (Test-Path $vendorDst)) {
    Copy-Item $vendorTable $BuildSrc -Force
    Write-Host "   已复制厂商寄存器表 I2C_OV5640_1280720_Config.v"
}
Write-Host ("   同步文件数: " + (Get-ChildItem $BuildSrc -Filter *.v).Count)

Write-Host ("== 3/3 运行 Efinity 流程: " + $Flow + " ==") -ForegroundColor Cyan
Set-Location $BuildRoot
& $EFX_BIN $PROJ_NAME --prj -f $Flow

$code = $LASTEXITCODE
Write-Host ""
if ($code -eq 0) { Write-Host "构建成功。产物在 $BuildRoot\outflow" -ForegroundColor Green }
else             { Write-Host "构建失败（exit=$code）。请看 $BuildRoot\outflow\$PROJ_NAME.log" -ForegroundColor Red }
exit $code
