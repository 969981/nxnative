#!/usr/bin/env python3
"""Verify/reapply narrowly scoped fork fixes after each upstream synchronization.

Every change is a deterministic, byte-exact substitution against the upstream
file. Unexpected local edits or upstream refactors cause a hard failure instead
of silently losing local patches.
"""
from pathlib import Path
import subprocess
import sys

PATCHES = {
    "dm/gfx/tools/shader_split.py": (
        (
            """        for i, m in enumerate(cra.narc_members(d, label)): scan_blob(cra.undo(m), f'{label}/{i}', out, depth + 1)
""",
            """        try:
            members = cra.narc_members(d, label)
            for i, m in enumerate(members): scan_blob(cra.undo(m), f'{label}/{i}', out, depth + 1)
        except cra.Error as e:
            red(str(e))   # malformed NARC is an explicit format rejection, not an undeclared exception
""",
        ),
    ),
    "dm/gfx/tools/cra.py": (
        (
            "def narc_members(d, where='NARC'):\n    if d[:4] != b'NARC': raise Error(f'{where}: not a NARC')\n    o, n = struct.unpack_from('<HH', d, 0xc); secs = {}\n    for _ in range(n):\n        if o + 8 > len(d): raise Error(f'{where}: a section past the end')\n        s = struct.unpack_from('<I', d, o + 4)[0]; secs[d[o:o + 4]] = o; o += s\n    if b'BTAF' not in secs or b'GMIF' not in secs: raise Error(f'{where}: no BTAF or GMIF')\n    fat = secs[b'BTAF']; data = secs[b'GMIF'] + 8\n    out = []\n    for i in range(struct.unpack_from('<I', d, fat + 8)[0]):\n        a, b = struct.unpack_from('<II', d, fat + 12 + 8 * i)\n        if not data + a <= data + b <= len(d): raise Error(f'{where}: member {i} past the end')\n        out.append(d[data + a:data + b])\n    return out\n",
            "def narc_members(d, where='NARC'):\n    if d[:4] != b'NARC': raise Error(f'{where}: not a NARC')\n    if len(d) < 16: raise Error(f'{where}: truncated NARC header')\n    o, n = struct.unpack_from('<HH', d, 0xc); secs = {}\n    if o < 16 or o > len(d): raise Error(f'{where}: invalid section table offset')\n    for _ in range(n):\n        if o + 8 > len(d): raise Error(f'{where}: a section past the end')\n        s = struct.unpack_from('<I', d, o + 4)[0]\n        if s < 8 or s > len(d) - o: raise Error(f'{where}: invalid section size')\n        secs[d[o:o + 4]] = (o, s); o += s\n    if b'BTAF' not in secs or b'GMIF' not in secs: raise Error(f'{where}: no BTAF or GMIF')\n    fat, fat_size = secs[b'BTAF']\n    gmif, gmif_size = secs[b'GMIF']\n    if fat_size < 12: raise Error(f'{where}: truncated BTAF section')\n    count = struct.unpack_from('<I', d, fat + 8)[0]\n    if count > (fat_size - 12) // 8: raise Error(f'{where}: BTAF member table exceeds its section')\n    data, data_end = gmif + 8, gmif + gmif_size\n    out = []\n    for i in range(count):\n        a, b = struct.unpack_from('<II', d, fat + 12 + 8 * i)\n        if not 0 <= a <= b <= data_end - data: raise Error(f'{where}: member {i} past the end')\n        out.append(d[data + a:data + b])\n    return out\n",
        ),
    ),
    "dm/ios/tools/gen_build.py": (
        (
            """#                     OTHER_CFLAGS (-D), frameworks (Cocoa is replaced by what the UIKit side already has, skipped)""",
            """#                     OTHER_CFLAGS (-D), frameworks (macOS-only Cocoa, IOBluetooth and IOKit are excluded from iOS linking)""",
        ),
        (
            """print('DM_FRAMEWORKS = ' + ' '.join(f'-framework {f}' for f in fws if f != 'Cocoa'))""",
            """print('DM_FRAMEWORKS = ' + ' '.join(f'-framework {f}' for f in fws if f not in ('Cocoa', 'IOBluetooth', 'IOKit')))""",
        ),
    ),
}


def source(ref, path):
    return subprocess.check_output(["git", "show", f"{ref}:{path}"])


def overlay(path, data):
    if path == "dm/ios/tools/gen_build.py":
        # Upstream now queries the actual iOS SDK and excludes every framework
        # absent from it. That supersedes our old hard-coded macOS-only list.
        # Accept only the complete verified upstream implementation, not a
        # partial rewrite that could reintroduce Cocoa/IOKit link failures.
        sdk_markers = (
            b"['xcrun', '--sdk', 'iphoneos', '--show-sdk-path']",
            b"mac_only = [f for f in fws if not os.path.isdir(",
            b"if f not in mac_only",
            b"if mac_only: print('gen_build: not in the iOS SDK",
        )
        if all(marker in data for marker in sdk_markers):
            return data
    for old_text, new_text in PATCHES[path]:
        old, new = old_text.encode(), new_text.encode()
        if data.count(old) == 1:
            data = data.replace(old, new, 1)
        elif data.count(new) == 1 and old not in data:
            pass  # upstream has already incorporated this exact change
        else:
            raise SystemExit(f"Upstream changed the fork patch site in {path}; manual review required.")
    return data


def main():
    if (len(sys.argv) == 4 and sys.argv[1] == "verify"):
        baseline, local = sys.argv[2:]
        for path in PATCHES:
            if overlay(path, source(baseline, path)) != source(local, path):
                raise SystemExit(f"Unexpected local modifications to {path}; refusing to overwrite.")
        print("Verified all fork overlays against the previous upstream revision")
    elif (len(sys.argv) == 3 and sys.argv[1] == "apply"):
        for path in PATCHES:
            Path(path).write_bytes(overlay(path, source(sys.argv[2], path)))
        print(f"Applied fork overlays to upstream {sys.argv[2]}")
    else:
        raise SystemExit("Usage: apply_narc_rejection.py verify BASELINE LOCAL | apply UPSTREAM")


if __name__ == "__main__":
    main()
