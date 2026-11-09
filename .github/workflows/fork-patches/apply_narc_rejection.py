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
