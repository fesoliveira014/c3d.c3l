module c3d::test::ribbons;

import c3d;
import c3d::maths;
import c3d::scene;
import c3d::spatial;
import std::math;

const float TOLERANCE @local = 1e-5f;

fn bool near_vector(Vec3 first, Vec3 second) @local {
    return (first - second).length() <= TOLERANCE;
}

fn void test_ribbon_bounds_cover_points_and_half_width() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    RibbonPoint[2] points = { scene::RIBBON_POINT_DEFAULT, scene::RIBBON_POINT_DEFAULT };
    points[0].position = { 1, 0, 0 };
    points[0].width = 2;
    points[1].position = { 1, 4, 0 };
    points[1].width = 1;
    Node* node = scene.add_ribbons(material: {}, capacity: 2, points: points[..])!!;
    node.local.position = { 3, 4, 5 };
    node.local.scale = { 2, 2, 2 };
    node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2);
    scene.update_world();
    Aabb bounds = spatial::ribbon_world_bounds(node, scene.get(node, RibbonBatch));
    assert(near_vector(bounds.min, { 1, 2, 1 }));
    assert(near_vector(bounds.max, { 5, 13, 5 }));
}

fn void test_ribbon_bounds_override_replaces_point_bounds() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    RibbonPoint[2] points = { scene::RIBBON_POINT_DEFAULT, scene::RIBBON_POINT_DEFAULT };
    points[1].position = { 0, 1, 0 };
    Node* node = scene.add_ribbons(material: {}, capacity: 2, points: points[..])!!;
    node.local.position = { 5, 0, 0 };
    scene.update_world();
    RibbonBatch* batch = scene.get(node, RibbonBatch);
    Aabb point_bounds = spatial::ribbon_world_bounds(node, batch);
    assert(point_bounds.min.x > 4 && point_bounds.max.x < 6);

    batch.has_bounds_override = true;
    batch.local_bounds = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
    Aabb bounds = spatial::ribbon_world_bounds(node, batch);
    assert(near_vector(bounds.min, { 4, -1, -1 }) && near_vector(bounds.max, { 6, 1, 1 }));
}
