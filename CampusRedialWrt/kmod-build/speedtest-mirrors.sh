#!/bin/bash
SHA=d5fcb18e5420670c8734c6a659873e73adab6dac
REPO=CodeLinaro-mirror/qsdk_oss_kernel_linux-ipq-5.4
T=$(mktemp -d)
t() {
  name="$1"; url="$2"; shift 2
  out="$T/$name.bin"
  r=$(curl -sSL --max-time 10 -o "$out" -w "%{http_code}|%{speed_download}|%{size_download}" "$@" "$url" 2>/dev/null)
  sp=$(echo "$r" | cut -d'|' -f2); sz=$(echo "$r" | cut -d'|' -f3)
  printf '%-16s http=%s  %6d KB/s  got=%d KB\n' "$name" "$(echo "$r"|cut -d'|' -f1)" $(( ${sp%.*} / 1024 )) $(( ${sz:-0} / 1024 ))
  rm -f "$out"
}
t codeload       "https://codeload.github.com/$REPO/tar.gz/$SHA"
t codeload_np    "https://codeload.github.com/$REPO/tar.gz/$SHA" --noproxy '*'
t ghfast         "https://ghfast.top/https://github.com/$REPO/archive/$SHA.tar.gz"
t ghproxy_net    "https://ghproxy.net/https://github.com/$REPO/archive/$SHA.tar.gz"
t gh_proxy_com   "https://gh-proxy.com/https://github.com/$REPO/archive/$SHA.tar.gz"
t gitmirror      "https://hub.gitmirror.com/https://github.com/$REPO/archive/$SHA.tar.gz"
t llkk           "https://gh.llkk.cc/https://github.com/$REPO/archive/$SHA.tar.gz"
rm -rf "$T"
