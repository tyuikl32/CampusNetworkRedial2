#!/bin/sh
# cr-cpu-sample.sh — 每秒采一次 /proc/stat，用于判断"是不是路由器 CPU 把带宽卡住了"。
#
# 背景：聚合下行卡在 ~350 Mbps 时，判据是打流期间 cpu1 是否钉在 100%、softirq 是否占大头
# （实测 99.5% / softirq ~92%）。CPU 打满 ⇒ 瓶颈是每包走 netfilter 慢路径，不是校园网。
# 修法见 CampusRedialWrt/tools/install-flow-offload.sh；完整记录见 docs/05-故障排查.md §3.7。
#
# 用法（路由器上）：
#   sh cr-cpu-sample.sh 20 > /tmp/cpu.log 2>&1 &     # 后台采 20 秒
#   # 立刻在别的窗口打流（PC 端多流下载），采完后取回 /tmp/cpu.log
#
# 解读：每行是当时 /proc/stat 的全部 cpu* 行（用 '|' 连接），字段顺序为
#   cpu user nice system idle iowait irq softirq steal guest guest_nice
# 逐秒算 busy = 100 - Δidle - Δiowait（百分比）；cpu0/cpu1 分开看能判断是否单核饱和。
# 一次性解读：
#   awk '/^cpu /{print $2+$3+$4, $5, $6}' /tmp/cpu.log    # 看相邻两行的差值即可
# 或把文件交给 PC 侧脚本（见 docs/05 §3.7 的说明）。
n=${1:-20}
i=0
while [ "$i" -lt "$n" ]; do
	grep -E '^cpu' /proc/stat | tr '\n' '|'
	echo
	i=$((i + 1))
	sleep 1
done
