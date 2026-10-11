module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import c3d::test::animated_lod_fixtures;
import c3d::test::transparency_fixtures;
import gpu;
import gpu::internal @public;
import vk;
import std::io;
import std::io::path;
import std::math;

const uint LAYERED_CROWD_SIZE @private = 256;
const uint LAYERED_CROWD_SOURCES @private = 2;
const uint LAYERED_CROWD_FRAGMENTS @private = LAYERED_CROWD_SOURCES * animated_crowd_fixtures::PARTS_MESH_COUNT;
const double LAYERED_CROWD_HEIGHT @private = 8;
const double LAYERED_CROWD_EDGE_MARGIN @private = 2 * LAYERED_CROWD_HEIGHT / LAYERED_CROWD_SIZE;
const float[2] LAYERED_CROWD_COVERAGE @private = { 0.5f, 0.25f };
const Vec4[2] LAYERED_CROWD_COLORS @private = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 } };
const uint LAYERED_REAL_LEVEL @private = 2;
const uint LAYERED_REAL_SAMPLE_STRIDE @private = 8;
const uint LAYERED_REAL_FRAGMENT_CAPACITY @private = 64;
const double LAYERED_REAL_BARYCENTRIC_MARGIN @private = 0.08;
const float LAYERED_REAL_CAMERA_Y @private = 1.4f;

struct LayeredRealTriangle @private {
    double[<3>][3] points;
    double[<3>][3] raster_points;
    uint source;
    uint part;
    uint primitive;
}

struct LayeredCrowdSnapshot @private {
    uint count;
    Transform[] placements;
    Vec4[] colors;
    Mat4[] palettes;
    float[] weights;
    uint[] batch_revisions;
    uint[] batch_counts;
    Transform[][] batch_transforms;
    Vec4[][] batch_colors;
    uint lod_revision;
    uint lod_bounds_revision;
    uint lod_descriptor_revision;
    uint lod_count;
    uint[] lod_generations;
}

fn LayeredCrowdSnapshot snapshot_layered_crowd(Scene* scene, Node* owner) @private {
    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    LayeredCrowdSnapshot snapshot = {
        .count = crowd.count,
        .placements = alloc::clone_slice(mem, crowd.placements),
        .colors = alloc::clone_slice(mem, crowd.colors),
        .palettes = alloc::clone_slice(mem, crowd.palettes),
        .weights = alloc::clone_slice(mem, crowd.morph_weights),
        .batch_revisions = mem::new_array(uint, crowd.parts.len),
        .batch_counts = mem::new_array(uint, crowd.parts.len),
        .batch_transforms = mem::new_array(Transform[], crowd.parts.len),
        .batch_colors = mem::new_array(Vec4[], crowd.parts.len),
    };
    foreach (index, part : crowd.parts) {
        InstancedMesh* batch = scene.world.get(part.batch, InstancedMesh);
        snapshot.batch_revisions[index] = batch.revision;
        snapshot.batch_counts[index] = batch.count;
        snapshot.batch_transforms[index] = alloc::clone_slice(mem, batch.transforms);
        snapshot.batch_colors[index] = alloc::clone_slice(mem, batch.colors);
    }
    if (LodGroup* group = scene.get(owner, LodGroup)) {
        snapshot.lod_revision = group.state.revision;
        snapshot.lod_bounds_revision = group.state.bounds_revision;
        snapshot.lod_descriptor_revision = group.state.descriptor_revision;
        snapshot.lod_count = group.state.count;
        snapshot.lod_generations = alloc::clone_slice(mem, group.state.slot_generations);
    }
    return snapshot;
}

fn void free_layered_crowd_snapshot(LayeredCrowdSnapshot* snapshot) @private {
    free(snapshot.placements.ptr);
    free(snapshot.colors.ptr);
    free(snapshot.palettes.ptr);
    free(snapshot.weights.ptr);
    free(snapshot.batch_revisions.ptr);
    free(snapshot.batch_counts.ptr);
    foreach (transforms : snapshot.batch_transforms) free(transforms.ptr);
    foreach (colors : snapshot.batch_colors) free(colors.ptr);
    free(snapshot.batch_transforms.ptr);
    free(snapshot.batch_colors.ptr);
    free(snapshot.lod_generations.ptr);
}

