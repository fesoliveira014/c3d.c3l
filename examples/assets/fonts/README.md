# Example fonts

Both fonts are under the SIL Open Font License 1.1 (`OFL.txt`).

| File | Content | Bytes | SHA-256 |
| --- | --- | --- | --- |
| `NotoSans-Regular.ttf` | Noto Sans Regular 2.015, unchanged; 3,884 glyphs (Latin, Greek, Cyrillic) | 431,364 | `f3961a9cde016d41a4879aecda1474d3a36d6bf54fa0e4643de029cc2248b0e8` |
| `NotoSansCJKsc-Regular-GB2312-L1.otf` | Noto Sans CJK SC Regular 2.004, subset; 4,184 glyphs | 847,620 | `8a58dcf715213f20c26e72e85c1cf456a0ccaca02b9c0ebdf8ee22a79867a788` |

The CJK subset keeps ASCII, CJK punctuation (U+3000 to U+303F), hiragana, katakana, the fullwidth forms U+FF01 to
U+FF5E and the 3,755 hanzi of GB2312 level 1.

Sources:

- `https://github.com/notofonts/notofonts.github.io/raw/main/fonts/NotoSans/unhinted/ttf/NotoSans-Regular.ttf`
- `https://github.com/notofonts/noto-cjk/raw/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf`
  (16,437,364 bytes)

The subset was made once with fontTools 4.65.0:

```bash
/tmp/fonts/bin/python -c "
ranges = ['U+0020-007E', 'U+3000-303F', 'U+3041-3096', 'U+30A1-30FA', 'U+FF01-FF5E']
hanzi = sorted({bytes([high, low]).decode('gb2312') for high in range(0xB0, 0xD8) for low in range(0xA1, 0xFF)
                if not (high == 0xD7 and low > 0xF9)})
open('/tmp/cjk_unicodes.txt', 'w').write(','.join(ranges + ['U+%04X' % ord(c) for c in hanzi]))"
/tmp/fonts/bin/pyftsubset NotoSansCJKsc-Regular.otf --unicodes-file=/tmp/cjk_unicodes.txt \
   --layout-features=kern --no-hinting --output-file=examples/assets/fonts/NotoSansCJKsc-Regular-GB2312-L1.otf
```
