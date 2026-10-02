module c3d::scene;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::maths;
import std::math;

const uint IMPOSTOR_MIN_FRAMES @local = 2;
const uint IMPOSTOR_MAX_FRAMES @local = 32;
const uint IMPOSTOR_MIN_CELL @local = 4;
const float IMPOSTOR_BOUNDS_TOLERANCE @local = 1e-6f; // Accommodates the sphere calculation's rounding at AABB corners.

<* Maximum mesh levels plus one terminal impostor. *>
const uint MAX_LOD_CHOICES = MAX_LOD_LEVELS + 1;

<* Baked surface atlas and its subject-local capture frame. *>
struct Impostor {
    TextureId atlas;
    Sphere bounds;
    uint frames_per_side;
    uint cell_size;
}

<*
 Install a terminal raster alternative without taking texture ownership.
 @param [&in] assets : "Supplies the live atlas and mesh bounds."
 @param [&in] node : "Carries LodGroup."
 @param min_screen_size : "Minimum height fraction for the final mesh."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
 @require self.has(node, LodGroup)
*>
fn void? Scene.set_lod_impostor(
    &self,
    AssetStore* assets,
    Node* node,
    Impostor impostor,
    float min_screen_size,
) {
    LodGroupState* state = self.get(node, LodGroup).state;
    TextureAsset* texture = assets.textures.try_get(impostor.atlas)!;
    if (!impostor_texture_valid(impostor, &texture.desc)) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(min_screen_size) || min_screen_size <= 0) return c3d::INVALID_ARGUMENT~;
    if (state.desc.levels.len > 1 && min_screen_size >= state.desc.levels[^2].min_screen_size) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (state.effects.sway.amplitude != 0 && state.effects.sway.weight == SwayWeight.VERTEX_ALPHA) {
        return c3d::UNSUPPORTED~;
    }
    Sphere sphere = impostor.bounds;
    if (!math::is_finite(sphere.radius) || sphere.radius <= 0) return c3d::INVALID_ARGUMENT~;
    foreach (coordinate : sphere.center) {
        if (!math::is_finite(coordinate)) return c3d::INVALID_ARGUMENT~;
    }
    foreach (part : state.desc.parts) {
        GeometryAsset* geometry = assets.geometries.try_get(part.geometry)!;
        Aabb bounds = state.desc.has_bounds_override ? state.desc.local_bounds : maths::aabb_transform(geometry.data.bounds, part.local);
        for (uint corner = 0; corner < 8; corner++) {
            Vec3 point = {
                corner & 1 ? bounds.max.x : bounds.min.x,
                corner & 2 ? bounds.max.y : bounds.min.y,
                corner & 4 ? bounds.max.z : bounds.min.z,
            };
            if (point.distance(sphere.center) > sphere.radius * (1 + IMPOSTOR_BOUNDS_TOLERANCE)) return c3d::INVALID_ARGUMENT~;
        }
    }
    state.impostor = impostor;
    state.impostor_min_screen_size = min_screen_size;
    state.has_impostor = true;
    state.descriptor_revision++;
    state.geometry_revisions[..] = 0;
}

<*
 Remove the terminal alternative while retaining its texture asset.
 @param [&in] node : "Carries LodGroup."
 @require self.has(node, LodGroup)
*>
fn void Scene.clear_lod_impostor(&self, Node* node) {
    LodGroupState* state = self.get(node, LodGroup).state;
    state.impostor = {};
    state.impostor_min_screen_size = 0;
    state.has_impostor = false;
    state.descriptor_revision++;
    state.geometry_revisions[..] = 0;
}

fn bool impostor_texture_valid(Impostor impostor, TextureDesc* texture) @private {
    uint frames = impostor.frames_per_side;
    if (frames < IMPOSTOR_MIN_FRAMES || frames > IMPOSTOR_MAX_FRAMES || (frames & (frames - 1)) != 0
      || impostor.cell_size < IMPOSTOR_MIN_CELL) return false;
    ulong width = (ulong)frames * impostor.cell_size;
    if (width > uint::max / 2) return false;
    return texture.format == PixelFormat.RGBA8_UNORM && texture.width == width && texture.height == width * 2
      && texture.depth <= 1 && texture.layers == 1 && !texture.is_cube && texture.mip_levels == 1 && !texture.generate_mips;
}