fn void check_layered_crowd_snapshot(Scene* scene, Node* owner, LayeredCrowdSnapshot* snapshot) @private {
    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    assert(crowd.count == snapshot.count);
    assert(crowd.placements.len == snapshot.placements.len);
    assert(mem::equals(
        a: crowd.placements.ptr,
        b: snapshot.placements.ptr,
        len: (sz)(snapshot.placements.len * Transform::size),
    ));
    assert(crowd.colors.len == snapshot.colors.len);
    assert(mem::equals(
        a: crowd.colors.ptr,
        b: snapshot.colors.ptr,
        len: (sz)(snapshot.colors.len * Vec4::size),
    ));
    assert(crowd.palettes.len == snapshot.palettes.len);
    assert(mem::equals(
        a: crowd.palettes.ptr,
        b: snapshot.palettes.ptr,
        len: (sz)(snapshot.palettes.len * Mat4::size),
    ));
    assert(crowd.morph_weights.len == snapshot.weights.len);
    assert(mem::equals(
        a: crowd.morph_weights.ptr,
        b: snapshot.weights.ptr,
        len: (sz)(snapshot.weights.len * float::size),
    ));
    foreach (index, part : crowd.parts) {
        InstancedMesh* batch = scene.world.get(part.batch, InstancedMesh);
        assert(batch.revision == snapshot.batch_revisions[index]);
        assert(batch.count == snapshot.batch_counts[index]);
        assert(batch.transforms.len == snapshot.batch_transforms[index].len);
        assert(mem::equals(
            a: batch.transforms.ptr,
            b: snapshot.batch_transforms[index].ptr,
            len: (sz)(snapshot.batch_transforms[index].len * Transform::size),
        ));
        assert(batch.colors.len == snapshot.batch_colors[index].len);
        assert(mem::equals(
            a: batch.colors.ptr,
            b: snapshot.batch_colors[index].ptr,
            len: (sz)(snapshot.batch_colors[index].len * Vec4::size),
        ));
    }
    if (LodGroup* group = scene.get(owner, LodGroup)) {
        assert(group.state.revision == snapshot.lod_revision);
        assert(group.state.bounds_revision == snapshot.lod_bounds_revision);
        assert(group.state.descriptor_revision == snapshot.lod_descriptor_revision);
        assert(group.state.count == snapshot.lod_count);
        assert(group.state.slot_generations.len == snapshot.lod_generations.len);
        assert(mem::equals(
            a: group.state.slot_generations.ptr,
            b: snapshot.lod_generations.ptr,
            len: (sz)(snapshot.lod_generations.len * uint::size),
        ));
    }
}

fn Vec4[]? render_layered_crowd_pixels(Fixture* fixture, LayeredScene* target, LayeredView* view) @private {
    fixture.renderer.begin_frame()!;
    defer catch render::abort_frame(&fixture.renderer);
    fixture.renderer.render_view(&target.scene, target.camera, view.view)!;
    fixture.renderer.finish_view(view.view)!;
    fixture.renderer.end_frame()!;
    Vec4[] pixels = mem::new_array(Vec4, LAYERED_CROWD_SIZE * LAYERED_CROWD_SIZE);
    defer catch free(pixels);
    fixture.renderer.read_render_target(view.target, ((char*)pixels.ptr)[:pixels.len * Vec4::size])!;
    return pixels;
}

fn void? attach_layered_parts_lod(
    Fixture* fixture,
    LayeredScene* target,
    Node* owner,
    ModelId model_id,
    MaterialId coarse_material,
) @private {
    @pool() {
        ModelTemplate* template = &fixture.assets.model(model_id).data;
        uint count = (uint)template.meshes.len;
        LodLevel[2] levels = {
            { .first_part = 0, .part_count = count, .min_screen_size = 0.1f },
            { .first_part = count, .part_count = count, .min_screen_size = 0 },
        };
        AnimatedLodPart[] parts = alloc::new_array(tmem, AnimatedLodPart, (usz)count * 2);
        for (uint level = 0; level < 2; level++) {
            foreach (uint part, mesh : template.meshes) {
                ModelSkin skin;
                foreach (candidate : template.skins) {
                    if (candidate.mesh_node == mesh.node) skin = candidate;
                }
                parts[level * count + part] = {
                    .draw = {
                        .geometry = mesh.geometry,
                        .material = level ? coarse_material : mesh.material,
                        .local = matrix::IDENTITY4,
                    },
                    .mesh_index = part,
                    .skin = skin,
                    .default_morph_weights = mesh.default_morph_weights,
                };
            }
        }
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &target.scene,
            owner: owner,
            desc: { .levels = levels[..], .parts = parts },
        )!;
    };
}

fn Vec3 layered_parts_point(
    uint source,
    uint part,
    uint corner,
    Transform[] placements,
) @private {
    uint index = part * animated_crowd_fixtures::PARTS_VERTEX_COUNT + corner;
    Vec3 literal = source ? animated_crowd_fixtures::PARTS_POSED_POINTS[index]
      : animated_crowd_fixtures::PARTS_REST_POINTS[index];
    Vec3 local = literal - animated_crowd_fixtures::PARTS_ROOT_POSITION;
    Transform placement = placements[source];
    return placement.position + placement.scale * local;
}

fn double layered_triangle_side(double[<2>] first, double[<2>] second, double[<2>] point) @private {
    return (second.x - first.x) * (point.y - first.y) - (second.y - first.y) * (point.x - first.x);
}

