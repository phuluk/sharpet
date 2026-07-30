#!/usr/bin/env python3
"""Regenerate assets/fonts/ from the @fontsource npm packages.

Self-hosting the webfonts means visitors' IP addresses are never handed to
Google's font servers (a live GDPR question in the EU), and it lets the CSP in
vercel.json use `font-src 'self'` with no third-party origins at all.

Only the latin and latin-ext subsets are shipped: between them they cover
English, German and Czech, and the browser downloads only the subsets a page
actually needs thanks to the unicode-range declarations.

Usage:
    npm install @fontsource/inter @fontsource/space-grotesk @fontsource/jetbrains-mono
    python3 tools/build_fonts.py [path/to/node_modules/@fontsource]
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "assets" / "fonts"
SUBSETS = ("latin", "latin-ext")

# package -> (css font-family, weights actually used by the stylesheets)
FAMILIES = {
    "inter": ("Inter", [400, 500, 600]),
    "space-grotesk": ("Space Grotesk", [500, 600, 700]),
    "jetbrains-mono": ("JetBrains Mono", [500, 700]),
}

HEADER = """\
/* Self-hosted webfonts — GENERATED FILE, do not edit by hand.
   Regenerate with: python3 tools/build_fonts.py

   Self-hosting keeps visitor IP addresses away from Google's servers and lets
   the CSP drop fonts.googleapis.com / fonts.gstatic.com entirely. */
"""


def main() -> None:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("node_modules/@fontsource")
    if not src.is_dir():
        sys.exit(f"not found: {src}\nRun `npm install @fontsource/...` first.")

    DEST.mkdir(parents=True, exist_ok=True)
    for stale in DEST.glob("*.woff2"):
        stale.unlink()

    out = [HEADER]
    copied = 0

    for package, (family, weights) in FAMILIES.items():
        for weight in weights:
            css = (src / package / f"{weight}.css").read_text(encoding="utf-8")
            for block in re.findall(r"@font-face\s*\{[^}]*\}", css):
                match = re.search(r"url\(\./files/([^)]+\.woff2)\)", block)
                if not match:
                    continue
                filename = match.group(1)
                subset = filename.replace(f"{package}-", "").replace(f"-{weight}-normal.woff2", "")
                if subset not in SUBSETS:
                    continue
                unicode_range = re.search(r"unicode-range:\s*([^;]+);", block)
                shutil.copy(src / package / "files" / filename, DEST / filename)
                copied += 1
                out.append(
                    "@font-face{\n"
                    f"  font-family:'{family}';\n"
                    "  font-style:normal;\n"
                    "  font-display:swap;\n"
                    f"  font-weight:{weight};\n"
                    f"  src:url('./{filename}') format('woff2');\n"
                    + (f"  unicode-range:{unicode_range.group(1).strip()};\n" if unicode_range else "")
                    + "}\n"
                )

    (DEST / "fonts.css").write_text("\n".join(out), encoding="utf-8")
    print(f"wrote {copied} woff2 files and fonts.css to {DEST.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
