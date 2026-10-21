# Materials reference

Parameters, defaults, ranges, texture slots, tangent frames and faults of the built-in material families. See
[Materials](materials.md) for usage and [Custom shaders](custom_shaders.md) for `material::custom`.

All types live in `c3d::material` unless noted. Ranges in the tables are contracts: a constructor rejects a value
outside its range as a programming error (`@require`), not a fault. Direct edits to an asset record skip the
constructor, so they must keep the same ranges.

## Constructors and defaults

| Constructor | Parameters | Default constants |
| --- | --- | --- |
| `material::basic(params, common)` | `BasicParams` | `BASIC_PARAMS_DEFAULT`, `MATERIAL_COMMON_DEFAULT` |
| `material::standard(params, common)` | `StandardParams` | `STANDARD_PARAMS_DEFAULT`, `MATERIAL_COMMON_DEFAULT` |
| `material::toon(params, common)` | `ToonParams` | `TOON_PARAMS_DEFAULT`, `MATERIAL_COMMON_DEFAULT` |
| `material::physical(params, common)` | `PhysicalParams` | `PHYSICAL_PARAMS_DEFAULT`, `MATERIAL_COMMON_DEFAULT` |
| `material::custom(shader, param_block, slots, references, common)` | `CustomParams` | `CUSTOM_SLOTS_DEFAULT`, `MATERIAL_COMMON_DEFAULT` |

A zero-initialized params struct keeps literal zeros, including a zero UV scale. Start from the named default constant
instead.

## MaterialCommon

| Field | Default | Meaning |
| --- | --- | --- |
| `alpha_mode` | `OPAQUE` | `OPAQUE`, `MASK` or `BLEND` |
| `blend_mode` | `PREMULTIPLIED_ALPHA` | `PREMULTIPLIED_ALPHA` or `ADDITIVE`; ignored unless `alpha_mode` is `BLEND` |
| `alpha_cutoff` | 0.5 | `MASK` discards coverage below this value |
| `double_sided` | false | Draw back faces; Standard, Physical and Toon flip the shading normal on them |
| `depth_write` | true | Authored depth write; `BLEND` draws never write depth whatever this says |
| `depth_test` | true | Test against the depth buffer |
| `wireframe` | false | Draw lines; falls back to filled triangles on a device without line polygon mode |

Base factor alpha and sampled base-texture alpha are straight-alpha inputs.

| `alpha_mode` | Output |
| --- | --- |
| `OPAQUE` | Ignores coverage; writes alpha 1 |
| `MASK` | Discards below `alpha_cutoff`; writes alpha 1 for survivors |
| `BLEND` | Clamps coverage to [0, 1], multiplies the shaded RGB by it once, writes premultiplied RGBA |

For straight source RGB `C`, coverage `a` and destination `(D, A)`:

| `blend_mode` | Output RGB | Output alpha |
| --- | --- | --- |
| `PREMULTIPLIED_ALPHA` | `C*a + D*(1-a)` | `a + A*(1-a)` |
| `ADDITIVE` | `C*a + D` | `A` |

## Basic

| `BasicParams` field | Default | Meaning |
| --- | --- | --- |
| `color` | white RGBA | Unlit color multiplied by the map |
| `map` | absent, identity transform | Optional base color map |

## Standard

| `StandardParams` field | Default | Range |
| --- | --- | --- |
| `base_color` | white RGBA | [0, 1] per channel |
| `metallic` | 1 | [0, 1] |
| `roughness` | 1 | [0, 1]; shading floors the perceptual roughness at 0.045 and keeps the authored value |
| `emissive` | black RGB | Finite, at least 0; values above 1 keep HDR emission |
| `emissive_strength` | 1 | Finite, at least 0 |
| `normal_scale` | 1 | Finite; may be negative; 0 disables normal perturbation |
| `occlusion_strength` | 1 | [0, 1]; 0 removes the occlusion effect |
| `base_color_map`, `metallic_roughness_map`, `normal_map`, `occlusion_map`, `emissive_map` | absent, identity transform | See below |

