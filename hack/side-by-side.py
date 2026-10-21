#!/usr/bin/env python3
"""Render a side-by-side HTML diff of this fork against its upstream.

For reviewing what a fork actually changes, rather than reading a patch. Each
modified file gets an upstream-versus-ours table with a few lines of context;
files that are new are listed as such, since diffing them against nothing is
not worth a table.

Uses only the standard library, so there is nothing to install.

    hack/side-by-side.py                       # collection-scripts, vs upstream/main
    hack/side-by-side.py --ref upstream/release-4.18
    hack/side-by-side.py --path . --out /tmp/review
"""

from __future__ import annotations

import argparse
import difflib
import html
import os
import pathlib
import subprocess
import sys


def git(*args):
    return subprocess.run(["git", *args], check=True, text=True,
                          capture_output=True).stdout


def show(ref, path):
    """File contents at a ref, or None when it does not exist there."""
    try:
        return subprocess.run(["git", "show", f"{ref}:{path}"], check=True,
                              text=True, capture_output=True).stdout
    except subprocess.CalledProcessError:
        return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ref", default="upstream/main",
                    help="what to compare against (default upstream/main)")
    ap.add_argument("--path", default="collection-scripts",
                    help="limit to this path (default collection-scripts)")
    ap.add_argument("--out", default="side-by-side",
                    help="output directory (default ./side-by-side)")
    ap.add_argument("--context", type=int, default=6,
                    help="lines of context, 0 for the whole file")
    args = ap.parse_args(argv)

    root = pathlib.Path(git("rev-parse", "--show-toplevel").strip())
    os.chdir(root)
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    changed = git("diff", "--name-only", f"{args.ref}...HEAD",
                  "--", args.path).split()
    if not changed:
        print(f"no differences under {args.path} against {args.ref}")
        return 0

    differ = difflib.HtmlDiff(wrapcolumn=92)
    rows, modified, added = [], 0, 0

    for path in changed:
        before = show(args.ref, path)
        after = show("HEAD", path)
        name = path.replace("/", "_")

        if before is None:
            added += 1
            rows.append(
                f'<tr><td><code>{html.escape(path)}</code></td>'
                f'<td class="new">new file</td>'
                f'<td>{len((after or "").splitlines())} lines</td>'
                f'<td><a href="{name}.new.txt">view</a></td></tr>')
            (out / f"{name}.new.txt").write_text(after or "")
            continue

        modified += 1
        table = differ.make_file(
            before.splitlines(), (after or "").splitlines(),
            fromdesc=f"{args.ref}:{path}", todesc=f"this fork:{path}",
            context=args.context > 0, numlines=args.context or 5)
        (out / f"{name}.html").write_text(table)

        b, a = before.splitlines(), (after or "").splitlines()
        plus = sum(1 for line in difflib.unified_diff(b, a, n=0)
                   if line.startswith("+") and not line.startswith("+++"))
        minus = sum(1 for line in difflib.unified_diff(b, a, n=0)
                    if line.startswith("-") and not line.startswith("---"))
        rows.append(
            f'<tr><td><code>{html.escape(path)}</code></td>'
            f'<td>modified</td>'
            f'<td><span class="p">+{plus}</span> '
            f'<span class="m">-{minus}</span></td>'
            f'<td><a href="{name}.html">side by side</a></td></tr>')

    index = f"""<!doctype html>
<meta charset="utf-8">
<title>{html.escape(root.name)} vs {html.escape(args.ref)}</title>
<style>
 body {{ font: 14px/1.5 system-ui, sans-serif; margin: 2rem auto; max-width: 54rem; }}
 table {{ border-collapse: collapse; width: 100%; }}
 td, th {{ border-bottom: 1px solid #ddd; padding: .4rem .6rem; text-align: left; }}
 code {{ font: 13px ui-monospace, monospace; }}
 .p {{ color: #0a0; }} .m {{ color: #a00; }} .new {{ color: #06c; }}
 .meta {{ color: #666; }}
</style>
<h1>{html.escape(root.name)}</h1>
<p class="meta">{modified} modified, {added} new, under
<code>{html.escape(args.path)}</code>, against <code>{html.escape(args.ref)}</code>
({git("rev-parse", "--short=12", args.ref).strip()}).</p>
<table>
<tr><th>file</th><th></th><th></th><th></th></tr>
{chr(10).join(rows)}
</table>
"""
    (out / "index.html").write_text(index)
    print(f"{modified} modified, {added} new -> {out / 'index.html'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
