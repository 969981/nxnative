#!/usr/bin/env python3
"""Verify and reapply the fork's narrow NARC rejection fix across upstream syncs.

Only this exact substitution is allowed. If upstream rewrites this reader or any
other local edits appear, fail closed for manual review, rather than overwriting
upstream code or silently discarding the fork's fix.
"""
from pathlib import Path
import subprocess
import sys

TARGET = "dm/gfx/tools/shader_split.py"
OLD = """        for i, m in enumerate(cra.narc_members(d, label)): scan_blob(cra.undo(m), f'{label}/{i}', out, depth + 1)
"""
NEW = """        try:
            members = cra.narc_members(d, label)
            for i, m in enumerate(members): scan_blob(cra.undo(m), f'{label}/{i}', out, depth + 1)
        except cra.Error as e:
            red(str(e))   # malformed NARC is an explicit format rejection, not an undeclared exception
"""


def source(ref):
    return subprocess.check_output(["git", "show", f"{ref}:{TARGET}"])


def overlay(data):
    old, new = OLD.encode(), NEW.encode()
    if data.count(old) == 1:
        return data.replace(old, new, 1)
    if data.count(new) == 1 and old not in data:
        return data  # upstream has incorporated this precise fix
    raise SystemExit(
        f"Cannot apply fork NARC guard to {TARGET}: upstream changed the matching code; review required."
    )


def main():
    if len(sys.argv) != 4 and not (len(sys.argv) == 3 and sys.argv[1] == "apply"):
        raise SystemExit("Usage: apply_narc_rejection.py verify BASELINE LOCAL | apply UPSTREAM")
    if sys.argv[1] == "verify":
        baseline, local = sys.argv[2:]
        if overlay(source(baseline)) != source(local):
            raise SystemExit(
                f"Unexpected local changes to {TARGET}; only the documented NARC guard is allowed."
            )
        print("Verified existing fork NARC guard against previous upstream revision")
    elif sys.argv[1] == "apply":
        revision = sys.argv[2]
        new = overlay(source(revision))
        Path(TARGET).write_bytes(new)
        print(f"Applied NARC guard to upstream {revision}")
    else:
        raise SystemExit("Unknown command")


if __name__ == "__main__":
    main()
