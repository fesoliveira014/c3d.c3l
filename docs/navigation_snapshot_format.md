# Navigation snapshot format

Version 1 of the portable byte layout that `NavMesh.write_snapshot` emits and `read_snapshot` accepts. This page is for tool authors. [Baked navigation snapshots](navigation_persistence.md) covers the API, ownership and faults.

Offsets are relative to the beginning of the containing blob or record. Integers are u8, u16, u32, u64 or two's-complement i32. Floats are IEEE binary32 or binary64. All multi-byte scalar fields use the byte order selected by the marker; single bytes and magic bytes do not change. The writer always emits little endian.

Records and array sections start at relative multiples of eight. The writer zeroes every specified reserved or padding byte. The reader requires the exact packed layout and lengths: no duplicate tile keys, overlapping records, ranges inside the header or directory, extra gaps or trailing bytes. It rejects nonzero padding or reserved fields and unsupported enum or flag values.

## Header: 64 bytes

| Offset | Type | Value |
| --- | --- | --- |
| 0 | 8 bytes | ASCII `C3DNAV` followed by two zero bytes |
| 8 | u32 | `0x01020304`: bytes `04 03 02 01` for little endian, `01 02 03 04` for big endian |
| 12 | u32 | Portable version: 1 |
| 16 | u32 | Header bytes: 64 |
| 20 | u32 | Resident tile count |
| 24 | u64 | Exact total blob length |
| 32 | 3 × f32 | Grid origin X, Y, Z |
| 44 | f32 | Tile width along X |
| 48 | f32 | Tile height along Z |
| 52 | 12 bytes | Zero |

The directory begins immediately after the header. Each 32-byte entry holds X, Z and layer as three i32 values at offsets 0, 4 and 8, a zero u32 at 12, the record's absolute u64 byte offset at 16 and its u64 byte length at 24. Entries are strictly ordered by coordinate key (X, then Z, then layer). Records follow contiguously in that order.

## Tile metadata: 128 bytes

| Offset | Type | Value |
| --- | --- | --- |
| 0 | u32 | Tile user id |
| 4, 8, 12 | u32 each | Ground polygon count, ground vertex count, off-mesh connection count |
| 16, 20, 24 | u32 each | Detail vertex, triangle and portal counts |
| 28 | u32 | Detail mode: 0 `COARSE`, 1 `BOUNDED` |
| 32 | u32 | Clearance mode: 0 `WHOLE_CELL`, 1 `SUB_CELL` |
| 36 | u32 | Subdivision |
| 40 | u32 | Explicit corner state, exactly 0 or 1 |
| 44 | u32 | BV enabled, exactly 0 or 1 |
| 48, 52, 56 | f32 each | Walkable height, radius and climb |
| 60, 72 | 3 × f32 each | Bounds minimum and maximum |
| 84 | f32 | BV quantization factor |
| 88, 92, 96 | f32 each | Cell size, source cell size and clearance maximum error |
| 100 | 3 × f32 | Detail origin X, Y, Z |
| 112 | 2 × f64 | Compensated detail-origin X and Z corrections |

Grid origin and dimensions, active geometry and precision values must be finite and satisfy the runtime's domain and topology rules. Ground polygons precede off-mesh polygons. Total vertices are the ground vertices plus two per off-mesh connection, and total polygons are the ground polygons plus the off-mesh count. Counts must fit the runtime's index and range limits, whatever their wire width. At most 32 layers share one XZ coordinate.

## Arrays after the tile metadata

Each row starts after the previous row's bytes rounded up to eight; the padding is zero.

| Order | Count | Element |
| --- | --- | --- |
| 1 | Ground vertex count | X, Y, Z as three f32 values, 12 bytes |
| 2 | Ground polygon count | Ground polygon record, 32 bytes |
| 3 | Ground polygon count when `COARSE` and BV enabled; zero otherwise | Quantized query bounds: minimum X, Y, Z then maximum X, Y, Z, six u16 values, 12 bytes |
| 4 | Ground vertex count when `BOUNDED`; zero otherwise | Local detail corner X, Y, Z, 12 bytes |
| 5 | Ground polygon count when `BOUNDED`; zero otherwise | Detail range: vertex base, vertex count, triangle base, triangle count as four u32 values, 16 bytes |
| 6 | Detail vertex count | Local X, Y, Z as three f32 values, 12 bytes |
| 7 | Detail triangle count | Three u16 local vertex indices and one u16 boundary-edge mask, 8 bytes |
| 8 | Detail portal count | Detail portal record, 32 bytes |
| 9 | Off-mesh connection count | Off-mesh record, 48 bytes |

### Ground polygon record

Six u16 vertex indices at offset 0, six u16 neighbour words at 12, the current u16 flags at 24, the u8 vertex count at 26, the u8 area at 27, and four zero bytes at 28. Inactive vertex and neighbour entries are zero. Active neighbours use 0 for none, the polygon ordinal plus one for an internal neighbour, or `0x8000 | side` for a tile portal; valid sides are 0, 2, 4 and 6. Areas range from 0 through 63. Zero flags are preserved exactly.

### Quantized query bounds

Minimum X, Y, Z at offsets 0, 2 and 4 and maximum X, Y, Z at 6, 8 and 10. Each axis needs minimum ≤ maximum. Records follow ground polygon order, and their count derives from the ground polygon count and the `COARSE` and BV-enabled settings. Only the whole section is padded to eight bytes, with zeros. Native node order, internal unions and escape indices are not encoded.

### Detail portal record

Polygon and edge as u32 at 0 and 4; the accepted interval minimum and maximum and the source and target heights as f32 at 8, 12, 16 and 20; the kind as u16 at 24; the source floor as u16 at 26; and the target as u32 at 28. Kinds are 0 `HEIGHT_BORDER`, 1 `FLOOR_BORDER` and 2 `INTERNAL`. The target is the neighbour floor ordinal for `FLOOR_BORDER` and the polygon ordinal for `INTERNAL`. Bounds and reciprocal identities follow the bounded-surface contract of [navigation grids](navigation_grids.md#bounded-scene-surfaces).

### Off-mesh record

Original start X, Y, Z as f32 at 0 and end X, Y, Z at 12; the radius as f32 at 24; the user id as u32 at 28; the polygon ordinal as u32 at 32; the current polygon flags as u16 at 36; the polygon area as u8 at 38; the bidirectional flag as u8 at 39 (exactly 0 or 1); the side as u8 at 40 (0 through 7, or 255 for the same tile); and seven zero bytes at 41. Connection ordinal `i` must refer to polygon `ground_polygon_count + i`. The two runtime vertices are recreated from the original endpoints and snapped during linking.

## See also

- [Baked navigation snapshots](navigation_persistence.md).
