# Sky, fog and cloud reference

Components, validity rules, CPU functions, constants, view switches, counters and memory of the outdoor
features. The guides are [sky](sky.md), [fog and medium volumes](fog.md) and [clouds](clouds.md).

All four components live in `c3d::light`. `create_scene` registers them. `describe::register_core_components` describes
them and `serial::register_core_codecs` serializes them.

## Atmosphere

| Field | `ATMOSPHERE_EARTH` | Meaning |
| --- | --- | --- |
| `planet_radius` | 6,360,000 | Metres; world y = 0 lies on the surface |
| `atmosphere_height` | 100,000 | Metres above the surface |
| `rayleigh_scattering` | (5.802, 13.558, 33.1) × 10⁻⁶ | Per metre at the surface, per channel |
| `rayleigh_scale_height` | 8,000 | Metres |
| `mie_scattering` | 3.996 × 10⁻⁶ | Per metre at the surface |
| `mie_absorption` | 0.444 × 10⁻⁶ | Per metre at the surface |
| `mie_scale_height` | 1,200 | Metres |
| `mie_anisotropy` | 0.8 | Cornette-Shanks `g` |
| `ozone_absorption` | (0.650, 1.881, 0.085) × 10⁻⁶ | Per metre at the layer centre, per channel |
| `ozone_center_altitude` | 25,000 | Metres |
| `ozone_half_width` | 15,000 | Metres; the layer thins to zero over it (a tent profile) |
| `ground_albedo` | (0.3, 0.3, 0.3) | The lit ground seen below the horizon and bounced into the lighting |
| `sun_angular_radius` | 0.004675 | Radians |
| `observer_altitude` | 0 | Metres; the scene's lighting is the sky seen from here |

`light::atmosphere_valid` accepts an atmosphere when:

- `planet_radius`, `atmosphere_height`, `rayleigh_scale_height`, `mie_scale_height`, `ozone_half_width` and
  `sun_angular_radius` are finite and positive, and `sun_angular_radius` is below π/2;
- the Rayleigh, ozone and ground channels, `mie_scattering`, `mie_absorption` and `ozone_center_altitude` are finite and
  nonnegative, and the albedo channels are at most 1;
- `|mie_anisotropy|` is below 1;
- `observer_altitude` is finite and in [0, `atmosphere_height`).

## HeightFog

The density is referenced to the node's world y. The node's rotation and scale are ignored.

