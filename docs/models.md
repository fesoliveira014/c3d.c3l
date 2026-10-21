# Models, glTF and FBX import

A model is loaded once into shared assets plus a reusable template, then instantiated any number of times without
reparsing. `c3d::asset::gltf` reads glTF 2.0 and GLB files through cgltf, `c3d::asset::fbx` reads FBX files through ufbx,
and `c3d::model::instantiate` turns a stored template into live scene nodes. The renderer sees meshes, LOD groups, cameras
and lights afterwards and needs no model-specific path. Skeletons and animation clips are shared assets that `c3d::anim`
plays onto instances ([Animation](animation.md)).

| Page | Contents |
| --- | --- |
| This page | Import, instantiate, keys, options, glTF and FBX mapping, faults. |
| [Asset loading](asset_loading.md) | Store-free decode and publish, replacing a model, the background loader. |
| [Asset store](assets.md) | Ids, keys, capacities, file sources and replacement rules. |
| [glTF source inspection](gltf_source.md) | Source metadata for tools and exporters. |

## Quick start

```c3
import c3d::asset::gltf;
import c3d::model;

ModelId model = gltf::load_model(&assets, "models/helmet.glb")!;
Node* left = model::instantiate(&assets, &scene, model, name: "left")!;
Node* right = model::instantiate(&assets, &scene, model, name: "right")!;
right.local.position = { 2, 0, 0 };
renderer.prepare_scene(&scene)!;
```

