# Models and glTF import

A model is loaded once into shared assets plus a reusable template, then
instantiated any number of times without reparsing. `c3d::asset::gltf` reads
glTF 2.0 and GLB files through cgltf; `c3d::model::instantiate` turns a stored
template into live scene nodes. The renderer sees ordinary meshes, cameras and
lights afterwards and needs no model-specific path.

## Load once, instantiate twice

```c3
ModelId model = gltf::load_model(&assets, "models/helmet.glb")!;
Node* left = model::instantiate(&assets, &scene, model, name: "left")!;
Node* right = model::instantiate(&assets, &scene, model, name: "right")!;
right.local.position = { 2, 0, 0 };
renderer.prepare_scene(&scene)!;
```

`load_model` parses the file, converts every sampler, image, material and
primitive into store assets, and stores a `ModelTemplate` under the path as
its key. `load_model_memory` does the same from bytes, with a caller-supplied
key and a base directory for external URIs. `load` composes an import with one
instantiation and returns a `LoadResult` listing the ids and nodes it produced;
its arrays belong to the allocator the caller passes.

Instantiation creates one synthetic root under the parent and one live node per
template node, parents before children, so `ModelInstance.nodes[i]` is the live
node of template node `i`. Meshes, cameras and lights become the usual
components. The root carries a `ModelInstance` component holding the node table,
the authored local transforms and the authored morph weights of every mesh. The
scene owns every node and every array; removing the root frees them through the
component hook and leaves the shared assets untouched. Removing the model
template afterwards leaves existing instances intact.

## Keys

Every asset an import creates is keyed under the model key, which is the file
path for `load_model` and `load` and the caller's key for `load_model_memory`:

| Asset | Key |
| --- | --- |
| Model template | `<key>` |
| Sampler `i` | `<key>#sampler/<i>` |
| Image `i` decoded as sRGB color | `<key>#image/<i>/srgb` |
| Image `i` decoded as linear data | `<key>#image/<i>/linear` |
| Material `i` | `<key>#material/<i>` |
| Default material for primitives without one | `<key>#material/default` |
| Primitive `j` of mesh `i` | `<key>#mesh/<i>/<j>` |

A key already present in the store makes the load fail with `INVALID_ARGUMENT`
before anything is parsed. An image referenced as base color, emissive, sheen
color or specular color becomes an sRGB texture; every other reference becomes a
linear texture; an image used both ways becomes two textures. Images nothing
references are not decoded.

## Options

`LoadOptions` selects what the importer keeps. `LOAD_OPTIONS_DEFAULT` enables
everything with a scale of one.

| Field | Effect |
| --- | --- |
| `lights` | Import `KHR_lights_punctual` lights as `ModelLight` entries. |
| `cameras` | Import cameras as `ModelCamera` entries. |
| `generate_tangents` | Compute tangents for triangle primitives that have a normal map and UV0 but no `TANGENT` stream. |
| `scale` | Uniform scale applied to the instance root by `load` only; templates store the authored transforms. |

## Node index contract

Template nodes are ordered depth first from the default scene's roots, or from
every parentless node when the file names no scene, with a parent always before
its children. `NodeTemplate.parent` is the model-local index of the parent, or
`-1` for a template root. A source node with a mesh keeps its transform and
gains one generated child per primitive, named `<node name>/primitive/<j>`,
placed before the node's authored children. Matrix nodes are decomposed into
position, rotation and scale; shear is dropped.

## Material mapping

