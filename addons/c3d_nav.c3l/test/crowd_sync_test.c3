module c3d_nav_test;

import std::math;
import c3d::nav @public;
import c3d::scene;

const uint  SYNC_UPDATES @private = 60;
const Vec3  PARENT_OFFSET @private = { 5, 0, 0 };
const float DRIVEN_ALIGNMENT @private = 0.9f; // cosine; the steering points within 26 degrees of the target

fn Node* add_agent_node(QueryFixture* fixture, Vec3 position, Node* parent = null) @private {
    Scene* scene = &fixture.level.scene;
    Node* node = scene.add_node(parent)!!;
    node.local.position = position;
    scene.update_world();
    scene.add_nav_agent(node, nav::default_nav_agent_params())!!;
    return node;
}

fn void run_crowd(QueryFixture* fixture, Crowd* crowd, uint updates) @private {
    for (uint update = 0; update < updates; update++) {
        nav::crowd_update(&fixture.level.scene, crowd, CROWD_STEP);
        fixture.level.scene.update_world();
    }
}

fn usz active_count(Crowd* crowd) @private {
    CrowdAgent*[CROWD_AGENTS] agents;
    return crowd.active_agents(agents[..]);
}

fn void test_removing_a_node_removes_its_agent() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    build_level(fixture);
    Crowd crowd = create_test_crowd(fixture);
    defer nav::destroy_crowd(&crowd);
    Scene* scene = &fixture.level.scene;
    Node* removed = add_agent_node(fixture, { 4, 0, 4 });
    add_agent_node(fixture, { 8, 0, 4 });
    run_crowd(fixture, &crowd, 1);
    uint freed = scene.get(removed, CrowdAgentRuntime).index;
    usz before = active_count(&crowd);

    scene.remove_later(removed);
    scene.flush_removals();
    run_crowd(fixture, &crowd, 1);
    usz after = active_count(&crowd);
    Node* replacement = add_agent_node(fixture, { 12, 0, 4 });
    run_crowd(fixture, &crowd, 1);

    assert(before == 2 && after == 1);
    assert(scene.get(replacement, CrowdAgentRuntime).index == freed, "the freed slot is reused");
    assert(active_count(&crowd) == 2);
}

fn void test_driven_agent_leaves_the_node_position_alone() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    build_level(fixture);
    Crowd crowd = create_test_crowd(fixture);
    defer nav::destroy_crowd(&crowd);
    Scene* scene = &fixture.level.scene;
    Vec3 start = { 4, 0, 4 };
    Vec3 target = { 14, 0, 4 };
    Node* node = add_agent_node(fixture, start);
    scene.get(node, NavAgent).driven = true;
    scene.set_nav_target(node, target);

    for (uint update = 0; update < SYNC_UPDATES; update++) {
        run_crowd(fixture, &crowd, 1);
        assert(node.local.position == start, "update %d moved the node", update);
    }

    CrowdAgent* agent = crowd.agent(scene.get(node, CrowdAgentRuntime).index);
    Vec3 heading = agent.velocity.normalize();
    assert(agent.driven && agent.velocity.length() > STOPPED_SPEED);
    assert(heading.dot((target - start).normalize()) > DRIVEN_ALIGNMENT, "the velocity points at the target");
}

fn void test_crowd_update_writes_parent_space_positions() @test {
    QueryFixture* fixture = floor_level(2);
    defer destroy_level(fixture);
    build_level(fixture);
    Crowd crowd = create_test_crowd(fixture);
    defer nav::destroy_crowd(&crowd);
    Scene* scene = &fixture.level.scene;
    Node* parent = scene.add_node()!!;
    parent.local.position = PARENT_OFFSET;
    Vec3 start = { 4, 0, 4 };
    Node* node = add_agent_node(fixture, start - PARENT_OFFSET, parent);
    scene.set_nav_target(node, { 14, 0, 4 });

    run_crowd(fixture, &crowd, SYNC_UPDATES);

    Vec3 world = node.world_position();
    NearestPoly under = nearest(fixture, world);
    assert(world.x > start.x + 1, "the agent walked");
    assert(under.over_poly && math::abs(under.point.y - world.y) < QUERY_TOLERANCE, "on the mesh");
    assert((node.local.position - (world - PARENT_OFFSET)).length() < QUERY_TOLERANCE, "parent space");
}