| Slot | Channels | Load color space | Effect |
| --- | --- | --- | --- |
| `base_color_map` | RGBA | sRGB RGB, linear alpha | Multiplies base RGBA |
| `metallic_roughness_map` | G roughness, B metallic | Linear | Multiplies the two factors; R and A are ignored |
| `normal_map` | RGB tangent-space XYZ, or explicit RG XY | Linear | Decodes the asset semantic, reconstructs positive Z for RG, scales XY, then normalizes |
| `occlusion_map` | R | Linear | Multiplies constant and environment diffuse by `mix(1, R, occlusion_strength)` |
| `emissive_map` | RGB | sRGB | Multiplies emissive RGB and strength |

Scene ambient adds `ambient_color * ambient_intensity * base_color.rgb * (1 - metallic)`, using mapped base and metallic
values and the occlusion multiplier when present. It adds no specular term. A selected lighting environment replaces it
unless `scene.ambient_add` is true ([Environments](environments.md), [Lights](lights.md)). Occlusion never changes
direct lighting or emission. A black emissive factor keeps emission black even with a populated map.

## Toon

| `ToonParams` field | Default | Range |
| --- | --- | --- |
| `color` | white RGBA | [0, 1] per channel |
| `map` | absent, identity transform | Base color map |
| `steps` | 4 | At least 2 |
| `gradient_map` | none | `TextureId`; see below |
| `rim_color` | white RGB | Finite, at least 0 |
| `rim_strength` | 0 | Finite, at least 0; 0 leaves the surface unchanged |
| `rim_power` | 2 | Finite, above 0 |
| `outline_width` | 0 | Finite, at least 0; pixels of the view's image; 0 draws no outline |
| `outline_color` | black RGB, linear | Finite, at least 0 |
| `outline_depth_offset` | 0 | Finite, at least 0; view-space units |

Toon quantizes the clamped normal-light cosine separately for each directional, point or spot light, then adds the
contributions. Light color, intensity, range and cone attenuation and shadow visibility stay smooth. Scene ambient and
the environment's SH diffuse fill stay smooth. Toon has no specular environment reflection and no normal-map slot.

`gradient_map` replaces uniform steps with a 2D, single-layer intensity ramp. The renderer samples red only, at
`(NdotL, 0.5)`, from mip zero with a fixed nearest, clamp sampler. Green, blue and alpha are ignored. Load ramp data as
linear. A zero, missing or stale id falls back to uniform steps. A live cube, array, 3D or `R16_UINT` source returns
`c3d::UNSUPPORTED`.

The rim adds `rim_color * rim_strength * (1 - NdotV)^rim_power` after diffuse and indirect lighting. It ignores the base
texture color, lights and shadows. Final blend alpha scales it with the rest of the shaded result.

## Physical

`PhysicalParams` embeds a `StandardParams` in `standard`. With every layer disabled, Physical shades like its embedded
Standard surface.

| Field | Default | Range |
| --- | --- | --- |
| `standard` | `STANDARD_PARAMS_DEFAULT` | As Standard |
| `clearcoat`, `clearcoat_roughness` | 0 | [0, 1] |
| `clearcoat_normal_scale` | 1 | Finite; may be negative |
| `sheen_color` | black RGB | [0, 1] per channel |
| `sheen_roughness` | 0 | [0, 1] |
| `ior` | 1.5 | Finite, at least 1 |
| `specular` | 1 | [0, 1] |
| `specular_color` | white RGB | Finite, at least 0 |
| `anisotropy` | 0 | [0, 1] |
| `anisotropy_rotation` | 0 | Finite angle in radians, from the tangent toward the bitangent |
| `transmission` | 0 | [0, 1] |
| `thickness` | 0 | Finite, at least 0; object-space distance scaled by the model matrix columns; 0 is a thin surface |
| `attenuation_distance` | 0 | Finite, at least 0; 0 disables volume attenuation |
| `attenuation_color` | white RGB | [0, 1] per channel |

| Slot | Channels | Load color space | Effect |
| --- | --- | --- | --- |
| `clearcoat_map` | R | Linear | Multiplies `clearcoat` |
| `clearcoat_roughness_map` | G | Linear | Multiplies `clearcoat_roughness` |
| `clearcoat_normal_map` | RGB XYZ or explicit RG XY | Linear | Independently scaled coat normal, decoded by its texture semantic |
| `sheen_color_map` | RGB | sRGB | Multiplies `sheen_color` after sRGB decoding |
| `sheen_roughness_map` | A | Linear alpha | Multiplies `sheen_roughness` |
| `specular_map` | A | Linear alpha | Multiplies `specular` |
| `specular_color_map` | RGB | sRGB | Multiplies `specular_color` after sRGB decoding |
| `anisotropy_map` | RG direction, B strength | Linear | Direction `rg * 2 - 1`, rotated by `anisotropy_rotation`; B multiplies `anisotropy` |
| `transmission_map` | R | Linear | Multiplies `transmission` |
| `thickness_map` | G | Linear | Multiplies `thickness` |