| glTF | c3d |
| --- | --- |
| `KHR_materials_unlit` | `material::basic` with the base color factor and texture |
| Metallic-roughness only | `material::standard` |
| Any of clearcoat, sheen, transmission, volume, IOR, specular or anisotropy | `material::physical` |
| `baseColorFactor`, `metallicFactor`, `roughnessFactor`, `emissiveFactor` | The matching Standard factors |
| `KHR_materials_emissive_strength` | `emissive_strength`; one when absent |
| `normalTexture.scale` | `normal_scale` |
| `occlusionTexture.strength` | `occlusion_strength` |
| `alphaMode`, `alphaCutoff`, `doubleSided` | `MaterialCommon` |
| `KHR_materials_clearcoat` | `clearcoat`, `clearcoat_roughness`, `clearcoat_normal_scale` and their maps |
| `KHR_materials_sheen` | `sheen_color`, `sheen_roughness` and their maps |
| `KHR_materials_ior` | `ior`; 1.5 when absent |
| `KHR_materials_specular` | `specular`, `specular_color` and their maps |
| `KHR_materials_anisotropy` | `anisotropy`, `anisotropy_rotation` and the direction map |
| `KHR_materials_transmission` | `transmission` and its map |
| `KHR_materials_volume` | `thickness`, `attenuation_color`, `attenuation_distance` and the thickness map; an absent or unbounded attenuation distance becomes zero |
| `KHR_texture_transform` | `TextureSlot.transform` offset, rotation and scale; the extension's `texCoord` overrides the view's |

Every texture view becomes a `TextureSlot` carrying its texture, its sampler or
the builtin linear repeat sampler, and its UV set. Sampler filters map
nearest-or-linear per stage; the mip filter follows the minification filter's
mipmap half and is linear when the source names none. Wrap modes map to the
matching address modes; the W axis repeats. Every factor is validated against
the constructor domains before the material is built; a value outside them is
`ASSET_FORMAT_ERROR`.

## Geometry

Each primitive becomes one `Geometry` asset. `POSITION`, `NORMAL`, `TANGENT`,
`TEXCOORD_0`, `TEXCOORD_1` and `COLOR_0` are read; normalized integer streams
are expanded to floats and three-component colors gain an alpha of one. Point,
line and triangle lists pass through; strips, fans and loops are rewritten into
indexed lists. Triangle primitives without normals receive smooth normals.
Morph targets keep position and normal deltas and their names; a target with
only one delta kind gains a zero array for the other. Sparse accessors are
expanded. A primitive whose `POSITION` accessor is missing or empty is
`ASSET_FORMAT_ERROR`.

## Supported and unsupported extensions

Supported: `KHR_materials_clearcoat`, `KHR_materials_sheen`,
`KHR_materials_transmission`, `KHR_materials_volume`, `KHR_materials_ior`,
`KHR_materials_specular`, `KHR_materials_anisotropy`,
`KHR_materials_emissive_strength`, `KHR_materials_unlit`,
`KHR_texture_transform`, `KHR_lights_punctual`, `KHR_mesh_quantization`.

Any other extension listed in `extensionsRequired` makes the load fail with
`UNSUPPORTED`, as does a primitive compressed with Draco or meshopt, and a
texture whose only image comes through `KHR_texture_basisu` or
`EXT_texture_webp`. Unsupported extensions that are merely used are ignored:
specular-glossiness, iridescence, diffuse transmission, dispersion, material
variants and GPU instancing import as if absent.

## Faults

| Fault | Meaning |
| --- | --- |
| `ASSET_IO_ERROR` | The file, an external buffer or an external image could not be read. |
| `ASSET_FORMAT_ERROR` | The document failed to parse or validate, an image failed to decode, an accessor could not be read, or a numeric value lies outside the constructor domains. |
| `UNSUPPORTED` | A required extension or a compressed primitive the importer does not implement. |
| `CAPACITY_EXCEEDED` | A store pool is full. |
| `INVALID_ARGUMENT` | The model key is already present. |
| `INVALID_ID` | `instantiate` received a dead model id. |

On any fault the loader removes every asset it inserted during that call and
frees an uninserted template; assets that existed before the call are never
touched. An instantiation that runs out of nodes removes the partial subtree
and leaves no instance behind.

## CPU release

Templates hold only ids, names and transforms. Releasing a geometry's CPU
arrays with `release_geometry_cpu` after the renderer uploaded it does not
affect instantiation, which copies nothing from the geometry.

## Example

```bash
python3 scripts/build.py --example gltf_viewer
./examples/build/gltf_viewer path/to/model.glb --gpu-timings
```

`gltf_viewer` loads the argument path, or the bundled
[BoxTextured](../examples/assets/gltf/README.md) sample, instantiates it twice
side by side under a studio environment and one directional light, and spins
the right instance. Drag to orbit, scroll to zoom, release Escape to quit.
Imported cameras and lights are instantiated, but the example renders through
its own orbit camera.