fn bool layered_near_triangle_edge(double[<2>] point, Vec3[3] triangle) @private {
    for (uint edge = 0; edge < 3; edge++) {
        Vec3 first = triangle[edge];
        Vec3 second = triangle[(edge + 1) % 3];
        double[<2>] start = { first.x, first.y };
        double[<2>] delta = { (double)second.x - first.x, (double)second.y - first.y };
        double squared_length = delta.x * delta.x + delta.y * delta.y;
        double[<2>] offset = point - start;
        double share = math::clamp((offset.x * delta.x + offset.y * delta.y) / squared_length, 0.0, 1.0);
        double[<2>] distance = offset - share * delta;
        if (distance.x * distance.x + distance.y * distance.y
          <= LAYERED_CROWD_EDGE_MARGIN * LAYERED_CROWD_EDGE_MARGIN) return true;
    }
    return false;
}

fn bool layered_triangle_covers(double[<2>] point, Vec3[3] triangle) @private {
    double[<2>][3] vertices;
    foreach (index, vertex : triangle) vertices[index] = { vertex.x, vertex.y };
    double first = layered_triangle_side(vertices[0], vertices[1], point);
    double second = layered_triangle_side(vertices[1], vertices[2], point);
    double third = layered_triangle_side(vertices[2], vertices[0], point);
    return (first > 0 && second > 0 && third > 0) || (first < 0 && second < 0 && third < 0);
}

fn void check_layered_parts_raster(
    Fixture* fixture,
    LayeredScene* target,
    LayeredView* view,
    Node* owner,
    Transform[] placements,
    Vec4[] pixels,
    uint level,
    bool lod,
) @private {
    AnimatedCrowd* crowd = target.scene.get(owner, AnimatedCrowd);
    uint[] captured = read_layered_depth(fixture, view, 0)!!;
    defer free(captured);
    uint[] shaded = read_layered_material_anchor(fixture, view)!!;
    defer free(shaded);
    uint samples;
    uint tie_samples;
    uint[LAYERED_CROWD_SOURCES] source_samples;
    for (uint row = 0; row < LAYERED_CROWD_SIZE; row++) {
        for (uint column = 0; column < LAYERED_CROWD_SIZE; column++) {
            double[<2>] point = {
                -LAYERED_CROWD_HEIGHT / 2 + LAYERED_CROWD_HEIGHT * ((double)column + 0.5) / LAYERED_CROWD_SIZE,
                LAYERED_CROWD_HEIGHT / 2 - LAYERED_CROWD_HEIGHT * ((double)row + 0.5) / LAYERED_CROWD_SIZE,
            };
            transparency_fixtures::DepthFragment[LAYERED_CROWD_FRAGMENTS] fragments;
            uint count;
            bool boundary;
            for (uint part = 0; part < animated_crowd_fixtures::PARTS_MESH_COUNT; part++) {
                for (uint source = 0; source < LAYERED_CROWD_SOURCES; source++) {
                    Vec3[3] triangle;
                    for (uint corner = 0; corner < 3; corner++) {
                        triangle[corner] = layered_parts_point(
                            source: source,
                            part: part,
                            corner: corner,
                            placements: placements,
                        );
                    }
                    boundary |= layered_near_triangle_edge(point, triangle);
                    if (!layered_triangle_covers(point, triangle)) continue;
                    Entity identity = lod ? owner.id : crowd.parts[part].batch;
                    Vec4 color = LAYERED_CROWD_COLORS[source];
                    fragments[count++] = {
                        .depth = (9 + triangle[0].z) / 8,
                        .node_index = identity.index,
                        .node_generation = identity.generation,
                        .part_index = lod ? level * animated_crowd_fixtures::PARTS_MESH_COUNT + part : part,
                        .instance_index = source,
                        .radiance = { color.x, color.y, color.z },
                        .coverage = lod ? LAYERED_CROWD_COVERAGE[level] : LAYERED_CROWD_COVERAGE[0],
                    };
                }
            }
            if (boundary) continue;
            transparency_fixtures::order_depth_fragments(fragments[:count]);
            transparency_fixtures::DepthGroup[LAYERED_CROWD_FRAGMENTS] groups;
            uint group_count = transparency_fixtures::classify_depth_groups(fragments[:count], groups[..]);
            transparency_fixtures::Color expected = transparency_fixtures::PLANAR_BACKGROUND;
            for (uint group = group_count; group > 0; group--) {
                transparency_fixtures::DepthGroup entry = groups[group - 1];
                if (entry.count > 1) tie_samples++;
                foreach (fragment : fragments[entry.begin:entry.count]) {
                    expected = transparency_fixtures::compose_over(expected, fragment.radiance, fragment.coverage);
                    source_samples[fragment.instance_index]++;
                }
            }
            uint pixel = row * LAYERED_CROWD_SIZE + column;
            check_layered_color(pixels[pixel], expected);
            if (count) {
                assert(captured[pixel] == bitcast(fragments[0].depth, uint));
                assert(captured[pixel] == shaded[pixel]);
                samples++;
            }
        }
    }
    assert(samples > 0 && tie_samples > 0);
    foreach (count : source_samples) assert(count > 0);
}

