#!/bin/bash
# agon_vclk on the clock models of the modules (seconds)
set -e
cd "$(dirname "$0")"
M=../../../modules
iverilog -g2005 -o build_vclk -s tb_vclk tb_vclk.v ../../rtl/agon_vclk.v $M/rtl/video/hdmi/pll_reset.v $M/sim/hdmi/xilinx_models.v
vvp -n build_vclk | grep -v "^VCD" | tail -12
