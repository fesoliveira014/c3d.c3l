# Decals

A `Decal` component projects a Standard material onto the surfaces inside a box: paint, stains, bullet holes, road
markings. The projection blends base color, normal, roughness and metallic into the receiver's material before lighting.
Decals are scene components in `c3d::scene`; the renderer applies them on the forward and deferred paths.

## Quick start

```c3
DecalDesc desc = scene::default_decal_desc(material_id);
desc.size = { 2, 1, 0.5f };
desc.decal.weights = { .base_color = 1 };
Node* decal_node = scene.add_decal(desc, name: "paint")!;
decal_node.local.position = { 0, 0, 1 };
scene.update_world();
```

`material_id` names a live Standard material. The decal projects along its local Z axis onto surfaces whose geometric
normal faces local +Z, within the fade angle ([Volume and projection](#volume-and-projection)).

## Concepts

- **Receivers.** Opaque and masked Standard and Physical meshes receive decals. Basic, Toon, alpha-blended and impostor
  receivers do not. Traced-hit shading in reflections, global illumination and path tracing does not apply decals.
  [Terrain](terrain.md#decals) receives decals on both paths. Other custom shaders opt in explicitly.
- **Source material.** The decal borrows a Standard material from the asset store. The scene owns the component, not its
  material or textures.
- **Blending.** Each channel weight times the source base alpha times the angular opacity blends the projected value
  over the receiver's.
- **Order.** Overlaps apply in ascending `(order, entity.index, entity.generation)`, so later entries blend over earlier
  ones.

## Create a decal

`scene::default_decal_desc(material)` returns a unit-size description with full channel weights, every receiver layer,
order zero and `DEFAULT_DECAL_FADE_ANGLE` (80 degrees, stored in radians).

`Scene.add_decal(desc, parent, name)` copies `desc.size` to the new node's local scale and adds the component.
`Scene.add(node, decal)` attaches a component to an existing node. Direct component edits must keep the same weight and
angle ranges.

| Field | Meaning | Constraint |
| --- | --- | --- |
| `DecalDesc.size` | Box size, copied to the node's local scale | Finite and positive on each axis |
| `Decal.material` | Standard source material | Live `STANDARD` material at draw time |
| `Decal.weights` | `DecalWeights`: `base_color`, `normal`, `roughness`, `metallic` | Finite, in [0, 1] |
| `Decal.fade_angle` | Angle from the projection axis beyond which the decal fades out, in radians | Finite, in [0, PI/2] |
| `Decal.receiver_layers` | Receiver-node layers the decal affects; zero disables it | Bit mask |
| `Decal.order` | Blend order among overlapping decals | Any `int` |

`add_decal` faults `INVALID_ARGUMENT` for an invalid description and `CAPACITY_EXCEEDED` when the scene has no node
capacity. Neither fault adds a node or component.

| `DecalWeights` field | Blended receiver value |
| --- | --- |
| `base_color` | Base RGB |
| `normal` | Shading normal |
| `roughness` | Roughness |
| `metallic` | Metallic |

Receiver alpha, emissive, occlusion and the geometric `offset_normal` stay unchanged. Decals do not change alpha masking
or shadow coverage. Physical extension parameters, including clearcoat and sheen, stay unchanged.

## Volume and projection

The volume is the node's unit cube, from -0.5 to +0.5 on each axis, mapped by the node's world transform. Finite affine
transforms work, including non-uniform scale, inherited shear and reflection. A collapsed volume draws nothing and takes
no decal slot. The renderer also skips a non-finite determinant or inverse. Non-finite world transforms are unsupported
input.

Call `scene.update_world()` after moving or scaling the node. Decals follow their hierarchy's visibility. Node `layers`
select cameras, and `Decal.receiver_layers` independently selects receiver-node layers.

The projected UV is `(local.x + 0.5, 0.5 - local.y)`. Each projected map applies its own UV transform and sampler to
that projection. The UV0/UV1 selection of a slot does not select a receiver UV stream. The source base factor and map
provide RGB and opacity. The metallic-roughness map supplies G roughness and B metallic.

### Angular fade

The fade compares the receiver's geometric normal with the normalized world image of local +Z, including under shear.
With `c = cos(fade_angle)`, the cosine band is `min(DECAL_FADE_BAND, 1 - c)`, where `DECAL_FADE_BAND` is 0.1. A nonzero
band gives `clamp((facing - c) / band, 0, 1)`: zero at the cutoff, full weight at facing 1. When the band is zero,
including at an angle of zero, the rule is `facing >= 1 ? 1 : 0`. That hard limit needs exact alignment. Useful narrow
fades start around one degree.

### Normal maps

Normal maps follow the [material convention](materials_reference.md#tangent-frames): +X follows increasing U and +Y
increasing V, which is local -Y for this projection. The packed tangent follows world local +X with handedness
`-sign(determinant)`, so reflections reverse it. The decal frame orthogonalizes against the receiver's shading normal
after the receiver's own normal map, so a flat decal normal map keeps the receiver's normal-map detail even at full
normal weight. Under shear, U follows the projected tangent and V is the orthogonal approximation. RGB XYZ decoding,
normal scale and degenerate-frame behavior match mesh normal maps. Scale zero disables the perturbation.

## Budget and ownership

- Each view keeps at most `MAX_DECALS` (256) eligible decals after culling and ordering. The budget keeps the
  lowest-order entries and drops higher-order overlays first. `Stats.decals_dropped` counts the drops.
- `add_decal` does not validate the material. Preparation and rendering skip dead or non-Standard source materials and
  count them in `Stats.dangling_refs`. Keep shared assets alive while a decal uses them.
- Edit a source material through its asset record and call `assets.mark_material_dirty(material_id)`
  ([Materials](materials.md#edit-a-shared-material)). Direct decal edits need no dirty call.
- `Renderer.prepare_scene` resolves decal materials, and view extraction resolves their current revisions before
  packing.

## Decals in custom shaders

A custom receiver includes the public `decals.glsl` and calls `apply_decals` before lighting or writing its G-buffer.
Supply:

- a fully initialized `StandardMaterialSample`;
- the receiver's material flags and `DrawRoot.layers`;
- the frame-relative position and the matching view depth.

Compute position derivatives in uniform flow before any discard or divergent decal branch, then pass them to the helper.
It applies map UV transforms and the frame mip bias to those gradients.

## Limits

- Only Standard source materials.
- At most 256 decals per view.
- Traced effects do not see decals.

## See also

- [Materials](materials.md) for the Standard family and shared edits.
- [Terrain](terrain.md#decals) for decals on terrain.
- [Serialization](serialization.md) for the `c3d.Decal` codec; the material is an asset reference.
- [Custom shaders](custom_shaders_reference.md#public-includes) for `decals.glsl`.
- [Views](views.md) for per-view capacities and light selection.