`load_model(&assets, path, options)` parses the file, converts every sampler, image, material and primitive into store
assets and stores a `ModelTemplate` under the path as its key. `load_model_memory(&assets, bytes, base_dir, key, options)`
does the same from bytes, with a caller-supplied key and a base directory for external URIs. Loading never touches a
scene: placing a model is always `model::instantiate`, and the caller sets the root transform. `fbx::load_model` is the
FBX equivalent ([FBX import](#fbx-import)).

## Concepts

### Template and instance

A `ModelTemplate` holds parent-before-child `nodes`, `meshes`, `lod_groups`, `skins`, `lights`, `cameras` and the `clips`
list, all by index and shared asset ID. It holds no payload, so releasing a geometry's CPU arrays with
`release_geometry_cpu` after the renderer uploaded it does not affect instantiation. Removing the template leaves
existing instances intact.

`model::instantiate` creates one synthetic root under the parent and one live node per template node, parents before
children. An instantiation that runs out of nodes removes the partial subtree and leaves no instance behind.

- Meshes, cameras and lights become the usual components.
- The root carries a `ModelInstance` component:

| `ModelInstance` field | Meaning |
| --- | --- |
| `source` | The `ModelId` it was created from. |
| `nodes`, `node_entities` | Borrowed pointer table and the captured entity identity of each template node. |
| `base_pose` | Authored local transforms. |
| `mesh_nodes`, `base_morph_weights` | Template indices of mesh nodes and their authored morph weights. |
| `clips` | The template's clip IDs, copied. |

- `ModelInstance.present_node(i)` resolves the original node of template index `i`, or null after its removal. The
  captured identity means a reused slot never retargets the instance, and reparenting a live node keeps its template
  membership. Indices and authored arrays keep their original extents after node removal.
- The scene owns every node and array. Removing the root removes its remaining subtree and frees the component arrays
  through the removal hook; shared assets stay in the store.
- Lifetime rules for removed nodes, missing tracks and required skin joints are in
  [Animation](animation.md#removed-instance-nodes).

A subtree serialized with `c3d_serial` keeps its model key, exact structural signature, captured template identities and
authored overrides. Restore creates the saved graph directly, preserving deleted template slots and application children.
The source model and the referenced keyed assets must be live in the destination store. A structural mismatch returns
`INCOMPATIBLE_TEMPLATE` with the model key and the first differing template index ([Serialization](serialization.md)).

### Node index contract

Template nodes are ordered depth first from the default scene's roots, or from every parentless node when the file names
no scene, with a parent always before its children. `NodeTemplate.parent` is the model-local index of the parent, or `-1`
for a template root. A source node with a mesh keeps its transform and gains one generated child per primitive, named
`<node name>/primitive/<j>`, placed before the node's authored children. Matrix nodes are decomposed into position,
rotation and scale; shear is dropped.

### Keys

Every asset an import creates is keyed under the model key, which is the file path for `load_model` and the caller's key
for `load_model_memory`.

| Asset | glTF key |
| --- | --- |
| Model template | `<key>` |
| Sampler `i` | `<key>#sampler/<i>` |
| Image `i` as sRGB color | `<key>#image/<i>/srgb` |
| Image `i` as linear data | `<key>#image/<i>/linear` |
| Image `i` as a normal map | `<key>#image/<i>/normal_rgb/<fmt>` or `<key>#image/<i>/normal_rg/<fmt>` |
| Image `i` as a masked base color | `<key>#image/<i>/mask/<fmt>/<coverage>/<hex>` |
| Material `i` | `<key>#material/<i>` |
| Default material for primitives without one | `<key>#material/default` |
| Primitive `j` of mesh `i` | `<key>#mesh/<i>/<j>` |
| Skin `i` | `<key>#skeleton/<i>` |
| Animation `i` | `<key>#anim/<i>` |

In the image keys, `<fmt>` is the ordinal of the texture's pixel format, `<coverage>` is the alpha-coverage policy
ordinal and `<hex>` is the bit pattern of the effective alpha threshold.

A key already present in the store makes the load fail with `INVALID_ARGUMENT` before anything is parsed. An image
referenced as base color, emissive, sheen color or specular color becomes an sRGB texture; every other reference becomes a
linear texture; an image used both ways becomes two textures. Images nothing references are not decoded. Normal-map roles
and color roles use distinct texture variants, and a glTF masked base texture gets a variant for its effective alpha
threshold, including the material factor. A mask that every texel passes or fails, such as a zero cutoff, shares the
unmasked texture.

## Options

`LoadOptions` selects what the importer keeps. It lives in `c3d::asset` and is shared by every model loader.
`LOAD_OPTIONS_DEFAULT` enables `animations`, `lights`, `cameras` and `generate_tangents`; `regenerate_tangents` is off and
`normal_encoding` is `RGB`.

| Field | Effect |
| --- | --- |
| `animations` | Import animations as clip assets listed by the template; skins are imported either way. |
| `lights` | Import `KHR_lights_punctual` lights as `ModelLight` entries. |
| `cameras` | Import cameras as `ModelCamera` entries. |
| `generate_tangents` | Generate a missing tangent stream for a normal-mapped triangle primitive. |
| `regenerate_tangents` | Replace authored tangents and split geometry where needed. |
| `normal_encoding` | `RGB` (default) or `RG` for imported normal textures; their generated mips filter decoded vectors. |

With `generate_tangents`, a missing tangent stream is generated from the normal map's raw UV0 or UV1 using the pinned
MikkTSpace, and lookup transforms are excluded. When the base and clearcoat normal maps use different UV sets, generated
tangents follow the base map's set and the coat is shaded with that frame; a missing UV stream keeps the derivative
fallback. Existing finite authored tangent XYZ, zero included, is preserved and its handedness is normalized to a sign.
`regenerate_tangents` can recover decoded non-finite or zero-W tangent values; a structural `TANGENT` count or type
mismatch still returns `ASSET_FORMAT_ERROR`.

## glTF mapping

### Materials

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

Every texture view becomes a `TextureSlot` carrying its texture, its sampler or the builtin linear repeat sampler, and its
UV set. Sampler filters map nearest-or-linear per stage; the mip filter follows the minification filter's mipmap half and
is linear when the source names none. Wrap modes map to the matching address modes; the W axis repeats. Every factor is
validated against the constructor domains before the material is built; a value outside them is `ASSET_FORMAT_ERROR`.
Material and sampler fidelity for tools is in [glTF source inspection](gltf_source.md#material-and-sampler-fidelity).

### Geometry

Each primitive becomes one `Geometry` asset.

- `POSITION`, `NORMAL`, `TANGENT`, `TEXCOORD_0`, `TEXCOORD_1`, `COLOR_0`, `JOINTS_0` and `WEIGHTS_0` are read. Normalized
  integer streams are expanded to floats. `COLOR_0` imports as RGBA (RGB gains alpha one) and tints the built-in shading.
- A primitive with joints but no weights, or the reverse, is `ASSET_FORMAT_ERROR`, as is one whose `POSITION` accessor is
  missing or empty.
- Point, line and triangle lists pass through; strips, fans and loops are rewritten into indexed lists. Triangle
  primitives without normals receive smooth normals.
- Morph targets keep position and normal deltas and their names; a target with only one delta kind gains a zero array for
  the other. Sparse accessors are expanded. A primitive with morph targets but no node or mesh weights starts every target
  at zero, so a weights clip on the node plays. A supplied weights count that differs from the target count is
  `ASSET_FORMAT_ERROR`. glTF geometries carry no `channels` table, so each morph weight drives the target at its index.
- A `matrix` node decomposes with its sign: a reflection lands in the x scale and zero-scale columns complete an
  orthonormal frame. Shear or non-finite values are `ASSET_FORMAT_ERROR`.
- An orthographic camera keeps both magnitudes: `ortho_height = 2 * ymag` and `aspect = xmag / ymag`.

### Skeletons and clips

Each skin becomes a `Skeleton` asset: joint names, parents as indices into the joint array (`-1` when the parent is not a
joint), the rest pose from the joints' local transforms and the inverse-bind matrices from the accessor, or identity when
the skin has none. Every primitive child of a skinned mesh node gets a `ModelSkin` entry naming the skeleton and the
template indices of the joints in skeleton order. Instantiation turns each entry into a `SkinBinding` component on the
live mesh node, with the joints mapped to live nodes. A joint outside the imported node set is `ASSET_FORMAT_ERROR`.

Each animation becomes an `AnimationClip` asset over model-local node indices. `targets` lists the distinct template nodes
the channels address in first-appearance order, and each `Track.target` indexes that list.

- Translation, rotation and scale channels become one track on the authored node. A weights channel becomes one track
  per primitive child of the node, with the mesh's morph count as the value stride.
- Interpolation maps to `STEP`, `LINEAR` or `CUBIC_SPLINE`; cubic keys keep their in-tangent, value and out-tangent triples.
  `duration` is the largest key time.
- The template lists its clip IDs and every instance copies them. Channels whose target nodes are outside the imported
  node set are omitted, including for unselected scenes and alternate subtrees skipped during optional LOD fallback. A clip
  with no imported channels has no tracks. `options.animations = false` skips clips.
- Clip events import from animation metadata ([Event import schema](animation_reference.md#event-import-schema)).

The renderer builds joint palettes from `SkinBinding` and selects the skinned and morphed vertex variants
([Animation deformation](animation_deformation.md)).

### Node-level LOD

Rigid node-level `MSFT_lod` becomes one [LodGroup](lod.md). Alternate subtrees flatten into group-relative
parts while preserving the alternate root transform in the owner's parent space. Part counts and materials may differ.
Absorbed primitive nodes remain named template nodes without duplicate `Mesh` components; unrelated cameras and lights
remain. Each instantiation owns its descriptor copy, and renderer preparation visits every level's dependencies.

- Whole-owner animation is retained. Skin or morph deformation or animation within member subtrees is unsupported:
  optional LOD falls back to the ordinary highest-detail subtree; required LOD faults `UNSUPPORTED`. Required
  material-level LOD also faults `UNSUPPORTED`.
- Bad node IDs, cycles, conflicting ownership and malformed hints fault `ASSET_FORMAT_ERROR`.
- For N levels, `extras.MSFT_screencoverage` must contain N finite numeric values. The first N-1 are positive descending
  projected-height fractions; the final nonnegative cull hint is ignored. Missing hints use the transitions
  `{0.2, 0.1, 0.05, 0.025}`. At most five levels (`MAX_LOD_LEVELS`) are supported. The projected-height reading is c3d's
  import policy.
- `ModelDocument` validates references before publication, then remaps all part geometry and material IDs atomically with
  the model.

### Extensions

Supported: `KHR_materials_clearcoat`, `KHR_materials_sheen`, `KHR_materials_transmission`, `KHR_materials_volume`,
`KHR_materials_ior`, `KHR_materials_specular`, `KHR_materials_anisotropy`, `KHR_materials_emissive_strength`,
`KHR_materials_unlit`, `KHR_texture_transform`, `KHR_lights_punctual`, `KHR_mesh_quantization` and `MSFT_lod`.

Any other extension listed in `extensionsRequired` makes the load fail with `UNSUPPORTED`, as does a primitive compressed
with Draco or meshopt and a texture whose only image comes through `KHR_texture_basisu` or `EXT_texture_webp`.
Unsupported extensions that are merely used are ignored: specular-glossiness, iridescence, diffuse transmission,
dispersion, material variants and GPU instancing import as if absent.

## FBX import

```c3
import c3d::asset::fbx;

ModelId hero = fbx::load_model(&assets, "characters/hero.fbx")!;
Node* first = model::instantiate(&assets, &scene, hero)!;
```

`fbx::load_model(assets, path, options)` converts an FBX file into the same store assets and `ModelTemplate` as glTF, and
takes the same `LoadOptions`. ufbx loads the file with right-handed Y-up axes, meters and `MODIFY_GEOMETRY` space
conversion: vertices, node translations and baked translation keys arrive in meters, authored node scales are kept and a
centimeter Mixamo file ends at scale one. Cameras and lights are converted to look along -Z.

| Asset | FBX key |
| --- | --- |
| Model template | `<path>` |
| Material part `j` of mesh `m` | `<path>#mesh/<m>/<j>` |
| Material `i` | `<path>#material/<i>` |
| Default material for parts without one | `<path>#material/default` |
| Texture `t` as sRGB color or linear data | `<path>#image/<t>/srgb`, `<path>#image/<t>/linear` (normal maps use the `normal_rgb` and `normal_rg` forms above) |
| Packed roughness `r` and metalness `m` | `<path>#image/<r>+<m>/metallic_roughness/<inverted\|direct>` |
| Base color `b` with opacity `o` | `<path>#image/<b>+<o>/srgb` |
| Sampler for mixed wrap modes | `<path>#sampler/repeat_clamp`, `<path>#sampler/clamp_repeat` |
| Skin deformer `s` | `<path>#skeleton/<s>` |
| Animation stack `k` | `<path>#anim/<k>` |

Indices are ufbx typed IDs; an absent source in a packed key is `-`. `inverted` marks a glossiness source converted to
roughness.

- **Nodes.** Template nodes are the file's nodes depth first below the root. A node with a mesh gains one child per
  non-empty material part, named `<node name>/part/<j>`, before its authored children. The child's local transform is the
  node's geometry transform, which FBX applies to the mesh and not to the node's children.
- **Geometry.** Faces are triangulated and corners with identical attributes merged. Streams: positions, normals
  (generated when absent), UV sets 0 and 1, the first color set, authored tangents when both tangents and bitangents
  exist, joints and weights. UV v is flipped, because FBX places the UV origin at the bottom left and c3d decodes images
  top row first; the authored tangent handedness follows the flip. Tangents are otherwise generated as for glTF.
- **Materials.** Every material becomes `STANDARD` from ufbx's PBR maps, which ufbx also derives for Lambert and Phong
  materials. A property connected to a texture takes its value from the texture; the base and emission factors still
  multiply. Opacity below one or an opacity texture selects blending. Base color, emissive, normal and occlusion textures
  map directly. Separate roughness and metalness textures are packed into one metallic-roughness map (roughness in green,
  metalness in blue), and an opacity texture is multiplied into a copy of the base color's alpha; sources of different
  sizes are resampled to the larger. Texture bytes come from embedded content, then the relative path next to the file,
  then the absolute path.
- **Skins.** Each skin deformer becomes a skeleton in cluster order, with the bone's local transform as rest pose and
  ufbx's geometry-to-bone matrix as inverse bind. Vertices keep their four largest weights, renormalized. When a skinned
  mesh has vertices without weights, the skeleton gains one last joint bound to the mesh part itself with an identity
  inverse bind, so those vertices follow the mesh rigidly.
- **Blend shapes.** Every blend channel becomes a `MorphChannel` and each of its keyframe shapes a `MorphTarget`, so
  in-between shapes deform as authored ([Animation deformation](animation_deformation.md#what-deforms)). Default morph
  weights are the channels' weights.
- **Animation.** Each animation stack is baked at the file frame rate from time zero into one clip: linear translation,
  rotation and scale tracks per animated node, and one morph-weight track per part child of a mesh with animated channels,
  holding every channel's weight per key.
- **Animation files.** A file that carries animation for another model, such as a Mixamo animation downloaded without
  skin, loads through `fbx::load_animations`, which rebinds each stack onto the model's template by node name
  ([Retargeting](animation_retargeting.md)).

Unsupported: texture UV transforms (`UNSUPPORTED`), UV set selection by name (textures use UV set 0), a mesh with more than
one skin deformer (`UNSUPPORTED`), dual-quaternion skinning (imported as linear), area and volume lights (skipped), NURBS,
constraints and geometry caches. A texture that has neither embedded content nor a readable file fails with
`ASSET_IO_ERROR`; any other ufbx load failure, a non-finite material value or invalid in-between weights fail with
`ASSET_FORMAT_ERROR`. A fault rolls back as for glTF.

## Faults

| Fault | Meaning |
| --- | --- |
| `ASSET_IO_ERROR` | The file, an external buffer or an external image could not be read. |
| `ASSET_FORMAT_ERROR` | The document failed to parse or validate, an image failed to decode, an accessor could not be read, a joint lies outside the imported nodes, or a numeric value lies outside the constructor domains. |
| `UNSUPPORTED` | A required extension or a compressed primitive the importer does not implement. |
| `CAPACITY_EXCEEDED` | A store pool has fewer free slots than the model needs. |
| `INVALID_ARGUMENT` | The model key or a content key is already present, an image file is empty, a skin stream has invalid influences, or a storage texture has a non-storage format. |
| `INVALID_ID` | `instantiate` received a dead model id. |
| `INCOMPATIBLE_STRUCTURE` | A replacement changes a count or layout that live components were sized against ([Asset loading](asset_loading.md#replace-a-model)). |

A loader decides every store fault before it inserts anything, so a fault leaves the store as it was.

## Run the examples

```bash
python3 scripts/build.py --example gltf_viewer
./examples/build/gltf_viewer path/to/model.glb
```

| Example | Shows |
| --- | --- |
| `gltf_viewer` | Loads a model (default: the bundled BoxTextured), instantiates it twice side by side, prints the template's counts and spins the right instance. The bundled `RiggedSimple.glb` and `AnimatedMorphCube.glb` exercise skins and morphs. `--benchmark` runs the headless scene benchmark ([Benchmarking](benchmarking.md#scene-benchmark)); `--texture-budget <MiB>` starts it under a texture budget ([Residency and memory budgets](textures.md#residency-and-memory-budgets)). |
| `streaming` | Renders a small scene while a glTF or GLB file decodes on the loader's worker ([Asset loading](asset_loading.md#background-loading)). |

The bundled sample assets are described in [examples/assets/gltf/README.md](../examples/assets/gltf/README.md).

## Limits

- glTF: Draco, meshopt, basisu and WebP images and unsupported required extensions fail the load.
- glTF `MSFT_lod`: rigid whole-owner levels only, at most five levels.
- FBX: no UV transforms, one skin deformer per mesh, linear skinning only.
- Every key must be new: re-importing a path needs `replace_model` or a removed model ([Asset loading](asset_loading.md)).
- Loading is synchronous on the calling thread; use the background loader to avoid stalls.

## See also

- [Asset store](assets.md) for ids, keys and capacities.
- [Asset loading](asset_loading.md) for decode and publish, replacement and background loading.
- [Animation](animation.md) and [Animation retargeting](animation_retargeting.md) for clips.
- [Whole-object LOD](lod.md) for `LodGroup`.
- [Textures](textures.md) and [Materials](materials.md) for the imported texture and material assets.
