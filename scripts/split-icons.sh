#!/bin/sh
# Splits design/glyphs/icons-20.svg (one <symbol> per icon) into standalone template SVGs
# under app/Sources/ActlApp/Resources/icons, and copies the menu bar glyphs beside them.
# Re-run after editing the design sources; the outputs are committed so `swift run` works without it.
set -e
cd "$(dirname "$0")/.."
out=app/Sources/ActlApp/Resources/icons
mkdir -p "$out" app/Sources/ActlApp/Resources/glyphs
python3 - "$out" <<'PY'
import re, sys, pathlib
out = pathlib.Path(sys.argv[1])
src = pathlib.Path("design/glyphs/icons-20.svg").read_text()
head = 'fill="none" stroke="#000" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"'
n = 0
for m in re.finditer(r'<symbol id="([^"]+)">(.*?)</symbol>', src, re.S):
    name, body = m.group(1), m.group(2).strip()
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20" {head}>{body}</svg>\n'
    (out / f"{name}.svg").write_text(svg)
    n += 1
print(f"wrote {n} icons to {out}")
PY
cp design/glyphs/menubar-*.svg app/Sources/ActlApp/Resources/glyphs/
echo "copied menu bar glyphs"
