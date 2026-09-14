#!/usr/bin/env python3
"""Write the glTF fixtures used by test_gltf.c3 and test_model.c3."""
import base64, json, struct
from pathlib import Path

HERE = Path(__file__).resolve().parent
PNG = base64.b64encode((HERE.parent / "rgba.png").read_bytes()).decode()

def data_uri(payload: bytes) -> str:
    return "data:application/octet-stream;base64," + base64.b64encode(payload).decode()

def floats(values): return struct.pack(f"<{len(values)}f", *values)
def ushorts(values): return struct.pack(f"<{len(values)}H", *values)

def write(name, document): (HERE / name).write_text(json.dumps(document, indent=1) + "\n")

# quad.gltf: one textured Standard quad, translated node, KHR_texture_transform.
positions = floats([-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0])
normals = floats([0, 0, 1] * 4)
uvs = floats([0, 1, 1, 1, 1, 0, 0, 0])
indices = ushorts([0, 1, 2, 0, 2, 3])
quad_buffer = positions + normals + uvs + indices
write("quad.gltf", {
    "asset": {"version": "2.0"},
    "extensionsUsed": ["KHR_texture_transform"],
    "scene": 0, "scenes": [{"nodes": [0]}],
    "nodes": [{"name": "quad", "mesh": 0, "translation": [1, 2, 3]}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0}]}],
    "materials": [{"name": "painted", "pbrMetallicRoughness": {
        "baseColorFactor": [0.5, 0.25, 0.125, 1.0], "metallicFactor": 0.0, "roughnessFactor": 0.5,
        "baseColorTexture": {"index": 0, "texCoord": 0, "extensions": {"KHR_texture_transform": {
            "offset": [0.5, 0.0], "rotation": 0.25, "scale": [2.0, 2.0]}}}}}],
    "textures": [{"source": 0, "sampler": 0}],
    "images": [{"uri": "data:image/png;base64," + PNG}],
    "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33071, "wrapT": 33071}],
    "buffers": [{"byteLength": len(quad_buffer), "uri": data_uri(quad_buffer)}],
    "bufferViews": [
        {"buffer": 0, "byteOffset": 0, "byteLength": 48},
        {"buffer": 0, "byteOffset": 48, "byteLength": 48},
        {"buffer": 0, "byteOffset": 96, "byteLength": 32},
        {"buffer": 0, "byteOffset": 128, "byteLength": 12}],
    "accessors": [
        {"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [-1, -1, 0], "max": [1, 1, 0]},
        {"bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"},
        {"bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"},
        {"bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"}],
})

# hierarchy.gltf: child listed before parent, matrix node, two-primitive mesh with an authored child, camera, punctual light.
tri_a = floats([0, 0, 0, 1, 0, 0, 0, 1, 0])
tri_b = floats([0, 0, 1, 1, 0, 1, 0, 1, 1])
hierarchy_buffer = tri_a + tri_b
write("hierarchy.gltf", {
    "asset": {"version": "2.0"},
    "extensionsUsed": ["KHR_materials_unlit", "KHR_materials_clearcoat", "KHR_lights_punctual"],
    "extensions": {"KHR_lights_punctual": {"lights": [
        {"type": "point", "color": [1.0, 0.5, 0.25], "intensity": 5.0, "range": 10.0}]}},
    "scene": 0, "scenes": [{"nodes": [1, 4]}],
    "nodes": [
        {"name": "child_b", "matrix": [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 1, 0, 1], "children": [2]},
        {"name": "root_a", "translation": [1, 0, 0], "children": [0, 3]},
        {"name": "cam", "camera": 0},
        {"name": "mesh_c", "mesh": 0, "children": [5]},
        {"name": "lamp", "extensions": {"KHR_lights_punctual": {"light": 0}}},
        {"name": "tag", "translation": [0, 0, 5]}],
    "meshes": [{"primitives": [
        {"attributes": {"POSITION": 0}, "material": 0},
        {"attributes": {"POSITION": 1}, "material": 1}]}],
    "materials": [
        {"name": "unlit", "pbrMetallicRoughness": {"baseColorFactor": [1.0, 0.0, 0.0, 1.0]}, "extensions": {"KHR_materials_unlit": {}}},
        {"name": "coated", "pbrMetallicRoughness": {"metallicFactor": 0.1},
         "extensions": {"KHR_materials_clearcoat": {"clearcoatFactor": 0.75, "clearcoatRoughnessFactor": 0.2}}}],
    "cameras": [{"type": "perspective", "perspective": {"yfov": 1.0, "znear": 0.1, "zfar": 100.0, "aspectRatio": 1.5}}],
    "buffers": [{"byteLength": len(hierarchy_buffer), "uri": data_uri(hierarchy_buffer)}],
    "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36}, {"buffer": 0, "byteOffset": 36, "byteLength": 36}],
    "accessors": [
        {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]},
        {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 1], "max": [1, 1, 1]}],
})

# strip.gltf: a triangle strip without normals or indices.
strip = floats([0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0])
write("strip.gltf", {
    "asset": {"version": "2.0"},
    "scene": 0, "scenes": [{"nodes": [0]}],
    "nodes": [{"mesh": 0}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "mode": 5}]}],
    "buffers": [{"byteLength": len(strip), "uri": data_uri(strip)}],
    "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 48}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]}],
})

# unsupported.gltf: a required extension the importer does not implement.
write("unsupported.gltf", {
    "asset": {"version": "2.0"},
    "extensionsRequired": ["KHR_draco_mesh_compression"],
    "extensionsUsed": ["KHR_draco_mesh_compression"],
    "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"name": "empty"}],
})
