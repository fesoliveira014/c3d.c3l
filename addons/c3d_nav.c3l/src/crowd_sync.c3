module c3d::nav;

import c3d::scene;

<*
 Bind agents to nodes, step the crowd, and write the positions of agents that are not driven.
 @param [&inout] scene : "The crowd's scene; world matrices as left by the last update_world."
 @param [&inout] crowd : "Agents are added and removed to match the NavAgent components."
 @param [inout] debug : "Filled for the agent it names; null for none."
 @require dt > 0, crowd.scene == scene
*>
fn void crowd_update(
    Scene* scene,
    Crowd* crowd,
    float dt,
    CrowdDebugInfo* debug = null,
) {
    remove_orphan_agents(scene, crowd);
    drain_agent_removals(crowd);
    bind_agents(scene, crowd);
    crowd.update(dt, debug);
    write_agent_positions(scene, crowd);
}

// Removing a mirror fires its remove hook, which queues the slot; removal waits for the walk to end.
fn void remove_orphan_agents(Scene* scene, Crowd* crowd) @local {
    usz orphans;
    scene.@each(CrowdAgentRuntime; entity, runtime) {
        if (!scene.world.has(entity, NavAgent)) crowd.orphan_scratch[orphans++] = entity;
    };
    foreach (entity : crowd.orphan_scratch[:orphans]) {
        scene.remove_component(scene.node(entity), CrowdAgentRuntime);
    }
}

// The hook is the one path that frees slots, so a slot freed here is never taken and freed again.
fn void drain_agent_removals(Crowd* crowd) @local {
    AgentRemovalQueue* removals = crowd.removals;
    foreach (index : removals.indices[:removals.count]) crowd.remove_agent(index);
    removals.count = 0;
}

fn void bind_agents(Scene* scene, Crowd* crowd) @local {
    crowd.unbound = 0;
    scene.@each(NavAgent; entity, nav_agent) {
        Node* node = scene.node(entity);
        CrowdAgentRuntime* runtime = scene.get(node, CrowdAgentRuntime);
        bool added;
        if (!runtime) {
            uint? index = crowd.add_agent(node.world_position(), nav_agent.params);
            if (catch index) {
                crowd.unbound++;
            } else {
                runtime = scene.add(node, (CrowdAgentRuntime){ .index = index });
                added = true;
            }
        }
        if (runtime) {
            if (added || nav_agent.changed) push_agent_request(crowd, runtime.index, nav_agent);
            CrowdAgent* agent = &crowd.agents[runtime.index];
            agent.driven = nav_agent.driven;
            if (agent.driven) agent.position = node.world_position();
        }
    };
}

fn void push_agent_request(Crowd* crowd, uint index, NavAgent* nav_agent) @local {
    nav_agent.changed = false;
    crowd.update_agent_params(index, nav_agent.params);
    switch (nav_agent.target_kind) {
        case NONE:
            crowd.reset_move_target(index);
        case POSITION:
            NearestPoly? nearest = crowd.query.find_nearest_poly(
                nav_agent.target,
                crowd.placement_half_extents,
                agent_filter(crowd, &crowd.agents[index]),
            );
            if (catch nearest) {
                crowd.reset_move_target(index);
                // A target off the mesh fails where the application can see it.
                crowd.agents[index].target_state = FAILED;
            } else {
                crowd.request_move_target(index, nearest.ref, nearest.point);
            }
        case VELOCITY:
            crowd.request_move_velocity(index, nav_agent.target);
    }
}

fn void write_agent_positions(Scene* scene, Crowd* crowd) @local {
    scene.@each2(NavAgent, CrowdAgentRuntime; entity, nav_agent, runtime) {
        CrowdAgent* agent = &crowd.agents[runtime.index];
        if (!agent.driven) scene.node(entity).set_world_position(agent.position);
    };
}