fn void test_layered_mixed_crowd_and_animated_lod_match_literal_pose_slot_order_without_scene_writes() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    fixture.assets.material(parts.material).data.common.alpha_mode = AlphaMode.BLEND;
    fixture.assets.material(parts.material).data.common.double_sided = true;
    fixture.assets.material(parts.material).data.basic.color.w = LAYERED_CROWD_COVERAGE[0];
    fixture.assets.mark_material_dirty(parts.material);
    MaterialId coarse = add_layered_basic(&fixture, { 1, 1, 1, LAYERED_CROWD_COVERAGE[1] })!!;
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    target.scene.@each(Mesh; Entity entity, Mesh* mesh) { target.scene.node(entity).visible = false; };
    target.scene.background.color = { 0.125f, 0.25f, 0.5f, 1 };
    *target.scene.get(target.camera, Camera) = camera::orthographic((float)LAYERED_CROWD_HEIGHT, 1, 9);
    Transform[LAYERED_CROWD_SOURCES] placements = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    placements[0].position = { 3, 0, -5 };
    placements[0].scale = { -0.25f, 0.25f, 0.25f };
    placements[1].position = { 0, 0, -5 };
    placements[1].scale = { 0.25f, 0.25f, 0.25f };
    CrowdInstance[LAYERED_CROWD_SOURCES] instances;
    foreach (uint source, &instance : instances) {
        *instance = {
            .placement = placements[source],
            .pose = { .clip = parts.posing, .time = source ? 1 : 0, .speed = 0, .loop = false },
            .color = LAYERED_CROWD_COLORS[source],
        };
    }
    Node* owner = model::add_crowd(
        assets: &fixture.assets,
        scene: &target.scene,
        model: parts.mixed,
        capacity: LAYERED_CROWD_SOURCES,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
    )!!;
    anim::crowd_update(&fixture.assets, &target.scene, 0);
    target.scene.update_world();
    LayeredView view = create_layered_view(&fixture, 4)!!;
    defer destroy_layered_view(&fixture, &view);
    render::resize_render_target(
        renderer: &fixture.renderer,
        target: view.target,
        width: LAYERED_CROWD_SIZE,
        height: LAYERED_CROWD_SIZE,
    )!!;
    for (uint row = 0; row < 3; row++) {
        bool lod = row != 0;
        uint level = row == 2 ? 1 : 0;
        if (row == 1) {
            attach_layered_parts_lod(
                fixture: &fixture,
                target: &target,
                owner: owner,
                model_id: parts.mixed,
                coarse_material: coarse,
            )!!;
        }
        ViewDesc desc = fixture.renderer.views.get(view.view).desc;
        desc.lod_bias = level ? -16 : 16;
        desc.instance_culling = row != 2;
        render::configure_view(&fixture.renderer, view.view, desc)!!;
        target.scene.update_world();
        LayeredCrowdSnapshot snapshot = snapshot_layered_crowd(&target.scene, owner);
        defer free_layered_crowd_snapshot(&snapshot);
        Vec4[] pixels = render_layered_crowd_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        check_layered_crowd_snapshot(&target.scene, owner, &snapshot);
        check_layered_parts_raster(
            fixture: &fixture,
            target: &target,
            view: &view,
            owner: owner,
            placements: placements[..],
            pixels: pixels,
            level: level,
            lod: lod,
        );
        check_layered_crowd_snapshot(&target.scene, owner, &snapshot);
    }
    check_validation(&fixture.renderer);
}

fn double[<3>] layered_real_vertex(
    AnimatedCrowd* crowd,
    Geometry* geometry,
    uint source,
    uint vertex,
) @private {
    Vec3 position = geometry.positions[vertex];
    double[<3>] skinned;
    for (uint influence = 0; influence < 4; influence++) {
        double weight = geometry.weights[vertex][influence];
        Mat4 palette = crowd.palettes[(usz)source * crowd.joint_count + geometry.joints[vertex][influence]];
        double[<3>] transformed = {
            (double)palette.m00 * position.x + (double)palette.m01 * position.y
              + (double)palette.m02 * position.z + palette.m03,
            (double)palette.m10 * position.x + (double)palette.m11 * position.y
              + (double)palette.m12 * position.z + palette.m13,
            (double)palette.m20 * position.x + (double)palette.m21 * position.y
              + (double)palette.m22 * position.z + palette.m23,
        };
        skinned += weight * transformed;
    }
    Transform placement = crowd.placements[source];
    return {
        placement.position.x + (double)placement.scale.x * skinned.x,
        placement.position.y + (double)placement.scale.y * skinned.y,
        placement.position.z + (double)placement.scale.z * skinned.z,
    };
}

fn Vec4 layered_real_float_vertex(
    AnimatedCrowd* crowd,
    Geometry* geometry,
    uint source,
    uint vertex,
) @private {
    Mat4 skin;
    for (uint influence = 0; influence < 4; influence++) {
        float weight = geometry.weights[vertex][influence];
        Mat4 palette = crowd.palettes[(usz)source * crowd.joint_count + geometry.joints[vertex][influence]];
        for (uint component = 0; component < skin.m.len; component++) {
            skin.m[component] += weight * palette.m[component];
        }
    }
    Vec3 position = geometry.positions[vertex];
    Vec4 local = skin.apply({ position.x, position.y, position.z, 1 });
    Mat4 placement = crowd.placements[source].to_mat4();
    return placement.apply({ local.x, local.y, local.z, 1 });
}

