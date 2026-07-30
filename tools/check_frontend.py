#!/usr/bin/env python3
"""Static consistency checks for the frontend.

Catches the classes of mistake that only show up at runtime otherwise:
  * a data-action with no handler, or a handler nothing triggers
  * getElementById on an id that is not in the HTML
  * a translation key used in markup or code but missing from a language
  * an inline script, style or on* handler sneaking back in (breaks the CSP)

Usage: python3 tools/check_frontend.py
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGES = {
    "index.html": ["assets/i18n.js", "assets/landing.js"],
    "app.html": ["assets/i18n.js", "assets/config.js", "assets/app.js"],
    "privacy.html": [],
}

problems: list[str] = []
notes: list[str] = []


def fail(msg: str) -> None:
    problems.append(msg)


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def strip_comments(js: str) -> str:
    js = re.sub(r"/\*.*?\*/", "", js, flags=re.S)
    return re.sub(r"(?m)^\s*//.*$", "", js)


# --------------------------------------------------------------- CSP hygiene
for page in PAGES:
    html = read(page)
    for pattern, label in (
        (r"\son[a-z]+\s*=", "inline event handler"),
        (r"<style[\s>]", "<style> block"),
        (r'\sstyle="', "style attribute"),
        (r"javascript:", "javascript: URL"),
    ):
        if re.search(pattern, html, flags=re.I):
            fail(f"{page}: contains {label} — breaks the strict CSP")
    for tag in re.findall(r"<script\b[^>]*>", html):
        if "src=" not in tag:
            fail(f"{page}: inline <script> — breaks the strict CSP")

# ------------------------------------------------------------- data-action
for page, scripts in PAGES.items():
    if not scripts:
        continue
    html = read(page)
    js = strip_comments("\n".join(read(s) for s in scripts))
    used = set(re.findall(r'data-action="([^"]+)"', html))

    if page == "app.html":
        block = re.search(r"var ACTIONS = \{(.*?)\n  \};", js, flags=re.S)
        if not block:
            fail("app.js: could not locate the ACTIONS table")
            defined = set()
        else:
            defined = set(re.findall(r"'([a-z-]+)':", block.group(1)))
    else:
        defined = set(re.findall(r"name === '([a-z-]+)'", js))

    for action in sorted(used - defined):
        fail(f"{page}: data-action=\"{action}\" has no handler")
    for action in sorted(defined - used):
        fail(f"{scripts[-1]}: handler '{action}' is never triggered from {page}")

# ------------------------------------------------------------- element ids
for page, scripts in PAGES.items():
    if not scripts:
        continue
    html = read(page)
    ids = set(re.findall(r'\sid="([^"]+)"', html))
    js = strip_comments("\n".join(read(s) for s in scripts))
    referenced = set(re.findall(r"\$\('([a-zA-Z0-9_-]+)'\)", js))
    referenced |= set(re.findall(r"getElementById\('([a-zA-Z0-9_-]+)'\)", js))
    for name in sorted(referenced - ids):
        fail(f"{page}: script looks up #{name}, which is not in the markup")

    for selector in re.findall(r"querySelector(?:All)?\('([^']+)'\)", js):
        for hashed in re.findall(r"#([a-zA-Z0-9_-]+)", selector):
            if hashed not in ids:
                fail(f"{page}: selector '{selector}' references missing #{hashed}")

# -------------------------------------------------------------- i18n keys
i18n = read("assets/i18n.js")
tables: dict[str, set[str]] = {}
for lang in ("en", "de", "cs"):
    block = re.search(rf"\n  {lang}: \{{(.*?)\n  \}}", i18n, flags=re.S)
    if not block:
        fail(f"i18n.js: language block '{lang}' not found")
        continue
    tables[lang] = set(re.findall(r"(?m)(?:^\s*|[{,]\s*)([a-z][a-z0-9_]*)\s*:", block.group(1)))

if len(tables) == 3:
    for lang in ("de", "cs"):
        missing = tables["en"] - tables[lang]
        if missing:
            fail(f"i18n.js: '{lang}' is missing {len(missing)} key(s): {sorted(missing)[:8]}")
        extra = tables[lang] - tables["en"]
        if extra:
            fail(f"i18n.js: '{lang}' has key(s) 'en' does not: {sorted(extra)[:8]}")

used_keys: set[str] = set()
for page in PAGES:
    html = read(page)
    used_keys |= set(re.findall(r'data-i18n(?:-placeholder)?="([^"]+)"', html))
known = tables.get("en", set())
for script in ("assets/app.js", "assets/landing.js"):
    js = read(script)
    used_keys |= set(re.findall(r"\bt\('([a-z0-9_]+)'", js))
    # keys handed around as plain string literals, e.g. friendlyAuthError(err, 'err_x')
    used_keys |= {k for k in re.findall(r"'([a-z][a-z0-9_]*)'", js) if k in known}

for key in sorted(used_keys - tables.get("en", set())):
    fail(f"translation key '{key}' is used but not defined in i18n.js")

unused = tables.get("en", set()) - used_keys
if unused:
    notes.append(f"{len(unused)} translation key(s) defined but unused: {sorted(unused)}")

# ------------------------------------------------- referenced files exist
for page in PAGES:
    html = read(page)
    # subresources only: <a href> is a navigation, not a load
    refs = re.findall(r'<(?:script|link|img)\b[^>]*?(?:src|href)="([^"]+)"', html)
    refs += re.findall(r'<a\b[^>]*?href="([^"]+)"', html)
    for ref in refs:
        if re.match(r"https?:|#|mailto:", ref):
            continue
        if not (ROOT / ref.split("?")[0].split("#")[0]).exists():
            fail(f"{page}: references missing file {ref}")

for css in ("assets/app.css", "assets/landing.css"):
    for ref in re.findall(r"url\('([^']+)'\)", read(css)):
        target = (ROOT / css).parent / ref
        if not target.exists():
            fail(f"{css}: url('{ref}') does not resolve")

fonts_css = read("assets/fonts/fonts.css")
for ref in re.findall(r"url\('\./([^']+)'\)", fonts_css):
    if not (ROOT / "assets" / "fonts" / ref).exists():
        fail(f"assets/fonts/fonts.css: missing {ref}")

# --------------------------------------------- CSP matches what is loaded
vercel = json.loads(read("vercel.json"))
csp = next(
    h["value"]
    for rule in vercel["headers"]
    for h in rule["headers"]
    if h["key"] == "Content-Security-Policy"
)
supabase_url = re.search(r"supabaseUrl: '([^']+)'", read("assets/config.js")).group(1)
if supabase_url not in csp:
    fail(f"vercel.json: connect-src does not allow {supabase_url}")
for directive in ("default-src 'none'", "script-src 'self'", "frame-ancestors 'none'",
                  "object-src 'none'", "base-uri 'none'"):
    if directive not in csp:
        fail(f"vercel.json: CSP is missing \"{directive}\"")
if "unsafe-inline" in csp or "unsafe-eval" in csp:
    fail("vercel.json: CSP still allows unsafe-inline/unsafe-eval")

for page in PAGES:
    subresources = re.findall(r'<(?:script|link|img)\b[^>]*?(?:src|href)="(https?://[^"/]+)', read(page))
    for host in subresources:
        if host not in csp:
            fail(f"{page}: loads from {host}, which the CSP does not allow")

# ------------------------------------------------------- node syntax check
for script in sorted((ROOT / "assets").glob("*.js")):
    result = subprocess.run(["node", "--check", str(script)], capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{script.name}: syntax error\n{result.stderr.strip()}")

# ------------------------------------------------------------------ report
for note in notes:
    print(f"note: {note}")
if problems:
    print()
    for p in problems:
        print(f"FAIL  {p}")
    print(f"\n{len(problems)} problem(s)")
    sys.exit(1)
print("\nfrontend checks passed")
