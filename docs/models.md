# Models, glTF and FBX import

A model is loaded once into shared assets plus a reusable template, then
instantiated any number of times without reparsing. `c3d::asset::gltf` reads
glTF 2.0 and GLB files through cgltf and `c3d::asset::fbx` reads FBX files through ufbx; `c3d::model::instantiate` turns a stored
template into live scene nodes. The renderer sees ordinary meshes, cameras and
lights afterwards and needs no model-specific path. Skeletons and animation
clips are shared assets; `c3d::anim` plays clips onto instances
([Animation](animation.md)).

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
key and a base directory for external URIs. Loading never touches a scene:
placing a model is always `model::instantiate`, and the caller sets the root
transform.

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
path for `load_model` and the caller's key for `load_model_memory`:

| Asset | Key |
| --- | --- |
| Model template | `<key>` |
| Sampler `i` | `<key>#sampler/<i>` |
| Image `i` decoded as sRGB color | `<key>#image/<i>/srgb` |
| Image `i` decoded as linear data | `<key>#image/<i>/linear` |
| Material `i` | `<key>#material/<i>` |
| Default material for primitives without one | `<key>#material/default` |
| Primitive `j` of mesh `i` | `<key>#mesh/<i>/<j>` |
| Skin `i` | `<key>#skeleton/<i>` |
| Animation `i` | `<key>#anim/<i>` |

A key already present in the store makes the load fail with `INVALID_ARGUMENT`
before anything is parsed. An image referenced as base color, emissive, sheen
color or specular color becomes an sRGB texture; every other reference becomes a
linear texture; an image used both ways becomes two textures. Images nothing
references are not decoded.

## Options

`LoadOptions` selects what the importer keeps. `LOAD_OPTIONS_DEFAULT` enables
everything. Both live in `c3d::asset` and are shared by every model loader.

| Field | Effect |
| --- | --- |
| `animations` | Import animations as clip assets listed by the template; skins are imported either way. |
| `lights` | Import `KHR_lights_punctual` lights as `ModelLight` entries. |
| `cameras` | Import cameras as `ModelCamera` entries. |
| `generate_tangents` | Compute tangents for triangle primitives that have a normal map and UV0 but no `TANGENT` stream. |

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
`TEXCOORD_0`, `TEXCOORD_1`, `COLOR_0`, `JOINTS_0` and `WEIGHTS_0` are read;
normalized integer streams are expanded to floats, three-component colors gain
an alpha of one, and a primitive with joints but no weights or the reverse is
`ASSET_FORMAT_ERROR`. Point, line and triangle lists pass through; strips, fans and loops are rewritten into
indexed lists. Triangle primitives without normals receive smooth normals.
Morph targets keep position and normal deltas and their names; a target with
only one delta kind gains a zero array for the other. Sparse accessors are
expanded. A primitive whose `POSITION` accessor is missing or empty is
`ASSET_FORMAT_ERROR`.

## Skeletons and clips

Each skin becomes a `Skeleton` asset: joint names, parents as indices into the
joint array (`-1` when the parent is not a joint), the rest pose from the
joints' local transforms and the inverse-bind matrices from the accessor, or
identity when the skin has none. Every primitive child of a skinned mesh node
gets a `ModelSkin` entry naming the skeleton and the template indices of the
joints in skeleton order. Instantiation turns each entry into a `SkinBinding`
component on the live mesh node, with the joints mapped to live nodes. A joint
outside the imported node set is `ASSET_FORMAT_ERROR`.

Each animation becomes an `AnimationClip` asset over model-local node indices.
`targets` lists the distinct template nodes the channels address in first
appearance order and each `Track.target` indexes that list. Translation,
rotation and scale channels become one track on the authored node; a weights
channel becomes one track per primitive child of the node, with the mesh's
morph count as the value stride. Interpolation maps to `STEP`, `LINEAR` or
`CUBIC_SPLINE`; cubic keys keep their in-tangent, value and out-tangent
triples. `duration` is the largest key time. The template lists its clip ids
and every instance copies them. A channel on a node outside the imported node
set is `ASSET_FORMAT_ERROR`; `options.animations = false` skips clips.

`c3d::anim` samples clips onto instance nodes and morph weights; the renderer
builds joint palettes from `SkinBinding` and selects the skinned and morphed
vertex variants ([Animation](animation.md)). glTF geometries carry no
`channels` table, so each morph weight drives the target at its index.

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
| `ASSET_FORMAT_ERROR` | The document failed to parse or validate, an image failed to decode, an accessor could not be read, a joint or animation target lies outside the imported nodes, or a numeric value lies outside the constructor domains. |
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

## FBX import

```c3
ModelId hero = fbx::load_model(&assets, "characters/hero.fbx")!;
Node* first = model::instantiate(&assets, &scene, hero)!;
```

`fbx::load_model(assets, path, options)` converts an FBX file into the same
store assets and `ModelTemplate` as glTF, and takes the same `LoadOptions`.
ufbx loads the file with right-handed Y-up axes, meters and
`MODIFY_GEOMETRY` space conversion: vertices, node translations and baked
translation keys arrive in meters, authored node scales are kept, and a
centimeter Mixamo file ends at scale one. Cameras and lights are converted to
look along -Z.

