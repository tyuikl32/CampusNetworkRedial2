# One-shot patcher for the campus-rediald defects (idempotent, asserts each hit).
import re, io, sys

P = r'D:\CampusNetworkRedial\campus-network-redial\luci-app-campus-redial\root\usr\sbin\campus-rediald'

with io.open(P, encoding='utf-8', newline='') as f:
    src = f.read()

# Normalise to LF: a CRLF shebang would make BusyBox fail to exec the script.
src = src.replace('\r\n', '\n').replace('\r', '\n')

def sub_once(pat, new, label, flags=0):
    global src
    m = re.search(pat, src, flags)
    assert m, 'NOT FOUND: ' + label
    repl = new(m) if callable(new) else new
    src = src[:m.start()] + repl + src[m.end():]
    print('ok  ' + label)

# ---------------------------------------------------------------- defect #1
# BusyBox ash exec-optimises `( cmd ) &`, so $! IS the downloader.  It used to
# run with --max-time SPEED_SECONDS+5 while we killed it at SPEED_SECONDS, so
# SIGTERM arrived before the tool could emit its byte count => speed always 0.
sub_once(
    r'(?m)^(\t+)sleep "\$SPEED_SECONDS"$',
    lambda m: (m.group(1) + '# Let each worker end on its own --max-time so it can still\n'
               + m.group(1) + '# emit its byte count; the kill below is only a safety net.\n'
               + m.group(1) + 'sleep $((SPEED_SECONDS + 1))'),
    'speed: sleep window')

# ---------------------------------------------------------------- defect #2
# Install the per-session default route into the table mwan3 owns for it,
# right after the session reports up (covers every caller of wait_for_up_name).
sub_once(
    r'grep -q true && return 0',
    'grep -q true && {\n'
    '\t\t\t# netifd only installs a default route for the primary PPPoE session,\n'
    '\t\t\t# so the table mwan3 owns for every extra session would stay without\n'
    '\t\t\t# one and mwan3 would flag it error (16) -> dropped from the policy.\n'
    '\t\t\tif [ -x /usr/sbin/campus-redial-mwan3route ]; then\n'
    '\t\t\t\t/usr/sbin/campus-redial-mwan3route "$name" >/dev/null 2>&1 || true\n'
    '\t\t\tfi\n'
    '\t\t\treturn 0\n'
    '\t\t}',
    'mwan3: hook route install into wait_for_up_name')

with io.open(P, 'w', encoding='utf-8', newline='\n') as f:
    f.write(src)

print('written', P)
