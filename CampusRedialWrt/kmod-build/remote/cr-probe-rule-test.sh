#!/bin/sh
# cr-probe-rule-test.sh -- probe verdict rule regression test (ASCII output on purpose:
# the host-side SSH helper mis-decodes non-ASCII, and the daemon comments contain arrows).
#
# RULE (must match PC-side C# ProbeClient and PowerShell Test-CampusExit.ps1):
#   ANY HTTP response (200/302/404/500...) = reachable = PASS
#   only timeout / connect / DNS / TLS failure = FAIL (= bad exit, keep redialing)
#
# It extracts the INSTALLED /usr/sbin/campus-rediald bound_fetch/probe_one verbatim and
# exercises both fetch backends, because that is where the rule breaks:
#   curl          -> 404 exits 0        (ok by default)
#   uclient-fetch -> 404 exits 8        (was judged as FAILURE before the fix)
#   uclient-fetch also FOLLOWS redirects, so "got a response then next hop failed" needs
#   the curl cross-check to be told apart from "never connected".
#
# Usage: sh cr-probe-rule-test.sh [interface]
#   Interface defaults to pppoe-wan. Pass br-lan for a stable binding: while the pool is
#   redialing (expected when the canary is throttled) PPP source addresses flap and make
#   this test flaky for reasons unrelated to the verdict rule.
set -u
DAEMON=/usr/sbin/campus-rediald
WORK=/tmp/cr-probe-fn.sh
EMPTY_LIB=/tmp/cr-fake-bind.so

if [ ! -r "$DAEMON" ]; then
	echo "FATAL: $DAEMON not found"
	exit 1
fi

: > "$WORK"
awk '/^FETCH_HTTP_ERROR_RC=/{f=1} f{print} f&&/^bound_fetch\(\)/{b=1} b&&/^\}/{exit}' "$DAEMON" >> "$WORK"
awk '/^probe_one\(\)/{p=1} p{print} p&&/^\}/{exit}' "$DAEMON" >> "$WORK"
if ! grep -q 'bound_fetch()' "$WORK" || ! grep -q 'probe_one()' "$WORK"; then
	echo "FATAL: could not extract functions from $DAEMON"
	exit 1
fi
if ! sh -n "$WORK"; then
	echo "FATAL: extracted functions do not parse"
	exit 1
fi
. "$WORK"
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-6}

passed=0
failed=0
skipped=0
have_addr() {
	[ -n "$(ip -4 -o addr show dev "$1" 2>/dev/null | awk 'NR==1 { print $4; exit }')" ]
}
check() { # $1=label $2=expect ok|fail $3=url $4=iface
	if probe_one "$3" "$4"; then got=ok; else got=fail; fi
	if [ "$got" = "$2" ]; then
		outcome=PASS; passed=$((passed + 1))
	elif [ "$2" = ok ] && [ "$4" != br-lan ] && ! have_addr "$4"; then
		# The pool redials sessions while the canary is judged bad, so a PPP source
		# address can vanish mid-test; that is a test artefact, not a verdict bug.
		outcome=SKIP; skipped=$((skipped + 1))
		got="$got(iface down)"
	else
		outcome=FAIL; failed=$((failed + 1))
	fi
	printf '  [%s] %-40s expect=%-4s got=%-4s\n' "$outcome" "$1" "$2" "$got"
}

run_suite() { # $1=backend label $2=iface
	echo "=== backend: $1 ==="
	check "404 missing path"        ok   "https://mirrors.pku.edu.cn/definitely-missing-cr-test" "$2"
	check "500 canary over http"    ok   "http://abvolcapi.douyucdn.cn/" "$2"
	check "302 canary over http"    ok   "http://apiv2.douyucdn.cn/" "$2"
	check "blackhole = timeout"     fail "http://10.255.255.1/" "$2"
	check "real canary over https"  fail "https://abvolcapi.douyucdn.cn/" "$2"
}

IFACE=${1:-}
if [ -z "$IFACE" ]; then
	IFACE=$(ip -4 -o addr show 2>/dev/null | awk '/pppoe-wan/ { print $2; exit }')
	[ -n "$IFACE" ] || IFACE=br-lan
fi
ADDR=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk 'NR==1 { split($4, a, "/"); print a[1]; exit }')
echo "interface: $IFACE (${ADDR:-no address})"
[ "$IFACE" = br-lan ] && echo "NOTE: br-lan cannot route to the internet; use a pppoe interface for real verdicts"
echo

BIND_LIBRARY=/usr/lib/campus-redial-bind.so
run_suite "curl (bind helper absent)" "$IFACE"

: > "$EMPTY_LIB"
echo
BIND_LIBRARY=$EMPTY_LIB
run_suite "uclient-fetch via LD_PRELOAD" "$IFACE"
rm -f "$EMPTY_LIB"

echo
echo "summary: PASS=$passed FAIL=$failed SKIP=$skipped"
[ "$failed" -eq 0 ]

