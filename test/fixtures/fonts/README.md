# Font fixtures

Subsets of Noto Sans and Noto Sans CJK SC under the SIL Open Font License 1.1 (`OFL.txt`). They are committed test
inputs; nothing below runs during builds or tests.

| File | Source | SHA-256 |
| --- | --- | --- |
| `latin.ttf` | Noto Sans Regular 2.015, TrueType | `33e9aa57a04ec15aee5c71143ca599b7fd722815a4896b4a05b59778254b6e80` |
| `cjk.otf` | Noto Sans CJK SC Regular 2.004, CID-keyed CFF | `ab5a5b7edb783fc423e064cc7be59ecfc3dac2c0309469b657a2f12aa677daae` |
| `pair.ttc` | Noto Sans Regular and Bold 2.015, one collection | `da6076e9cff32fbe63f33103d8ea40a340f724c1c8ff8d89d9a9b9391a214258` |

## Values the tests check

Checked against both stb_truetype v1.26 and fontTools 4.65.0.

| Fixture | Value |
| --- | --- |
| `latin.ttf` | 106 glyphs, 1000 units per em, hhea ascent 1069, descent -293, line gap 0 |
| | Glyph ids: `.notdef` 0 (has an outline), space 1 (empty), A 34, H 41, O 48, T 53, V 55, o 80, Ω 97, Ж 101 |
| | Advances: A 639, V 600, space 260, Ж 905, T 556, o 605, `.notdef` 600 |
| | Kerning: A V -40, V A -40, T o -70; 0 for H H and for every pair with space or `.notdef` |
| | Shapes: H 12 lines; O 20 quadratics in 2 contours; A 11 lines and 5 quadratics in 2 contours |
| `cjk.otf` | 8 glyphs, 1000 units per em; 中 4 (24 lines), 文 6 (12 cubics), あ 2 (27 cubics), ア 3 (12 cubics) |
| `pair.ttc` | 2 faces; the A advance is 639 in face 0 and 692 in face 1 (Bold) |

## Recipe

Sources:

- `NotoSans-Regular.ttf`, `NotoSans-Bold.ttf`:
  `https://github.com/notofonts/notofonts.github.io/raw/main/fonts/NotoSans/unhinted/ttf/`
- `NotoSansCJKsc-Regular.otf` (16,437,364 bytes):
  `https://github.com/notofonts/noto-cjk/raw/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf`

With fontTools 4.65.0 in a scratch virtual environment (`python3 -m venv /tmp/fonts && /tmp/fonts/bin/pip install
fonttools`):

```bash
S=/tmp/fonts/bin/pyftsubset
$S NotoSans-Regular.ttf --unicodes="U+0020-007E,U+0391,U+03A9,U+03B1,U+03C9,U+0411,U+0416,U+042F,U+0431,U+0436,U+044F" \
   --layout-features=kern --no-hinting --notdef-outline --output-file=test/fixtures/fonts/latin.ttf
$S NotoSansCJKsc-Regular.otf --unicodes="U+0020,U+4E2D,U+6587,U+5B57,U+6C38,U+3042,U+30A2" \
   --layout-features=kern --no-hinting --output-file=test/fixtures/fonts/cjk.otf
$S NotoSans-Regular.ttf --unicodes="U+0020-007E" --layout-features=kern --no-hinting --output-file=/tmp/regular.ttf
$S NotoSans-Bold.ttf --unicodes="U+0020-007E" --layout-features=kern --no-hinting --output-file=/tmp/bold.ttf
/tmp/fonts/bin/python -c "
from fontTools.ttLib import TTFont
from fontTools.ttLib.ttCollection import TTCollection
collection = TTCollection(); collection.fonts = [TTFont('/tmp/regular.ttf'), TTFont('/tmp/bold.ttf')]
collection.save('test/fixtures/fonts/pair.ttc')"
```