| Field | `HEIGHT_FOG_DEFAULT` | Meaning |
| --- | --- | --- |
| `density` | 0.002 | Extinction per metre at the node's world y |
| `falloff` | 0.02 | Per metre of height; the density halves every 35 m above the node; 0 is uniform fog |
| `albedo` | (1, 1, 1) | Scattered share of the extinction, per channel |
| `max_distance` | 200 | Metres of view the [volumetric fog](fog.md#volumetric-fog) covers; the analytic fog continues past it |
| `anisotropy` | 0.3 | Henyey-Greenstein `g` of the volumetric fog's sun light, in (-1, 1); 0 is isotropic, positive favours looking toward the sun |

`light::height_fog_valid` accepts a fog with finite nonnegative `density`, `falloff` and `albedo`, a finite positive
`max_distance` and `|anisotropy|` below 1.

## MediumVolume

A box of medium hanging below the node's local XZ plane. See [medium volumes](fog.md#medium-volumes).

| Field | Meaning |
| --- | --- |
| `absorption`, `scattering` | Per metre, per channel |
| `anisotropy` | Henyey-Greenstein `g` of the sun term, in (-1, 1) |
| `center` | Local x and z of the box centre, metres |
| `half_extent` | Local x and z half sizes, metres |
| `depth` | Local metres below the top face |

`light::medium_volume_valid` accepts a medium with finite nonnegative coefficients, a finite `center`, finite positive
`half_extent` and `depth`, and `|anisotropy|` below 1.

## CloudLayer

| Field | `CLOUD_LAYER_DEFAULT` | Meaning |
| --- | --- | --- |
| `bottom`, `top` | 1,500, 3,000 | Altitudes in metres above the y = 0 datum; `top` is above `bottom` |
| `density` | 0.04 | Extinction per metre where the weather is full |
| `coverage` | unset | A 2D `TextureId`: R is coverage, G the share of the layer a cloud fills; unset is full cover |
| `coverage_extent` | 20,000 | Metres one repeat of the map spans |
| `noise_scale` | 8,000 | Metres one repeat of the noise spans |
| `erosion` | 0.3 | Detail noise strength, 0 to 1 |
| `wind_offset` | 0 | Metres the clouds have drifted along each axis; the application advances it |
| `albedo` | 1 | Single-scattering albedo, 0 to 1 |
| `anisotropy` | 0.6 | Henyey-Greenstein `g` of the forward lobe; the back lobe takes −g / 2 |
| `cast_shadows` | true | The layer shadows the sun's light on the scene; a bare `CloudLayer{}` casts none |

`light::cloud_layer_valid` accepts a layer with finite fields, `top` above `bottom`, nonnegative `density`, positive
`coverage_extent` and `noise_scale`, `erosion` and `albedo` in [0, 1], and `|anisotropy|` below 1.

## CPU functions

All are pure and callable from any thread.

| Function | Result |
| --- | --- |
| `light::sun_radiance(atmosphere, sun, to_sun, altitude)` | The sun's colour times intensity times transmittance; exactly zero below the horizon |
| `light::atmosphere_transmittance(atmosphere, altitude, cos_zenith)` | Transmittance to the top of the atmosphere; zero where the direction meets the ground, one where it misses the shell |
| `light::height_fog_transmittance(fog, base_height, origin, direction, distance)` | Transmittance along a segment |
| `light::height_fog_optical_depth(fog, base_height, origin, direction, distance)` | Optical depth along a segment |
| `light::height_fog_limit_transmittance(fog, base_height, origin, direction)` | Transmittance to infinity; zero at and below the horizon unless the density is zero |
| `light::fog_rise_factor(rise)` | The share of the level integral a sloped ray keeps, `(1 - e^-rise) / rise` |

`atmosphere_transmittance` takes `ATMOSPHERE_TRANSMITTANCE_STEPS` (64) steps, accurate to about 0.35 %. `altitude` is in
metres above the surface, unbounded above and zero below zero.

## Constants

| Constant | Value | Meaning |
| --- | --- | --- |
| `render::ATMOSPHERE_CAPACITY` | 4 | Atmospheres of different scenes the renderer keeps at once |
| `render::SKY_REGENERATION_SUN_ANGLE` | 0.0087 rad (0.5°) | Sun motion that regenerates the lighting |
| `render::SKY_REGENERATION_ALTITUDE` | 500 m | `observer_altitude` change that regenerates the lighting |
| `render::SKY_ENVIRONMENT_SIZE` | 64 | Face size of the lighting cubes |
| `render::AERIAL_PERSPECTIVE_DISTANCE` | 128,000 m | Distance the aerial perspective volume covers |
| `shader::MAX_VIEW_MEDIA` | 4 | Medium volumes a view keeps |
| `shader::FOG_VOLUME_MAX_SLICES` | 128 | Most slices a fog volume holds |
| `shader::FOG_HISTORY_WEIGHT` | 0.9 | Share of the previous frame the temporal fog volume keeps |
| `shader::CLOUD_STEPS` | 64 | Samples along a half-resolution cloud ray |
| `shader::CLOUD_LIGHT_STEPS` | 6 | Samples toward the sun per cloud sample |
| `shader::CLOUD_NOISE_SIZE` | 128 | Edge of the shared cloud noise volume |
| `shader::CLOUD_SHADOW_SIZE` | 512 | Texels per side of the cloud shadow map |
| `shader::CLOUD_SHADOW_EXTENT` | 16,384 m | Reach of the cloud shadow map |
| `shader::CLOUD_SHADOW_STEPS` | 16 | Samples through the deck per shadow texel |
| `shader::CLOUD_SHADOW_EDGE_BAND` | 0.1 | Share of the map's half extent that fades to light |
| `shader::CLOUD_SUN_FLOOR` | 0.1 | Lowest sun cosine a cloud march or shadow projection divides by |
| `shader::CLOUD_HISTORY_WEIGHT` | 0.9 | Share of the previous frame the temporal cloud march keeps |

## View switches

| Field | Effect |
| --- | --- |
| `ViewDesc.volumetric_fog` | A froxel volume of the view's `HeightFog`; faults `INVALID_ARGUMENT` with `ShadingPath.PATH_TRACED` |
| `ViewDesc.fog_quality` | `FogQuality` grid of that volume: `LOW`, `MEDIUM` (the zero value) or `HIGH` |
| `ViewDesc.fog_temporal` | Accumulates the volume over frames; needs `volumetric_fog` |
| `ViewDesc.cloud_temporal` | Accumulates the cloud march over frames |

Reflection captures render without height fog, medium volumes and clouds. Path-traced views draw none of the three.

## Counters

`Stats` resets at `begin_frame`. A counter that counts per view or per resolution sums over the frame.

| Counter | Counts |
| --- | --- |
| `atmospheres_ignored` | Per resolution: extra, invalid or sunless atmospheres of a scene |
| `atmospheres_dropped` | Per resolution: atmospheres drawn as absent for want of a renderer slot |
| `fogs_ignored` | Per view: extra or invalid height fogs the view sees |
| `media_dropped` | Per view: visible medium volumes past the nearest four |
| `clouds_ignored` | Per view: extra or invalid cloud layers the view sees |
| `sky_regenerations` | Atmosphere lightings marked for regeneration this frame |
| `dangling_refs` | Includes a `CloudLayer.coverage` texture that no longer exists |

## Passes

| `Pass` | Work |
| --- | --- |
| `SKY_VIEW` | The per-view sky-view table |
| `AERIAL_PERSPECTIVE` | The per-view aerial perspective volume |
| `FOG_SCATTERING`, `FOG_INTEGRATION` | The fog volume |
| `SKY` | The sky background draw |
| `FOG` | The fog pass over the scene |
| `CLOUD_SHADOWS` | The cloud shadow map |
| `CLOUDS` | The cloud march and composite |
| `ENVIRONMENT` | The atmosphere's tables and cubes, as the stages `environment.sky_transmittance`, `environment.sky_multi_scattering` and `environment.sky`, then `environment.prefilter`, `environment.irradiance` and `environment.sheen`; the cloud noise as `environment.cloud_noise` |

Order of a fogged raster view (brackets mark passes that exist only with their feature):

```
forward:   uploads, shadows, sky view, aerial perspective, [cloud shadows], [fog volume], [depth prepass],
           [ambient occlusion], [screen-space GI], forward opaque and sky, [clouds], [scene snapshot, scene reads],
           [snapshot for blended readers], [screen-space GI colour copy], fog, [transparent], debug lines, post
deferred:  uploads, shadows, sky view, aerial perspective, [cloud shadows], [fog volume], depth prepass, G-buffer,
           [ambient occlusion], [screen-space GI], [reflections], lighting, forward opaque and sky, then as forward
```

The sky-view and aerial perspective tables record only when the scene has an atmosphere. The fog pass reads depth and
rewrites `hdr_color` in place. The transparent pass reopens with depth attached for testing, so a blended stage fogs
itself with `apply_fog`. A view with depth-pruned clusters records the fog volume after the pruning.

## Memory

| Owner | Cost |
| --- | --- |
| Each raster view that is not path traced | 418 KiB and two heap slots: a 192 × 108 sky-view table and a 32³ aerial perspective volume, both `RGBA16F` |
| Each atmosphere | About 0.6 MiB and 82 heap slots: the 256 × 64 transmittance and 32 × 32 multiple-scattering tables, and 64-texel source and GGX cubes |
| Each atmosphere, with a sheen material | About 0.9 MiB and 119 heap slots: adds a Charlie cube |
| Fog volume | `ceil(w / px) × ceil(h / px) × slices × 8` bytes per view for a working image of `w` × `h` pixels; twice that with `fog_temporal` |
| Clouds, per view | `12 × ceil(w / 2) × ceil(h / 2)` bytes; twice that with `cloud_temporal` |
| Cloud shadow map, per view | `CLOUD_SHADOW_SIZE² × 2` bytes, 512 KiB |
| Cloud noise | 8 MiB, once per renderer |

## See also

- [Sky and atmosphere](sky.md), [fog and medium volumes](fog.md), [clouds](clouds.md)
- [Views](views.md) for `ViewDesc`