Every slot keeps its own sampler, UV set and transform. The sheen color and roughness slots can share one sRGB texture
because its alpha stays linear. A missing or stale layer texture keeps factor-only behavior. A map is ignored while its
factor is zero: clearcoat maps at `clearcoat` 0, sheen maps when every `sheen_color` component is 0, specular maps at
`specular` 0, the anisotropy map at `anisotropy` 0, and transmission and thickness maps at `transmission` 0.

### Composition rules

- **Clearcoat.** Direct clearcoat uses a fixed dielectric F0 of 0.04 and attenuates the underlying Standard and sheen
  response with its view Fresnel. The `clearcoat_normal_map` creates a separate tangent-space normal and falls back to
  the geometry normal when absent. It never inherits the mapped base normal. The Standard `normal_map` orients the base
  and sheen response.
- **Sheen.** Sheen uses a Charlie lobe with directional-albedo attenuation and does not attenuate emission. Clearcoat
  attenuates emission and the underlying ambient by the view-dependent layer weight it uses for reflected lighting.
- **Environment.** Standard and clearcoat use the GGX-filtered cube. Sheen uses a separately Charlie-filtered cube.
  Constant ambient has no reflected layer lobes. Material occlusion affects only the underlying diffuse ambient and
  environment terms. Clearcoat, sheen and the transmission fallback read the same
  [reflection probes](reflection_probes.md) as the base layer, and ray-traced reflection hits shade the same lobes
  ([Reflections](reflections.md#what-traces)).
- **Alpha.** The renderer sums all active lobes before applying the alpha mode once. `BLEND` stays premultiplied
  source-over, and `MASK` coverage comes only from the embedded Standard base alpha.
- **Specular and IOR.** Normal-incidence reflectance is `((ior - 1) / (ior + 1))^2 * specular_color`, clamped per
  channel to 1, then multiplied by `specular`. Grazing reflectance is `specular`. Metallic surfaces still reflect their
  base color. The defaults reproduce the Standard reflectance of 0.04. Zero `specular` removes the dielectric specular
  lobe under direct and environment lighting and leaves the diffuse lobe unweighted. Clearcoat keeps its own fixed
  reflectance.
- **Anisotropy.** The direction lives in the frame the normal map uses (see [Tangent frames](#tangent-frames)). A
  degenerate frame renders isotropic. Direct lighting uses the anisotropic GGX distribution and visibility. Environment
  reflections bend the reflection normal toward the stretch direction, which is an approximation. Clearcoat and sheen
  stay isotropic. Zero strength reproduces the isotropic lobe exactly.
- **Transmission.** With `attenuation_distance` above 0, radiance crossing the volume is multiplied by
  `attenuation_color ^ (distance / attenuation_distance)`. See [Transparency](transparency.md#physical-transmission) for
  how the renderer samples the scene.

## Texture slots

| Type | Fields |
| --- | --- |
| `TextureSlot` | `texture` (`TextureRef`), `sampler` (`SamplerId`), `uv_set`, `transform` (`UvTransform`) |
| `TextureRef` | `kind`: `ASSET` (`asset`: `TextureId`), `RENDER_TARGET` (`target`: `RenderTargetId`) or `VIEW` (`view_slot`) |
| `UvTransform` | `offset`, `scale`, `rotation`; scales, then rotates about the origin, then translates |

`material::texture_slot(texture, sampler, uv_set, transform)` builds an asset slot with identity coordinates by default.
`material::view_texture_slot(view_slot, ...)` builds a view-provided slot for custom materials
([Custom shaders](custom_shaders.md#view-provided-slots)). `UV_TRANSFORM_IDENTITY` is the identity transform.

- A zero or stale texture id makes the slot absent: color, metallic-roughness, occlusion and emissive maps keep their
  scalar behavior, and an absent normal map keeps the geometry normal.
- A zero or stale sampler id selects the linear repeat sampler.
- A dead render target reads as absent. A resized target repacks the material on its own.
- `uv_set` is 0 or 1. The color space of a map belongs to the texture asset, not the slot ([Textures](textures.md)).
- Normal encoding follows the texture asset's `TextureDesc.semantic`: `COLOR` and `NORMAL_RGB` use RGB, `NORMAL_RG`
  reconstructs positive Z from RG. Render-target normal maps always use RGB. `TextureSlot` has no encoding override.
- Built-in slots cannot hold a `VIEW` reference.

## Tangent frames

A supplied tangent stream is authoritative. Tangent XYZ follows the model's linear transform and the normal follows its
inverse transpose. The mapping path keeps their interpolated basis before normalizing the mapped result. Tangent W
supplies the bitangent handedness; authored signs are normalized to +1 or -1 at publication. A reflected model transform
reverses the handedness. Reflected model and camera transforms keep front-face classification, and double-sided shading
flips the final normal on back faces.

Without a tangent stream, filled triangles derive a frame from world-position and transformed normal-map UV derivatives.
Mirrored or rotated lookup coordinates change the derived frame. A supplied frame keeps its authored basis: changing the
lookup UV set or transform does not rotate or rebuild it. A zero or degenerate supplied tangent, and degenerate position
or UV derivatives, keep the geometry normal. A decoded zero-length map normal uses neutral tangent-space `(0, 0, 1)`.

| Function | Purpose |
| --- | --- |
| `geometry::create_tangent_geometry(allocator, source, uv_set)` | Generates MikkTSpace tangents from raw UV0 or UV1 and returns a complete geometry the allocator owns |
| `AssetStore.add_geometry_owned` | Transfers the generated geometry into the store |
| `AssetStore.regenerate_geometry_tangents(geometry, uv_set)` | Regenerates the tangents of a stored geometry |
| `Geometry.transform` | Updates tangent handedness when baking a reflection; call `flip_winding` separately to reverse winding |

- Conflicting corner tangents split vertices and remap every vertex stream, including skin influences and morph deltas.
  Lookup transforms do not affect generation.
- The renderer never generates tangents implicitly. Changing a slot's UV set or editing geometry does not regenerate
  them.
- The MikkTSpace compatibility claim covers generated constant-sign triangles. The derivative fallback, mixed-sign
  authored interpolation and morphed base tangents have no such guarantee.
- Normal mip generation decodes, averages and normalizes vectors before encoding them again.
- An active normal map or active anisotropy without supplied tangents needs filled triangles. Lines, points and
  effective wireframe triangles return `c3d::UNSUPPORTED` during preparation or rendering. Supplied tangents, a missing
  map, or normal scale zero keep those geometry paths working.

## Faults

| Fault | Raised by |
| --- | --- |
| `c3d::CAPACITY_EXCEEDED` | `AssetStore.add_material` when the material pool is full |
| `c3d::INVALID_ARGUMENT` | `add_material` for a duplicate key; preparation for a `uv_set` above 1 or a comparison sampler in any slot |
| `c3d::UNSUPPORTED` | Preparation or rendering for a live cube texture or an `R16_UINT` texture in a built-in slot, an unusable Toon gradient source, or an active normal map or anisotropy that needs tangents on non-triangle or wireframe geometry |

`AssetStore.replace_material` and `mark_material_dirty` return no fault. A pairing fault from the cases above can still
appear at draw time, as with `add_material`, because a material cannot see which geometries draw it.

## Capacity and storage

The asset store holds at most `AssetStoreDesc.max_materials` materials (default 4096). `add_material` faults
`CAPACITY_EXCEEDED` past that. The renderer allocates a device heap of one `render::MATERIAL_STRIDE`-byte block for each
possible material when it is created, so the heap size follows that capacity. Applications edit asset material slots and
let the renderer resolve the bindings. The generated twins in `c3d::shader` (`StandardMaterialGpu`,
`PhysicalMaterialGpu`, `ToonMaterialGpu`, `BasicMaterialGpu`, `CustomMaterialGpu`) define the shader-visible layout, and
`abi/c3d.abi` is the source of truth ([Architecture](architecture.md)).