| Asset | Key |
| --- | --- |
| Model template | `<path>` |
| Material part `j` of mesh `m` | `<path>#mesh/<m>/<j>` |
| Material `i` | `<path>#material/<i>` |
| Default material for parts without one | `<path>#material/default` |
| Texture `t` decoded as sRGB color or linear data | `<path>#image/<t>/srgb`, `<path>#image/<t>/linear` |
| Packed roughness `r` and metalness `m` | `<path>#image/<r>+<m>/metallic_roughness` |
| Base color `b` with opacity `o` | `<path>#image/<b>+<o>/srgb` |
| Sampler for mixed wrap modes | `<path>#sampler/repeat_clamp`, `<path>#sampler/clamp_repeat` |
| Skin deformer `s` | `<path>#skeleton/<s>` |
| Animation stack `k` | `<path>#anim/<k>` |

Indices are ufbx typed ids; an absent source in a packed key is `-`.

**Nodes.** Template nodes are the file's nodes depth first below the root. A
node with a mesh gains one child per non-empty material part, named
`<node name>/part/<j>`, before its authored children; the child's local
transform is the node's geometry transform, which FBX applies to the mesh and
not to the node's children.

**Geometry.** Faces are triangulated and corners with identical attributes
merged. Streams: positions, normals (generated when absent), UV sets 0 and 1,
the first color set, authored tangents when both tangents and bitangents
exist, joints and weights. UV v is flipped, because FBX places the UV origin
at the bottom left and c3d decodes images top row first; the authored tangent
handedness follows the flip. Tangents are otherwise generated as for glTF.

**Materials.** Every material becomes `STANDARD` from ufbx's PBR maps, which
ufbx also derives for Lambert and Phong materials. A property connected to a
texture takes its value from the texture; the base and emission factors still
multiply. Opacity below one or an opacity texture selects blending. Base
color, emissive, normal and occlusion textures map directly. Separate
roughness and metalness textures are packed into one metallic-roughness map
(roughness in green, metalness in blue), and an opacity texture is multiplied
into a copy of the base color's alpha; sources of different sizes are resampled
to the larger. Texture bytes come from embedded content, then the relative
path next to the file, then the absolute path.

**Skins.** Each skin deformer becomes a skeleton in cluster order, with the
bone's local transform as rest pose and ufbx's geometry-to-bone matrix as
inverse bind. Vertices keep their four largest weights, renormalized. When a
skinned mesh has vertices without weights, the skeleton gains one last joint
bound to the mesh part itself with an identity inverse bind, so those vertices
follow the mesh rigidly.

**Blend shapes.** Every blend channel becomes a `MorphChannel` and each of its
keyframe shapes a `MorphTarget`, so in-between shapes deform as authored
([Animation](animation.md)). Default morph weights are the channels' weights.

**Animation.** Each animation stack is baked at the file frame rate from time
zero into one clip: linear translation, rotation and scale tracks per animated
node, and one morph-weight track per part child of a mesh with animated
channels, holding every channel's weight per key.

**Animation files.** `fbx::load_animations(allocator, assets, path, model,
options)` loads a file that carries animation for another model, such as a
Mixamo animation downloaded without skin: the file is parsed and baked without
inserting anything of its own, each stack is rebound onto the model's template
nodes by name through `c3d::anim::retarget` ([Animation](animation.md)), and
the clips are stored under `<path>#anim/<k>#<model key>#<keep|strip_xz|extract>`
so one file can serve several characters and root-motion modes. The returned
ids live in the caller's allocator. A dead model id is `INVALID_ID`; an
unmatched animated node is `ASSET_FORMAT_ERROR` unless `allow_partial`.

Unsupported: texture UV transforms (`UNSUPPORTED`), UV set selection by name
(textures use UV set 0), a mesh with more than one skin deformer
(`UNSUPPORTED`), dual-quaternion skinning (imported as linear), area and
volume lights (skipped), NURBS, constraints and geometry caches. A texture
that has neither embedded content nor a readable file fails with
`ASSET_IO_ERROR`; any other ufbx load failure, a non-finite material value or
invalid in-between weights fail with `ASSET_FORMAT_ERROR`. Rollback on a fault
matches glTF.

## Example

```bash
python3 scripts/build.py --example gltf_viewer
./examples/build/gltf_viewer path/to/model.glb --gpu-timings
```

`gltf_viewer` loads the argument path, or the bundled
[BoxTextured](../examples/assets/gltf/README.md) sample, instantiates it twice
side by side under a studio environment and one directional light, and spins
the right instance. It prints the template's node, mesh, camera, light,
skeleton, skin and clip counts on load; the bundled `RiggedSimple.glb` and
`AnimatedMorphCube.glb` exercise the skin and morph paths. Drag to orbit, scroll to zoom, release Escape to quit.
The Camera panel, or `F`, switches to a free camera that starts from the orbit pose:
right-drag looks, `W A S D` move along the view, `Q`/`E` move down and up, Shift is
four times faster, and the wheel scales the speed. `--benchmark` runs the headless
scene benchmark instead; see [Benchmarking](benchmarking.md#scene-benchmark).
Imported cameras and lights are instantiated, but the example renders through
its own orbit camera.
