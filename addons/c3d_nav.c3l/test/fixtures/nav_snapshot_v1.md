# Portable navigation fixture

`nav_snapshot_v1_le.bin` and `nav_snapshot_v1_be.bin` encode the same 368-byte snapshot. They were assembled independently from explicit scalar fields with Python's standard-library `struct.pack`; the production codec did not produce them. The complete field schema is [Version 1](../../../../docs/navigation_persistence.md#version-1-wire-layout).

The files differ only in byte order of multi-byte scalar fields. The marker is `04 03 02 01` in the little-endian file and `01 02 03 04` in the big-endian file.

| Blob offset | Content |
| --- | --- |
| 0-63 | Header: version 1, one tile, total 368 bytes, grid origin (0,0,0), tile width/height 2. |
| 64-95 | Directory: X=-2, Z=3, layer=4, record offset=96, record length=272. |
| 96-223 | Tile metadata: user ID 0x12345678; one ground polygon; four ground vertices; no off-mesh or detail vertices/triangles/portals; BOUNDED; WHOLE_CELL; subdivision=1; explicit corners=1; BV disabled. Walkable height/radius/climb=(2,0.25,0.5); bounds=(0,0,0)-(2,0,2); BV factor/cell size/source cell size=(1,1,1); clearance error=0; detail origin=(0,0,0); f64 X/Z corrections=(1e-12,-2e-12). |
| 224-271 | Four f32 vertices: (0,0,0), (0,0,2), (2,0,2), (2,0,0). |
| 272-303 | Polygon: vertices (0,1,2,3,0,0), all neighbor words zero, flags=0x1234, vertex count=4, area=7, reserved zero. |
| 304-351 | The same four positions as local detail corners. |
| 352-367 | One all-zero detail range; the bounded polygon uses its coarse fan. |

Every reserved/padding byte is zero. These fields exercise signed coordinates, a nontrivial u32 ID/u16 flag mask and both f64 corrections without requiring generated native data or a big-endian host.

## BV-enabled coarse fixture

`nav_snapshot_v1_coarse_le.bin` and `nav_snapshot_v1_coarse_be.bin` independently encode the same 384-byte snapshot using explicit `struct.pack` fields. The original BOUNDED/no-BV pair above is unchanged. This pair exercises the conditional query-bound section, including the multibyte u16 values 512 and 1024.

| Blob offset | Content |
| --- | --- |
| 0-63 | Header: version 1, one tile, total 384 bytes, grid origin (2,0,0), tile width/height 2. |
| 64-95 | Directory: X=0, Z=0, layer=0, record offset=96, record length=288. |
| 96-223 | Tile metadata: user ID 0x87654321; two ground polygons; six ground vertices; no off-mesh or detail arrays; COARSE; WHOLE_CELL; subdivision=0; explicit corners=0; BV enabled. Walkable height/radius/climb=(2,0.25,0.5); bounds=(2,0,0)-(4,1,2); BV factor=512; cell size=1/512; inactive source pitch/error/detail origin/corrections are zero. |
| 224-295 | Six f32 vertices: (2,0,0), (2,0,2), (3,0,2), (3,0,0), (4,0,2), (4,0,0). |
| 296-327 | Polygon 0: vertices (0,1,2,3,0,0); neighbors (0,0,2,0,0,0); flags=0x0102; vertex count=4; area=7; reserved zero. |
| 328-359 | Polygon 1: vertices (3,2,4,5,0,0); neighbors (1,0,0,0,0,0); flags=0x0201; vertex count=4; area=11; reserved zero. |
| 360-371 | Polygon 0 query bounds: u16 minimum (0,0,0), maximum (512,0,1024). |
| 372-383 | Polygon 1 query bounds: u16 minimum (512,0,0), maximum (1024,0,1024). |

The 24-byte query-bound section already ends on an eight-byte boundary. Every other reserved/padding byte is zero. The native three-node BV tree is reconstructed; neither its internal node nor its leaf ordering appears in these bytes.
