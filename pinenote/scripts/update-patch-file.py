#!/usr/bin/env python3
"""Replace one new-file diff section inside the forward-port patch.

The forward-port patch carries the EBC driver, drm_epd_helper, DTS files,
and defconfig as *new-file* diffs.  To edit one of those files without a
full patch refresh:

    1. extract it verbatim:
         pinenote/tools/wbf/extract-from-patch.py PATCH OUTDIR PATH
    2. edit the extracted copy,
    3. splice it back:
         pinenote/scripts/update-patch-file.py PATCH EDITED_FILE PATH
    4. verify the round-trip: re-extract from the modified patch and
       diff against your edited copy - they must be identical,
    5. gate in ladder order (doc/testing.md): host tool suites, then
       `make kernel-drv`, then the cross-build.

The regenerated section keeps the patch's new-file header shape
(mode 100755, a 9-character blob id computed with `git hash-object`)
and preserves a missing trailing newline if the source has one.

Only new-file sections are supported; a file that the patch *modifies*
(context hunks) needs a real patch refresh instead.
"""
import subprocess
import sys


def main():
    if len(sys.argv) != 4:
        sys.exit(f"usage: {sys.argv[0]} PATCH EDITED_FILE TARGET_PATH\n"
                 f"  TARGET_PATH is the in-tree path, e.g. "
                 f"drivers/gpu/drm/rockchip/rockchip_ebc.c")
    patch_path, src, target = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(patch_path) as f:
        lines = f.readlines()

    start = None
    end = len(lines)
    for i, l in enumerate(lines):
        if l.startswith("diff --git ") and l.rstrip().endswith("b/" + target):
            start = i
        elif start is not None and i > start and l.startswith("diff --git "):
            end = i
            break
    if start is None:
        sys.exit(f"no diff section for {target} in {patch_path}")
    if not lines[start + 1].startswith("new file mode"):
        sys.exit(f"{target} is not a new-file diff in {patch_path}; "
                 f"this tool only replaces new-file sections")

    with open(src) as f:
        content = f.read()
    body = content.split("\n")
    missing_nl = not content.endswith("\n")
    if not missing_nl:
        body = body[:-1]

    blob = subprocess.run(["git", "hash-object", src], capture_output=True,
                          text=True, check=True).stdout.strip()

    new = [
        f"diff --git a/{target} b/{target}\n",
        "new file mode 100755\n",
        f"index 000000000..{blob[:9]}\n",
        "--- /dev/null\n",
        f"+++ b/{target}\n",
        f"@@ -0,0 +1,{len(body)} @@\n",
    ]
    new += ["+" + l + "\n" for l in body]
    if missing_nl:
        new.append("\\ No newline at end of file\n")

    lines[start:end] = new
    with open(patch_path, "w") as f:
        f.writelines(lines)
    print(f"replaced patch lines {start + 1}..{end} with {len(new)} lines "
          f"({len(body)} source lines, blob {blob[:9]})")


if __name__ == "__main__":
    main()
