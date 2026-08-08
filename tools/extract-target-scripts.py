#!/usr/bin/env python3
"""Extract the on-target scripts that build-sdk.sh writes as nested heredocs.

build-sdk.sh generates an init which, at boot, writes /bin/load-wifi,
/usr/bin/wfb-start and the rest into tmpfs. Buildroot ships them as real files
instead, so this lifts each heredoc body out into the rootfs overlay once.

One-shot migration aid, not part of any build.
"""
import os
import re
import sys

SRC = 'build-sdk.sh'
DEST = 'buildroot-ext/board/ssr621q/rootfs-overlay'

# Quoted terminators only: an unquoted one would have been expanded by the
# outer shell, so its body is not literal and cannot be lifted as-is.
START = re.compile(r"^cat > (?P<path>/[^\s]+) << '(?P<term>\w+)'$")

def main():
    lines = open(SRC).read().split('\n')
    written = []
    i = 0
    while i < len(lines):
        m = START.match(lines[i])
        if not m:
            i += 1
            continue
        path, term = m.group('path'), m.group('term')
        body, j = [], i + 1
        while j < len(lines) and lines[j] != term:
            body.append(lines[j])
            j += 1
        if j >= len(lines):
            sys.exit(f"unterminated heredoc for {path} at line {i+1}")
        out = os.path.join(DEST, path.lstrip('/'))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, 'w') as f:
            f.write('\n'.join(body) + '\n')
        os.chmod(out, 0o755)
        written.append((path, len(body)))
        i = j + 1

    for path, n in written:
        print(f"{n:5d}  {path}")
    print(f"\n{len(written)} scripts, {sum(n for _, n in written)} lines")

main()
