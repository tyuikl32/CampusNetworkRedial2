<#
.SYNOPSIS
  PC 端聚合带宽测量（经路由器转发），并用路由器侧每会话 rx_bytes 交叉验证。

.DESCRIPTION
  这是本项目量"多拨聚合到底有多少"的标准装置，2026-09-11 用它得出 flow offload 前后
  350 → 690 Mbps 的结论。它刻意规避了四个会得出错误结论的坑：

  1) 目标必须是**持续流**。LibreSpeed 的 garbage.php 不带 ckSize 时只回 4 MB 就结束，
     于是 "N 条流" 实际测的是 N×4MB ÷ 窗口（实测 5/20/40 条流 = 15.8/63/126 Mbps 的假吞吐）。
     本脚本默认目标带 ?ckSize=100。
  2) 不能用 curl 自报速度。--parallel 下 %{speed_download} 与网卡计数能差 30%~50%
     （实测 curl 859 / 路由器 621 / PC 网卡 629 Mbps）。一律以**字节增量 ÷ 实测窗口**为准。
  3) 采样窗口不能含空闲。计数器先取一次 → 打流 → **打流仍在进行时**再取一次，否则尾部空闲会稀释速率。
  4) PC 可能有多条默认路由（WiFi 抢走流量）。用 -SourceIp 绑源地址强制走目标网卡，
     并同时采 WiFi 网卡计数，确认没有泄漏。

.PARAMETER Streams
  并发 TCP 流数（每条流都是独立的 --parallel 连接）。

.PARAMETER Url
  目标 URL（务必是持续流；LibreSpeed 后端请带 ?ckSize=100）。

.PARAMETER Seconds
  打流时长（秒）。路由器侧的第二次采样发生在 Seconds-1.5 秒处。

.PARAMETER SourceIp
  PC 上指向被测量网卡的源地址（默认 192.168.6.229 = 走 192.168.6.1 那台路由器的以太网口）。

.PARAMETER RouterScript
  调用路由器 SSH 的包装脚本（默认 D:\CampusNetworkRedial\scratch\cr.ps1）。

.EXAMPLE
  .\measure-aggregate.ps1 -Streams 20 -Url 'http://test.xidian.edu.cn/backend/garbage.php?ckSize=100' -Seconds 12

.NOTES
  判读要点：路由器聚合 ≈ PC 网卡收到（对得上才可信）；若差距很大先查 WiFi 泄漏与目标是否为持续流。
#>
param(
  [int]$Streams = 20,
  [Parameter(Mandatory = $true)][string]$Url,
  [string]$HostHeader = '',
  [int]$Seconds = 12,
  [string]$Tag = 'agg',
  [string]$SourceIp = '192.168.6.229',
  [string]$LanNic = '以太网',
  [string]$WifiNic = 'WLAN',
  [string]$RouterScript = 'D:\CampusNetworkRedial\scratch\cr.ps1'
)

$ErrorActionPreference = 'Stop'

function Get-RouterCounters {
  # 枚举 /sys/class/net/pppoe-wan*（注意：主会话的接口名是 pppoe-wan，没有数字后缀，
  # 用 pppoe-wan\d+ 去匹配会把它漏掉，聚合就少算一条会话）
  $raw = & $RouterScript run 'for d in /sys/class/net/pppoe-wan*; do n=$(basename $d); v=$(cat $d/statistics/rx_bytes 2>/dev/null); [ -n "$v" ] && echo "$n=$v"; done' 2>$null
  $h = @{}
  foreach ($line in ($raw -split "`n")) {
    if ($line -match '^(pppoe-wan\d*)=(\d+)') { $h[$Matches[1]] = [int64]$Matches[2] }
  }
  return $h
}

Write-Output ("=== {0}: {1} streams x {2}s -> {3}" -f $Tag, $Streams, $Seconds, $Url)

$rand = [guid]::NewGuid().ToString('N').Substring(0, 6)
$urls = 1..$Streams | ForEach-Object { $Url + $(if ($Url -match '\?') { '&' } else { '?' }) + "cr=$_`_$rand" }

$before = Get-RouterCounters
$eth0 = (Get-NetAdapterStatistics -Name $LanNic).ReceivedBytes
$wifi0 = (Get-NetAdapterStatistics -Name $WifiNic).ReceivedBytes
$outFile = Join-Path $env:TEMP "agg-$Tag.txt"
if (Test-Path $outFile) { Remove-Item $outFile -Force }

$args = @('-s', '--noproxy', '*', '--parallel', '--parallel-max', "$Streams",
          '--max-time', "$Seconds", '-w', '%{speed_download};%{http_code}\n')
if ($SourceIp) { $args += @('--interface', $SourceIp) }
if ($HostHeader) { $args += @('-H', "Host: $HostHeader") }
foreach ($u in $urls) { $args += @('-o', 'NUL', $u) }

$t0 = Get-Date
$proc = Start-Process -FilePath 'curl.exe' -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput $outFile

# 关键：在打流仍在进行时取第二次计数（避免尾部空闲稀释）
Start-Sleep -Milliseconds ([int](($Seconds - 1.5) * 1000))
$mid = Get-RouterCounters
$eth1 = (Get-NetAdapterStatistics -Name $LanNic).ReceivedBytes
$wifi1 = (Get-NetAdapterStatistics -Name $WifiNic).ReceivedBytes
$t1 = Get-Date

$proc | Wait-Process -Timeout ($Seconds + 30)
$window = ($t1 - $t0).TotalSeconds

$ok = 0; $codes = @{}
if (Test-Path $outFile) {
  foreach ($line in (Get-Content $outFile)) {
    $parts = "$line".Trim() -split ';'
    if ($parts.Count -lt 2) { continue }
    $code = $parts[1]
    $codes[$code] = 1 + $(if ($codes.ContainsKey($code)) { $codes[$code] } else { 0 })
    if ($code -eq '200') { $ok++ }
  }
}

$total = 0.0; $per = @()
foreach ($k in ($before.Keys | Sort-Object)) {
  $d = $mid[$k] - $before[$k]
  $mb = $d * 8 / 1e6 / $window
  $total += $mb
  $per += ("{0}={1:N1}" -f $k.Replace('pppoe-wan', 'wan'), $mb)
}

Write-Output ("    window {0:N2}s | streams ok {1}/{2} | codes: {3}" -f $window, $ok, $Streams,
  (($codes.Keys | Sort-Object | ForEach-Object { "$_ x$($codes[$_])" }) -join '  '))
Write-Output ("    router per-session Mbps: {0}" -f ($per -join '  '))
Write-Output ("    ROUTER AGGREGATE : {0:N1} Mbps   <-- 以后者为准" -f $total)
Write-Output ("    PC {0} rx : {1:N1} Mbps   ({2} leak: {3:N1})" -f $LanNic, (($eth1 - $eth0) * 8 / 1e6 / $window), $WifiNic, (($wifi1 - $wifi0) * 8 / 1e6 / $window))