fn uint? layered_raster_precision_bits(gpu::Device* device) @private {
    gpu::internal::DeviceOperation operation = gpu::internal::begin_device_operation(device)!;
    defer gpu::internal::end_device_operation(&operation);
    vk::PhysicalDeviceProperties properties;
    vk::get_physical_device_properties(operation.state.physical_device, &properties);
    return properties.limits.sub_pixel_precision_bits;
}

fn LayeredRealTriangle[] layered_real_triangles(
    Fixture* fixture,
    AnimatedCrowd* crowd,
    AnimatedLodFixtures* corpus,
    Mat4 view_proj,
    double subpixel_steps,
) @private {
    usz count;
    foreach (levels : corpus.levels) count += fixture.assets.geometry(levels[LAYERED_REAL_LEVEL]).data.indices.len / 3;
    LayeredRealTriangle[] triangles = mem::new_array(LayeredRealTriangle, (sz)(count * crowd.count));
    usz written;
    foreach (uint part, levels : corpus.levels) {
        Geometry* geometry = &fixture.assets.geometry(levels[LAYERED_REAL_LEVEL]).data;
        for (uint source = 0; source < crowd.count; source++) {
            double[<3>][] vertices = mem::new_array(double[<3>], geometry.positions.len);
            defer free(vertices.ptr);
            double[<3>][] raster_vertices = mem::new_array(double[<3>], geometry.positions.len);
            defer free(raster_vertices.ptr);
            foreach (uint vertex, &point : vertices) {
                *point = layered_real_vertex(
                    crowd: crowd,
                    geometry: geometry,
                    source: source,
                    vertex: vertex,
                );
                Vec4 world = layered_real_float_vertex(
                    crowd: crowd,
                    geometry: geometry,
                    source: source,
                    vertex: vertex,
                );
                Vec4 clip = view_proj.apply(world);
                double screen_x = ((double)(clip.x / clip.w) + 1) * LAYERED_CROWD_SIZE / 2;
                double screen_y = (1 - (double)(clip.y / clip.w)) * LAYERED_CROWD_SIZE / 2;
                raster_vertices[vertex] = {
                    math::round(screen_x * subpixel_steps) / subpixel_steps,
                    math::round(screen_y * subpixel_steps) / subpixel_steps,
                    (double)(clip.z / clip.w),
                };
            }
            for (uint corner = 0; corner < geometry.indices.len; corner += 3) {
                triangles[written++] = {
                    .points = { vertices[geometry.indices[corner]], vertices[geometry.indices[corner + 1]],
                        vertices[geometry.indices[corner + 2]] },
                    .raster_points = { raster_vertices[geometry.indices[corner]],
                        raster_vertices[geometry.indices[corner + 1]], raster_vertices[geometry.indices[corner + 2]] },
                    .source = source,
                    .part = part,
                    .primitive = corner / 3,
                };
            }
        }
    }
    return triangles;
}

fn double[<3>] layered_real_weights(double[<2>] point, LayeredRealTriangle* triangle) @private {
    double[<2>] first = { triangle.points[0].x, triangle.points[0].y };
    double[<2>] second = { triangle.points[1].x, triangle.points[1].y };
    double[<2>] third = { triangle.points[2].x, triangle.points[2].y };
    double area = layered_triangle_side(first, second, third);
    if (area == 0) return { -1, -1, -1 };
    double a = layered_triangle_side(second, third, point) / area;
    double b = layered_triangle_side(third, first, point) / area;
    return { a, b, 1 - a - b };
}

fn float layered_real_raster_depth(double[<2>] pixel, LayeredRealTriangle* triangle) @private {
    LayeredRealTriangle raster = *triangle;
    raster.points = triangle.raster_points;
    double[<3>] weights = layered_real_weights(pixel, &raster);
    return (float)(weights.x * raster.points[0].z + weights.y * raster.points[1].z + weights.z * raster.points[2].z);
}

