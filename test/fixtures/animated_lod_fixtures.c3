module c3d::test::animated_lod_fixtures;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::geometry;
import c3d::render;

<* Source mesh primitives in the Quaternius mannequin. *>
const uint LOD_PRIMITIVES = 2;
<* Original geometry followed by two reduced levels. *>
const uint LOD_LEVELS = 3;
const uint TRIANGLE_CORNERS @local = 3;
const String SOURCE_PATH @local = "examples/assets/quaternius/AnimationLibrary_Godot.glb";

<* Store-owned source model and geometry alternatives, indexed primitive then level. *>
struct AnimatedLodFixtures {
    ModelId model;
    GeometryId[LOD_LEVELS][LOD_PRIMITIVES] levels;
    render::GeometryLayout[LOD_LEVELS][LOD_PRIMITIVES] layouts;
}

macro @gather(source, uint[] vertices) @local {
    if (!source.len) return source;
    var gathered = alloc::new_array(tmem, $Typeof(source[0]), vertices.len);
    foreach (index, &value : gathered) *value = source[vertices[index]];
    return gathered;
}

fn Geometry face_subset(Geometry* source, uint stride) @local {
    sz faces = (sz)(source.indices.len / TRIANGLE_CORNERS + stride - 1) / stride;
    uint[] compact = alloc::new_array(tmem, uint, source.positions.len);
    compact[..] = uint::max;
    uint[] vertices = alloc::new_array(tmem, uint, source.positions.len);
    uint count;
    Geometry level = {
        .topology = Topology.TRIANGLES,
        .indices = alloc::new_array(tmem, uint, faces * TRIANGLE_CORNERS),
        .bounds = source.bounds,
    };
    foreach (usz corner, &index : level.indices) {
        usz face = corner / TRIANGLE_CORNERS * stride;
        uint original = source.indices[face * TRIANGLE_CORNERS + corner % TRIANGLE_CORNERS];
        if (compact[original] == uint::max) {
            compact[original] = count;
            vertices[count++] = original;
        }
        *index = compact[original];
    }

    vertices = vertices[:count];
    level.positions = @gather(source.positions, vertices);
    level.normals = @gather(source.normals, vertices);
    level.tangents = @gather(source.tangents, vertices);
    level.uv0 = @gather(source.uv0, vertices);
    level.uv1 = @gather(source.uv1, vertices);
    level.colors = @gather(source.colors, vertices);
    level.joints = @gather(source.joints, vertices);
    level.weights = @gather(source.weights, vertices);
    return level;
}

<*
 Load the mannequin and add two face-subset levels for each mesh primitive.
 @param [&inout] assets : "Owns the returned model and geometries."
 @param repository : "Directory containing the examples folder."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn AnimatedLodFixtures? load_animated_lod_fixtures(AssetStore* assets, String repository) {
    @pool() {
        LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
        options.generate_tangents = false;
        AnimatedLodFixtures fixtures = {
            .model = gltf::load_model(assets, string::tformat("%s/%s", repository, SOURCE_PATH), options)!,
        };
        ModelTemplate* template = &assets.model(fixtures.model).data;
        for (uint primitive = 0; primitive < LOD_PRIMITIVES; primitive++) {
            GeometryId source = template.meshes[primitive].geometry;
            fixtures.levels[primitive][0] = source;
            for (uint level = 1; level < LOD_LEVELS; level++) {
                Geometry subset = face_subset(&assets.geometry(source).data, 1u << level);
                fixtures.levels[primitive][level] = assets.add_geometry(&subset)!;
            }
            for (uint level = 0; level < LOD_LEVELS; level++) {
                Geometry* geometry = &assets.geometry(fixtures.levels[primitive][level]).data;
                fixtures.layouts[primitive][level] = render::geometry_layout(geometry);
            }
        }
        return fixtures;
    };
}
