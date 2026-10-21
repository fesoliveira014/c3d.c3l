# Font fixtures

Subsets of Noto Sans and Noto Sans CJK SC under the SIL Open Font License 1.1 (`OFL.txt`). Tests embed them with
`$embed` (`test/src/test_fonts.c3`, the overlay and asset replacement tests and the UI add-on tests). Nothing in the
recipe below runs during builds or tests.

| File | Source | SHA-256 |
| --- | --- | --- |
| `latin.ttf` | Noto Sans Regular 2.015, TrueType | `33e9aa57a04ec15aee5c71143ca599b7fd722815a4896b4a05b59778254b6e80` |
| `cjk.otf` | Noto Sans CJK SC Regular 2.004, CID-keyed CFF | `ab5a5b7edb783fc423e064cc7be59ecfc3dac2c0309469b657a2f12aa677daae` |
| `pair.ttc` | Noto Sans Regular and Bold 2.015, one collection | `da6076e9cff32fbe63f33103d8ea40a340f724c1c8ff8d89d9a9b9391a214258` |

- `latin.ttf` has 106 glyphs at 1000 units per em: ASCII, ten Greek and Cyrillic letters, an outlined `.notdef` and
  kerning, with quadratic outlines.
- `cjk.otf` has 8 glyphs at 1000 units per em with CFF cubic outlines: four CJK characters and two kana, plus `.notdef`
  and space.
- `pair.ttc` has 2 faces, Regular and Bold, so face selection changes the advances.

The values the tests check were read with stb_truetype v1.26 and fontTools 4.65.0.

## Recipe

Sources:

- `NotoSans-Regular.ttf`, `NotoSans-Bold.ttf`:
  `https://github.com/notofonts/notofonts.github.io/raw/main/fonts/NotoSans/unhinted/ttf/`
- `NotoSansCJKsc-Regular.otf` (16,437,364 bytes):
  `https://github.com/notofonts/noto-cjk/raw/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf`

With fontTools 4.65.0 in a scratch virtual environment, run from the repository root:

```bash
python3 -m venv /tmp/fonts && /tmp/fonts/bin/pip install fonttools && . /tmp/fonts/bin/activate
pyftsubset NotoSans-Regular.ttf --unicodes="U+0020-007E,U+0391,U+03A9,U+03B1,U+03C9,U+0411,U+0416,U+042F,U+0431,U+0436,U+044F" \
   --layout-features=kern --no-hinting --notdef-outline --output-file=test/fixtures/fonts/latin.ttf
pyftsubset NotoSansCJKsc-Regular.otf --unicodes="U+0020,U+4E2D,U+6587,U+5B57,U+6C38,U+3042,U+30A2" \
   --layout-features=kern --no-hinting --output-file=test/fixtures/fonts/cjk.otf
pyftsubset NotoSans-Regular.ttf --unicodes="U+0020-007E" --layout-features=kern --no-hinting --output-file=/tmp/regular.ttf
pyftsubset NotoSans-Bold.ttf --unicodes="U+0020-007E" --layout-features=kern --no-hinting --output-file=/tmp/bold.ttf
python -c "
from fontTools.ttLib import TTFont
from fontTools.ttLib.ttCollection import TTCollection
collection = TTCollection(); collection.fonts = [TTFont('/tmp/regular.ttf'), TTFont('/tmp/bold.ttf')]
collection.save('test/fixtures/fonts/pair.ttc')"
```
