# FBX fixtures

Copied unchanged from the `data/` directory of [ufbx](https://github.com/ufbx/ufbx) at tag
`v0.23.0` (the `lib/ufbx.c3l/vendor/ufbx` submodule). ufbx and its data are available under the
MIT License or as public domain (Unlicense); see `lib/ufbx.c3l/vendor/ufbx/LICENSE`.

| File | Used for |
| --- | --- |
| `maya_cube_7400_binary.fbx` | Centimeter units converted to meters, part children, keys, Lambert material, empty take |
| `blender_293_half_skinned_7400_binary.fbx` | Skeleton, skin streams, vertices without weights |
| `maya_blend_inbetween_7500_binary.fbx` | Blend channels with in-between shapes and their weight animation |
| `blender_293_embedded_textures_7400_binary.fbx` | Embedded textures, packed metallic-roughness and base-opacity maps |
| `blender_279_internal_textures_7400_binary.fbx` | External textures that cannot be read (the `textures/` directory is not copied) |