fn void check_layered_real_raster(
    Fixture* fixture,
    LayeredView* view,
    Node* owner,
    LayeredRealTriangle[] triangles,
    Vec4[] pixels,
) @private {
    uint[][render::TRANSPARENCY_LAYER_CAPACITY_MAX] captured;
    defer { foreach (depth : captured) free(depth.ptr); }
    for (uint group = 0; group < captured.len; group++) captured[group] = read_layered_depth(fixture, view, group)!!;
    uint[] shaded = read_layered_material_anchor(fixture, view)!!;
    defer free(shaded);
    uint[2] covered;
    uint[2] candidate_samples;
    uint[2] boundary_samples;
    uint[2] selected_actor_samples;
    uint selected_samples;
    uint ideal_maximum_ulp;
    uint raster_maximum_ulp;
    uint ideal_maximum_column;
    uint ideal_maximum_row;
    uint raster_maximum_column;
    uint raster_maximum_row;
    double ideal_maximum_error;
    double raster_maximum_error;
    uint cpu_order_checks;
    for (uint row = 2; row + 2 < LAYERED_CROWD_SIZE; row += LAYERED_REAL_SAMPLE_STRIDE) {
        for (uint column = 2; column + 2 < LAYERED_CROWD_SIZE; column += LAYERED_REAL_SAMPLE_STRIDE) {
            double[<2>] point = {
                -2 + 4 * ((double)column + 0.5) / LAYERED_CROWD_SIZE,
                (double)LAYERED_REAL_CAMERA_Y + 2 - 4 * ((double)row + 0.5) / LAYERED_CROWD_SIZE,
            };
            transparency_fixtures::DepthFragment[LAYERED_REAL_FRAGMENT_CAPACITY] fragments;
            float[LAYERED_REAL_FRAGMENT_CAPACITY] ideal_depths;
            float[LAYERED_REAL_FRAGMENT_CAPACITY] raster_depths;
            uint count;
            bool boundary;
            bool[2] candidate_actors;
            foreach (&triangle : triangles) {
                double[<3>] weights = layered_real_weights(point, triangle);
                if (weights.x <= 0 || weights.y <= 0 || weights.z <= 0) continue;
                candidate_actors[triangle.source] = true;
                boundary |= math::min(weights.x, math::min(weights.y, weights.z)) < LAYERED_REAL_BARYCENTRIC_MARGIN;
                double z = weights.x * triangle.points[0].z + weights.y * triangle.points[1].z
                  + weights.z * triangle.points[2].z;
                Vec4 color = LAYERED_CROWD_COLORS[triangle.source];
                assert(count < fragments.len);
                ideal_depths[count] = (float)((9 + z) / 8);
                raster_depths[count] = layered_real_raster_depth({ column + 0.5, row + 0.5 }, triangle);
                fragments[count] = {
                    .depth = raster_depths[count],
                    .node_index = owner.id.index,
                    .node_generation = owner.id.generation,
                    .part_index = LAYERED_REAL_LEVEL * animated_lod_fixtures::LOD_PRIMITIVES + triangle.part,
                    .instance_index = triangle.source,
                    .primitive_index = triangle.primitive,
                    .radiance = { color.x, color.y, color.z },
                    .coverage = 0.5,
                };
                count++;
            }
            foreach (source, selected : candidate_actors) {
                if (!selected) continue;
                candidate_samples[source]++;
                if (boundary) boundary_samples[source]++;
            }
            if (boundary || !count) continue;
            uint pixel = row * LAYERED_CROWD_SIZE + column;
            assert(captured[0][pixel] == shaded[pixel]);
            float[render::TRANSPARENCY_LAYER_CAPACITY_MAX] stored;
            uint stored_count;
            bool ended;
            foreach (group : captured) {
                uint bits = group[pixel];
                if (!bits) {
                    ended = true;
                    continue;
                }
                assert(!ended);
                float depth = bitcast(bits, float);
                assert(math::is_finite(depth) && depth > 0 && depth <= 1);
                if (stored_count) assert(stored[stored_count - 1] > depth);
                stored[stored_count++] = depth;
            }
            assert(stored_count > 0 && stored_count <= count);
            uint[render::TRANSPARENCY_LAYER_CAPACITY_MAX] membership;
            double sample_error;
            for (uint fragment = 0; fragment < count; fragment++) {
                uint nearest;
                double minimum_error = math::abs((double)stored[0] - raster_depths[fragment]);
                for (uint group = 1; group < stored_count; group++) {
                    double error = math::abs((double)stored[group] - raster_depths[fragment]);
                    if (error < minimum_error) {
                        minimum_error = error;
                        nearest = group;
                    }
                }
                membership[nearest]++;
                fragments[fragment].depth = stored[nearest];
                double ideal_error = math::abs((double)stored[nearest] - ideal_depths[fragment]);
                sample_error = math::max(sample_error, ideal_error);
                ideal_maximum_error = math::max(ideal_maximum_error, ideal_error);
                raster_maximum_error = math::max(raster_maximum_error, minimum_error);
                uint actual_bits = bitcast(stored[nearest], uint);
                uint ideal_bits = bitcast(ideal_depths[fragment], uint);
                uint raster_bits = bitcast(raster_depths[fragment], uint);
                uint ideal_ulp = actual_bits > ideal_bits ? actual_bits - ideal_bits : ideal_bits - actual_bits;
                uint raster_ulp = actual_bits > raster_bits ? actual_bits - raster_bits : raster_bits - actual_bits;
                if (ideal_ulp > ideal_maximum_ulp) {
                    ideal_maximum_ulp = ideal_ulp;
                    ideal_maximum_column = column;
                    ideal_maximum_row = row;
                }
                if (raster_ulp > raster_maximum_ulp) {
                    raster_maximum_ulp = raster_ulp;
                    raster_maximum_column = column;
                    raster_maximum_row = row;
                }
            }
            for (uint group = 0; group < stored_count; group++) assert(membership[group] > 0);
            for (uint first = 0; first < count; first++) {
                for (uint second = first + 1; second < count; second++) {
                    if (math::abs((double)ideal_depths[first] - ideal_depths[second]) <= 2 * sample_error) continue;
                    assert((ideal_depths[first] > ideal_depths[second])
                      == (fragments[first].depth > fragments[second].depth));
                    cpu_order_checks++;
                }
            }
            transparency_fixtures::order_depth_fragments(fragments[:count]);
            transparency_fixtures::DepthGroup[LAYERED_REAL_FRAGMENT_CAPACITY] groups;
            uint groups_used = transparency_fixtures::classify_depth_groups(fragments[:count], groups[..]);
            assert(groups_used <= render::TRANSPARENCY_LAYER_CAPACITY_MAX);
            transparency_fixtures::Color expected = transparency_fixtures::PLANAR_BACKGROUND;
            for (uint group = groups_used; group > 0; group--) {
                transparency_fixtures::DepthGroup entry = groups[group - 1];
                foreach (fragment : fragments[entry.begin:entry.count]) {
                    expected = transparency_fixtures::compose_over(expected, fragment.radiance, fragment.coverage);
                    covered[fragment.instance_index]++;
                }
            }
            check_layered_color(pixels[pixel], expected);
            selected_samples++;
            foreach (source, selected : candidate_actors) if (selected) selected_actor_samples[source]++;
        }
    }
    io::printfn("Quaternius ideal64 vs stored: max_ulp=%s location=(%s,%s) max_depth_error=%.12f",
      ideal_maximum_ulp, ideal_maximum_column, ideal_maximum_row, ideal_maximum_error);
    io::printfn("Quaternius float32/queried-grid vs stored: max_ulp=%s location=(%s,%s) max_depth_error=%.12f",
      raster_maximum_ulp, raster_maximum_column, raster_maximum_row, raster_maximum_error);
    io::printfn("Quaternius checked samples=%s unambiguous_cpu_order_pairs=%s", selected_samples, cpu_order_checks);
    foreach (source, samples : covered) {
        io::printfn("Quaternius actor=%s candidates=%s boundary_masked=%s selected_pixels=%s checked_fragments=%s",
          source, candidate_samples[source], boundary_samples[source], selected_actor_samples[source], samples);
    }
    foreach (samples : covered) assert(samples > 0);
    assert(selected_samples > 0);
}

