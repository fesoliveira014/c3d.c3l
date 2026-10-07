module c3d_nav_domains_test;

import c3d;
import c3d::nav;
import c3d::scene;

fn void test_nav_volume_add_rejects_nonfinite_active_fields() @test => check_runtime_domain(VOLUME);
fn void test_nav_link_add_rejects_nonfinite_active_fields() @test => check_runtime_domain(LINK);
fn void test_nav_obstacle_add_rejects_nonfinite_active_fields() @test => check_runtime_domain(OBSTACLE);
fn void test_nav_agent_add_rejects_nonfinite_params() @test => check_runtime_domain(AGENT);

fn void check_runtime_domain(DomainOwner owner) @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    nav::register_nav(&scene)!!;
    for (uint variant = 0; variant < domain_variants(owner); variant++) {
        Node* node = scene.add_node()!!;
        DomainFixture fixture;
        setup_domain(&fixture, owner, variant);
        uint fields = owner == AGENT ? 7 : fixture.count;
        foreach (field : fixture.fields[:fields]) {
            float original = *field;
            foreach (bits : (uint[3]){ 0x7fc01234, 0x7f800000, 0xff800000 }) {
                *field = bitcast(bits, float);
                assert(@catch(add_domain(&scene, node, &fixture)) == c3d::INVALID_ARGUMENT);
            }
            *field = original;
        }
        add_domain(&scene, node, &fixture)!!;
        scene.remove(node);
    }
}

fn void test_nav_numeric_range_boundaries_are_unchanged() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    nav::register_nav(&scene)!!;
    Node* node = scene.add_node()!!;
    NavAgentParams params = nav::default_nav_agent_params();
    params.radius = 0;
    params.max_speed = 0;
    params.max_acceleration = -1;
    params.collision_query_range = -2;
    params.path_optimization_range = -3;
    params.separation_weight = -4;
    scene.add_nav_agent(node, params)!!;
    scene.add_nav_obstacle(node, { .kind = BOX })!!;
    scene.add_nav_volume(node, { .kind = CONVEX, .vert_count = 3, .min_y = 1, .max_y = 1 })!!;
    Node* rejected = scene.add_node()!!;
    params.height = 0;
    assert(@catch(scene.add_nav_agent(rejected, params)) == c3d::INVALID_ARGUMENT);
    assert(@catch(scene.add_nav_volume(rejected, { .kind = CYLINDER, .radius = 0, .height = 1 })) == c3d::INVALID_ARGUMENT);
    assert(@catch(scene.add_nav_obstacle(rejected, { .kind = ORIENTED_BOX })) == c3d::INVALID_ARGUMENT);
}
