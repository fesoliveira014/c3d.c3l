#!/usr/bin/env python3
"""Write the files the asset_reload example watches and applies."""
import base64, json, struct, zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent


def png(width, height, pixel):
    rows = b"".join(b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(width)) for y in range(height))

    def chunk(kind, payload):
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def checker(first, second, cells=4, size=32):
    return png(size, size, lambda x, y: first if (x * cells // size + y * cells // size) % 2 == 0 else second)


def floats(values): return struct.pack(f"<{len(values)}f", *values)
def ushorts(values): return struct.pack(f"<{len(values)}H", *values)
def data_uri(payload): return "data:application/octet-stream;base64," + base64.b64encode(payload).decode()


def dumps(value, depth=0):
    pad = " " * depth
    if isinstance(value, dict):
        items = [f'{pad} {json.dumps(key)}: {dumps(item, depth + 1)}' for key, item in value.items()]
        return "{\n" + ",\n".join(items) + f"\n{pad}}}"
    if isinstance(value, list):
        if all(not isinstance(item, (dict, list)) for item in value):
            return "[" + ", ".join(json.dumps(item) for item in value) + "]"
        return "[\n" + ",\n".join(f"{pad} {dumps(item, depth + 1)}" for item in value) + f"\n{pad}]"
    return json.dumps(value)


def quad_buffer(width, height):
    positions = floats([-width, -height, 0, width, -height, 0, width, height, 0, -width, height, 0])
    normals = floats([0, 0, 1] * 4)
    uvs = floats([0, 1, 1, 1, 1, 0, 0, 0])
    indices = ushorts([0, 1, 2, 0, 2, 3])
    return positions + normals + uvs + indices


def scene(height, colors, extra_node=False):
    width = 0.8
    buffer = quad_buffer(width, height) * 2
    half = len(buffer) // 2
    views, accessors = [], []
    for mesh in range(2):
        base = mesh * half
        for offset, length in ((0, 48), (48, 48), (96, 32), (128, 12)):
            views.append({"buffer": 0, "byteOffset": base + offset, "byteLength": length})
        first = len(views) - 4
        accessors += [
            {"bufferView": first, "componentType": 5126, "count": 4, "type": "VEC3",
             "min": [-width, -height, 0], "max": [width, height, 0]},
            {"bufferView": first + 1, "componentType": 5126, "count": 4, "type": "VEC3"},
            {"bufferView": first + 2, "componentType": 5126, "count": 4, "type": "VEC2"},
            {"bufferView": first + 3, "componentType": 5123, "count": 6, "type": "SCALAR"},
        ]
    nodes = [
        {"name": "scene", "children": [1, 2] + ([3] if extra_node else [])},
        {"name": "left", "mesh": 0, "translation": [-1, 0, 0]},
        {"name": "right", "mesh": 1, "translation": [1, 0, 0]},
    ]
    if extra_node:
        nodes.append({"name": "extra", "translation": [0, 1.5, 0]})
    return {
        "asset": {"version": "2.0"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": nodes,
        "meshes": [
            {"primitives": [{"attributes": {"POSITION": mesh * 4, "NORMAL": mesh * 4 + 1, "TEXCOORD_0": mesh * 4 + 2},
                             "indices": mesh * 4 + 3, "material": mesh}]}
            for mesh in range(2)
        ],
        "materials": [
            {"name": f"surface_{mesh}", "pbrMetallicRoughness": {
                "baseColorFactor": colors[mesh], "metallicFactor": 0.0, "roughnessFactor": 0.6,
                "baseColorTexture": {"index": 0}}}
            for mesh in range(2)
        ],
        "textures": [{"source": 0, "sampler": 0}],
        "images": [{"uri": "checker.png"}],
        "samplers": [{"magFilter": 9729, "minFilter": 9729, "wrapS": 10497, "wrapT": 10497}],
        "buffers": [{"byteLength": len(buffer), "uri": data_uri(buffer)}],
        "bufferViews": views,
        "accessors": accessors,
    }


warm = [[1.0, 0.7, 0.4, 1.0], [0.4, 0.8, 1.0, 1.0]]
cool = [[0.5, 1.0, 0.5, 1.0], [1.0, 0.5, 0.9, 1.0]]
(HERE / "checker.png").write_bytes(checker((235, 235, 235, 255), (90, 90, 110, 255)))
(HERE / "panel.png").write_bytes(checker((255, 200, 60, 255), (40, 60, 120, 255), cells=8))
(HERE / "panel_alt.png").write_bytes(checker((60, 200, 255, 255), (120, 40, 40, 255), cells=2, size=64))
(HERE / "scene.gltf").write_text(dumps(scene(0.8, warm)) + "\n")
(HERE / "scene_content.gltf").write_text(dumps(scene(1.2, cool)) + "\n")
(HERE / "scene_structural.gltf").write_text(dumps(scene(0.8, warm, extra_node=True)) + "\n")
text = (HERE / "scene.gltf").read_text()
(HERE / "scene_broken.gltf").write_text(text[: len(text) // 2])