fn void test_layered_quaternius_selected_lod_matches_published_palette_raster_without_scene_writes() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    AnimatedLodFixtures corpus;
    @pool() {
        Path source = path::tnew($$FILEPATH)!!;
        String repository = (String)source.parent()!!.tappend("../../..")!!;
        corpus = animated_lod_fixtures::load_animated_lod_fixtures(&fixture.assets, repository)!!;
    };
    ModelTemplate* template = &fixture.assets.model(corpus.model).data;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.double_sided = true;
    foreach (mesh : template.meshes) {
        fixture.assets.material(mesh.material).data = material::basic({ .color = { 1, 1, 1, 0.5f } }, common);
        fixture.assets.mark_material_dirty(mesh.material);
    }
    ClipId clip;
    foreach (candidate : template.clips) {
        if (fixture.assets.clip(candidate).data.name == "Walk_Loop") clip = candidate;
    }
    assert(clip.generation != 0);
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    target.scene.@each(Mesh; Entity entity, Mesh* mesh) { target.scene.node(entity).visible = false; };
    target.scene.background.color = { 0.125f, 0.25f, 0.5f, 1 };
    *target.scene.get(target.camera, Camera) = camera::orthographic(4, 1, 9);
    target.camera.local.position.y = LAYERED_REAL_CAMERA_Y;
    CrowdInstance[2] instances;
    foreach (uint source, &instance : instances) {
        Transform placement = maths::TRANSFORM_IDENTITY;
        placement.position = { source ? 1 : -1, 0, -5 };
        if (source == 0) placement.scale.x = -1;
        *instance = {
            .placement = placement,
            .pose = { .clip = clip, .time = source ? 0.65f : 0.25f, .speed = 0, .loop = false },
            .color = LAYERED_CROWD_COLORS[source],
        };
    }
    Node* owner = model::add_crowd(
        assets: &fixture.assets,
        scene: &target.scene,
        model: corpus.model,
        capacity: 2,
        pose_bounds: { .min = { -1.5f, -0.1f, -1.5f }, .max = { 1.5f, 2.7f, 1.5f } },
        instances: instances[..],
    )!!;
    anim::crowd_update(&fixture.assets, &target.scene, 0);
    @pool() {
        LodLevel[3] levels;
        AnimatedLodPart[6] parts;
        for (uint level = 0; level < 3; level++) {
            levels[level] = { .first_part = level * 2, .part_count = 2, .min_screen_size = level == 0 ? 1 : 0 };
            if (level == 1) levels[level].min_screen_size = 0.001f;
            foreach (uint part, mesh : template.meshes) {
                ModelSkin skin;
                foreach (candidate : template.skins) if (candidate.mesh_node == mesh.node) skin = candidate;
                parts[level * 2 + part] = {
                    .draw = {
                        .geometry = corpus.levels[part][level],
                        .material = mesh.material,
                        .local = matrix::IDENTITY4,
                    },
                    .mesh_index = part,
                    .skin = skin,
                    .default_morph_weights = mesh.default_morph_weights,
                };
            }
        }
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &target.scene,
            owner: owner,
            desc: { .levels = levels[..], .parts = parts[..] },
        )!!;
    };
    target.scene.update_world();
    LayeredView view = create_layered_view(&fixture, render::TRANSPARENCY_LAYER_CAPACITY_MAX)!!;
    defer destroy_layered_view(&fixture, &view);
    render::resize_render_target(
        renderer: &fixture.renderer,
        target: view.target,
        width: LAYERED_CROWD_SIZE,
        height: LAYERED_CROWD_SIZE,
    )!!;
    ViewDesc desc = fixture.renderer.views.get(view.view).desc;
    desc.lod_bias = -16;
    render::configure_view(&fixture.renderer, view.view, desc)!!;
    AnimatedCrowd* crowd = target.scene.get(owner, AnimatedCrowd);
    uint precision_bits = layered_raster_precision_bits(&fixture.renderer.device)!!;
    assert(precision_bits < uint::size * 8);
    double subpixel_steps = (double)(1ul << precision_bits);
    io::printfn("Quaternius Vulkan sub_pixel_precision_bits=%s", precision_bits);
    CameraMatrices matrices = camera::derive_matrices(
        camera: *target.scene.get(target.camera, Camera),
        camera_world: target.camera.world,
        viewport: { LAYERED_CROWD_SIZE, LAYERED_CROWD_SIZE },
    );
    LayeredRealTriangle[] triangles = layered_real_triangles(
        fixture: &fixture,
        crowd: crowd,
        corpus: &corpus,
        view_proj: matrices.view_proj,
        subpixel_steps: subpixel_steps,
    );
    defer free(triangles.ptr);
    LayeredCrowdSnapshot snapshot = snapshot_layered_crowd(&target.scene, owner);
    defer free_layered_crowd_snapshot(&snapshot);
    Vec4[] pixels = render_layered_crowd_pixels(&fixture, &target, &view)!!;
    defer free(pixels);
    check_layered_crowd_snapshot(&target.scene, owner, &snapshot);
    check_layered_real_raster(
        fixture: &fixture,
        view: &view,
        owner: owner,
        triangles: triangles,
        pixels: pixels,
    );
    check_layered_crowd_snapshot(&target.scene, owner, &snapshot);
    check_validation(&fixture.renderer);
}

