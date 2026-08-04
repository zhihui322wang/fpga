#!/usr/bin/env python3
import sys, pathlib
tcl = pathlib.Path(sys.argv[1]).read_text()
with open(sys.argv[2], 'w') as f:
    for line in tcl.strip().split('\n'):
        p = line.split()
        if len(p) == 3 and p[0] == 'jwrite':
            f.write(f'{int(p[1],16):05X} {int(p[2],16):08X}\n')
print(f'{sys.argv[2]}: {sum(1 for l in tcl.strip().split(chr(10)) if l.startswith("jwrite"))} words')