fn void test_layered_billboard_sparse_visibility_preserves_original_slot_tie_order_and_scene_data() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LayeredView view = create_layered_view(&fixture, 2)!!;
    defer destroy_layered_view(&fixture, &view);
    Billboard[5] billboards;
    Vec4[5] colors = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 }, { 1, 1, 0, 1 }, { 0, 1, 1, 1 } };
    foreach (source, &billboard : billboards) {
        *billboard = scene::BILLBOARD_DEFAULT;
        billboard.position = { 0, 0, -5 };
        billboard.size = { 1.5f, 1.5f };
        billboard.color = colors[source];
    }
    billboards[1].position.x = 100;
    billboards[3].size.x = 0;
    MaterialId material = add_layered_basic(&fixture, { 1, 1, 1, 0.5f })!!;
    Node* node = target.scene.add_billboards(
        material: material,
        capacity: (uint)billboards.len,
        billboards: billboards[..],
    )!!;
    target.scene.update_world();
    BillboardBatch* batch = target.scene.get(node, BillboardBatch);
    uint revision = batch.revision;
    Billboard[] snapshot = alloc::clone_slice(mem, batch.billboards);
    defer free(snapshot.ptr);
    Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
    defer free(pixels);
    transparency_fixtures::Color expected = transparency_fixtures::PLANAR_BACKGROUND;
    uint[3] visible = { 0, 2, 4 };
    foreach (source : visible) {
        Vec4 color = colors[source];
        expected = transparency_fixtures::compose_over(expected, { color.x, color.y, color.z }, 0.5);
    }
    check_layered_interior(pixels, expected);
    uint[] captured = read_layered_depth(&fixture, &view, 0)!!;
    defer free(captured);
    uint[] second = read_layered_depth(&fixture, &view, 1)!!;
    defer free(second);
    uint[] shaded = read_layered_material_anchor(&fixture, &view)!!;
    defer free(shaded);
    for (uint row = LAYERED_INTERIOR_BEGIN; row < LAYERED_INTERIOR_END; row++) {
        for (uint column = LAYERED_INTERIOR_BEGIN; column < LAYERED_INTERIOR_END; column++) {
            uint pixel = row * LAYERED_IMAGE_SIZE + column;
            assert(captured[pixel] == bitcast(0.5f, uint) && second[pixel] == 0);
            assert(captured[pixel] == shaded[pixel]);
        }
    }
    assert(batch.count == billboards.len && batch.revision == revision);
    assert(batch.billboards.len == snapshot.len);
    assert(mem::equals(
        a: batch.billboards.ptr,
        b: snapshot.ptr,
        len: (sz)(snapshot.len * Billboard::size),
    ));
    check_validation(&fixture.renderer);
}
