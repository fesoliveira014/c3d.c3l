module c3d::nav;

import std::math;
import c3d;
import c3d::ecs;
import c3d::scene;

<* Neighbours one agent considers; mirrors DT_CROWDAGENT_MAX_NEIGHBOURS. *>
const uint MAX_AGENT_NEIGHBOURS = 6;

<* Corners one agent looks ahead; mirrors DT_CROWDAGENT_MAX_CORNERS. *>
const uint MAX_AGENT_CORNERS = 4;

<* Avoidance configurations a crowd holds; mirrors DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS. *>
const uint MAX_AVOIDANCE_PARAMS = 8;

<* Query filters a crowd holds; mirrors DT_CROWD_MAX_QUERY_FILTER_TYPE. *>
const uint MAX_CROWD_FILTERS = 16;

<* Polygons a crowd corridor holds; mirrors m_maxPathResult. *>
const usz CROWD_MAX_PATH = 256; // 2 KiB per agent; a target further away in polygons is reached partially

<* Search nodes of the crowd's shared query; mirrors MAX_COMMON_NODES. *>
const uint CROWD_QUERY_NODES = 512;

<* Search nodes of the path queue's query; mirrors MAX_PATHQUEUE_NODES. *>
const uint CROWD_PATH_QUEUE_NODES = 4096;

<* Path queue iterations per update; mirrors MAX_ITERS_PER_UPDATE. *>
const uint CROWD_PATH_ITERATIONS = 100;

<* Agents a crowd may hold; its proximity grid indexes cell entries with 16 bits. *>
const uint MAX_CROWD_AGENTS = 16383;

const float DEFAULT_AGENT_RADIUS @local = 0.6f; // metres; the default build's agent radius
const float DEFAULT_AGENT_HEIGHT @local = 2; // metres; the default build's agent height
const float DEFAULT_AGENT_ACCELERATION @local = 8; // metres per second squared; mirrors RecastDemo
const float DEFAULT_AGENT_SPEED @local = 3.5f; // metres per second; mirrors RecastDemo
const float COLLISION_RANGE_RADII @local = 12; // mirrors RecastDemo: agents and walls within twelve radii are avoided
const float OPTIMIZATION_RANGE_RADII @local = 30; // mirrors RecastDemo: the visibility shortcut reaches thirty radii
const float DEFAULT_SEPARATION_WEIGHT @local = 2; // mirrors RecastDemo
const uint  AVOIDANCE_CIRCLES @local = 6; // mirrors dtCrowd::init: neighbours the sampler sees
const uint  AVOIDANCE_SEGMENTS @local = 8; // mirrors dtCrowd::init: walls the sampler sees
const uint  GRID_ITEMS_PER_AGENT @local = 4; // mirrors dtCrowd::init: an agent's bounds cover up to four cells
const float GRID_CELL_RADII @local = 3; // mirrors dtCrowd::init: grid cells three max agent radii wide
const Vec3  PLACEMENT_RADII @local = { 2, 1.5f, 2 }; // mirrors dtCrowd::init; wider than an agent to recover strays
const uint  QUICK_SEARCH_ITERATIONS @local = 20; // mirrors updateMoveRequest's MAX_ITER
const usz   QUICK_SEARCH_POLYS @local = 32; // mirrors updateMoveRequest's MAX_RES
const usz   PATH_REQUESTS_PER_UPDATE @local = 8; // mirrors updateMoveRequest's PATH_MAX_AGENTS
const usz   CHECK_LOOKAHEAD @local = 10; // mirrors checkPathValidity: corridor polygons checked every update
const float TARGET_REPLAN_DELAY @local = 1.0f; // seconds; mirrors checkPathValidity
const float TOPOLOGY_OPTIMIZATION_TIME @local = 0.5f; // seconds; mirrors OPT_TIME_THR
const usz   TOPOLOGY_AGENTS_PER_UPDATE @local = 1; // mirrors OPT_MAX_AGENTS
const usz   MAX_GRID_NEIGHBOURS @local = 32; // mirrors getNeighbours' MAX_NEIS
const float BOUNDARY_REFRESH_SHARE @local = 0.25f; // of the collision range walked before the walls are gathered again
const float OFF_MESH_TRIGGER_RADII @local = 2.25f; // mirrors update: agent radii from a connection that start crossing
const float SLOW_DOWN_RADII @local = 2; // mirrors update: agent radii from the goal over which an agent slows
const float MIN_TURN_LENGTH @local = 0.001f; // mirrors calcSmoothSteerDirection's floor on the second corner's distance
const float MIN_SEPARATION_DISTANCE_SQR @local = 0.00001f; // mirrors update: coincident neighbours give no direction
const float MIN_WEIGHT @local = 0.0001f; // mirrors update: below it no neighbour contributed
const float MIN_INTEGRATION_SPEED @local = 0.0001f; // mirrors integrate: slower agents stop
const uint  COLLISION_ITERATIONS @local = 4; // mirrors update's collision passes
const float COLLISION_RESOLVE_FACTOR @local = 0.7f; // mirrors update: share of an overlap each pass removes
const float COINCIDENT_DISTANCE @local = 0.0001f; // mirrors update: agents this close separate sideways
const float COINCIDENT_PENETRATION @local = 0.01f; // mirrors update: metres coincident agents push apart per pass
const float TRAVERSAL_TIME_SCALE @local = 0.5f; // mirrors update: a traversal takes half its walking time
const float TRAVERSAL_APPROACH_SHARE @local = 0.15f; // mirrors update: share of a traversal spent reaching the start

<* Which behaviours an agent runs; mirrors UpdateFlags. *>
bitstruct AgentUpdateFlags : char {
    bool anticipate_turns    : 0;
    bool obstacle_avoidance  : 1;
    bool separation          : 2;
    bool optimize_visibility : 3;
    bool optimize_topology   : 4;
}

<* Where an agent is; mirrors CrowdAgentState. *>
enum AgentState : char {
    INVALID,    // off the mesh
    WALKING,
    OFF_MESH,   // traversing an off-mesh connection
}

<* State of an agent's move request; mirrors MoveRequestState. *>
enum TargetState : char {
    NONE,
    FAILED,
    VALID,
    REQUESTING,
    WAITING_FOR_QUEUE,
    WAITING_FOR_PATH,
    VELOCITY,
}

<* Agent configuration; mirrors dtCrowdAgentParams. *>
struct NavAgentParams {
    float            radius;
    float            height;
    float            max_acceleration;
    float            max_speed;
    float            collision_query_range;      // neighbours and walls within it are avoided
    float            path_optimization_range;    // reach of the visibility shortcut
    float            separation_weight;
    AgentUpdateFlags update_flags;
    char             obstacle_avoidance_type;    // index into the crowd's avoidance configurations
    char             query_filter_type;          // index into the crowd's filters
}

<* A neighbouring agent. *>
struct AgentNeighbour {
    uint  index;
    float distance_sqr;    // XZ
}

<* Runtime agent of a crowd; mirrors dtCrowdAgent. *>
struct CrowdAgent {
    bool                                 active;
    bool                                 driven;              // the node owns the position; see NavAgent
    AgentState                           state;
    bool                                 partial;
    PathCorridor                         corridor;
    LocalBoundary                        boundary;
    float                                topology_optimization_time;
    AgentNeighbour[MAX_AGENT_NEIGHBOURS] neighbours;
    uint                                 neighbour_count;
    float                                desired_speed;
    Vec3                                 position;
    Vec3                                 displacement;        // collision resolution of one pass
    Vec3                                 desired_velocity;
    Vec3                                 planned_velocity;    // after avoidance
    Vec3                                 velocity;            // after the acceleration limit
    NavAgentParams                       params;
    StraightPoint[MAX_AGENT_CORNERS]     corners;
    uint                                 corner_count;
    TargetState                          target_state;
    PolyRef                              target_ref;
    Vec3                                 target_position;     // the velocity under TargetState.VELOCITY
    PathQueueRef                         target_path_request;
    bool                                 target_replan;
    float                                target_replan_time;
}

<* Off-mesh traversal in progress; mirrors dtCrowdAgentAnimation. *>
struct AgentAnimation {
    bool    active;
    Vec3    initial_position;
    Vec3    start;
    Vec3    end;
    PolyRef poly_ref;
    float   t;
    float   t_max;
}

<* Debug output for one agent; mirrors dtCrowdAgentDebugInfo. *>
struct CrowdDebugInfo {
    uint              index;
    Vec3              optimization_start;
    Vec3              optimization_end;
    AvoidanceSample[] samples;         // filled up to its length
    usz               sample_count;
}

<* Capacity of a crowd. *>
struct CrowdDesc {
    uint  max_agents;
    float max_agent_radius;
}

<* Crowd slots whose nodes lost their mirror since the last crowd_update; the remove hook's context. *>
struct AgentRemovalQueue {
    uint[] indices;    // max_agents; a slot is queued once per binding, so it never overflows
    uint   count;
}

<* Agents steered together over one mesh; mirrors dtCrowd. *>
struct Crowd {
    Allocator                                     allocator;
    Scene*                                        scene;              // carries the CrowdAgentRuntime remove hook
    AgentRemovalQueue*                            removals;
    Entity[]                                      orphan_scratch;     // max_agents
    uint                                          max_agents;
    CrowdAgent[]                                  agents;
    CrowdAgent*[]                                 active;
    AgentAnimation[]                              animations;
    PathQueue                                     path_queue;
    ObstacleAvoidanceParams[MAX_AVOIDANCE_PARAMS] avoidance_params;
    ObstacleAvoidanceQuery                        avoidance;
    ProximityGrid                                 grid;
    PolyRef[]                                     path_scratch;       // CROWD_MAX_PATH
    Vec3                                          placement_half_extents;
    QueryFilter[MAX_CROWD_FILTERS]                filters;
    float                                         max_agent_radius;
    uint                                          velocity_sample_count;
    uint                                          unbound;            // NavAgent nodes left without a slot
    NavQuery                                      query;
}

<*
 Traversal point at time t: toward start over the approach share, then along the connection.
 @pure
*>
fn Vec3 AgentAnimation.position_at(&self, float t) {
    float approach = self.t_max * TRAVERSAL_APPROACH_SHARE;
    if (t < approach) {
        float share = math::clamp(t / approach, 0.0f, 1.0f);
        return self.initial_position + (self.start - self.initial_position) * share;
    }
    float share = math::clamp((t - approach) / (self.t_max - approach), 0.0f, 1.0f);
    return self.start + (self.end - self.start) * share;
}

<*
 Replace one avoidance configuration.
 @require index < MAX_AVOIDANCE_PARAMS
*>
fn void Crowd.set_obstacle_avoidance_params(&self, uint index, ObstacleAvoidanceParams params) {
    self.avoidance_params[index] = params;
}

<*
 One avoidance configuration, editable.
 @require index < MAX_AVOIDANCE_PARAMS
*>
fn ObstacleAvoidanceParams* Crowd.obstacle_avoidance_params(&self, uint index) => &self.avoidance_params[index];

<*
 One of the crowd's filters, editable.
 @require index < MAX_CROWD_FILTERS
*>
fn QueryFilter* Crowd.filter(&self, uint index) => &self.filters[index];

<*
 An agent slot; an inactive slot has active false.
 @require index < self.max_agents
*>
fn CrowdAgent* Crowd.agent(&self, uint index) => &self.agents[index];

<*
 Add an agent at the nearest polygon to the position; mirrors addAgent.
 An agent with no polygon in reach starts INVALID at the position.
 @return "The agent's index."
 @return? c3d::CAPACITY_EXCEEDED
 @require params.query_filter_type < MAX_CROWD_FILTERS, params.obstacle_avoidance_type < MAX_AVOIDANCE_PARAMS
*>
fn uint? Crowd.add_agent(&self, Vec3 position, NavAgentParams params) {
    foreach (usz index, &agent : self.agents) {
        if (agent.active) continue;
        self.update_agent_params((uint)index, params);
        PolyRef ref;
        Vec3 placed = position;
        QueryFilter* filter = agent_filter(self, agent);
        NearestPoly? nearest = self.query.find_nearest_poly(position, self.placement_half_extents, filter);
        if (try nearest) {
            ref = nearest.ref;
            placed = nearest.point;
        }

        agent.corridor.reset(ref, placed);
        agent.boundary.reset();
        agent.partial = false;
        agent.topology_optimization_time = 0;
        agent.target_replan_time = 0;
        agent.neighbour_count = 0;
        agent.desired_velocity = {};
        agent.planned_velocity = {};
        agent.velocity = {};
        agent.position = placed;
        agent.desired_speed = 0;
        agent.state = ref ? WALKING : INVALID;
        agent.target_state = NONE;
        agent.corner_count = 0;
        agent.driven = false;
        agent.active = true;
        // A slot freed mid-traversal would otherwise carry its animation to the next agent.
        self.animations[index].active = false;
        return (uint)index;
    }
    return c3d::CAPACITY_EXCEEDED~;
}

<*
 Replace an agent's configuration; mirrors updateAgentParameters.
 @require index < self.max_agents
 @require params.query_filter_type < MAX_CROWD_FILTERS, params.obstacle_avoidance_type < MAX_AVOIDANCE_PARAMS
*>
fn void Crowd.update_agent_params(&self, uint index, NavAgentParams params) {
    self.agents[index].params = params;
}

<*
 Free an agent slot; mirrors removeAgent.
 @require index < self.max_agents
*>
fn void Crowd.remove_agent(&self, uint index) {
    self.agents[index].active = false;
}

<*
 Ask an agent to walk to a position; mirrors requestMoveTarget.
 @param ref : "Polygon of the position."
 @require index < self.max_agents, ref != (PolyRef)0
*>
fn void Crowd.request_move_target(
    &self,
    uint index,
    PolyRef ref,
    Vec3 position,
) {
    CrowdAgent* agent = &self.agents[index];
    agent.target_ref = ref;
    agent.target_position = position;
    agent.target_path_request = (PathQueueRef)0;
    agent.target_replan = false;
    agent.target_state = REQUESTING;
}

<*
 Ask an agent to move at a velocity; mirrors requestMoveVelocity.
 @require index < self.max_agents
*>
fn void Crowd.request_move_velocity(&self, uint index, Vec3 velocity) {
    CrowdAgent* agent = &self.agents[index];
    agent.target_ref = (PolyRef)0;
    agent.target_position = velocity;
    agent.target_path_request = (PathQueueRef)0;
    agent.target_replan = false;
    agent.target_state = VELOCITY;
}

<*
 Cancel an agent's request; mirrors resetMoveTarget.
 @require index < self.max_agents
*>
fn void Crowd.reset_move_target(&self, uint index) {
    CrowdAgent* agent = &self.agents[index];
    agent.target_ref = (PolyRef)0;
    agent.target_position = {};
    agent.desired_velocity = {};
    agent.target_path_request = (PathQueueRef)0;
    agent.target_replan = false;
    agent.target_state = NONE;
}

<*
 Active agents in slot order.
 @param [out] out_agents : "Filled up to its length."
 @return "How many were written."
*>
fn usz Crowd.active_agents(&self, CrowdAgent*[] out_agents) {
    usz count;
    foreach (&agent : self.agents) {
        if (agent.active && count < out_agents.len) out_agents[count++] = agent;
    }
    return count;
}

<*
 Plan, steer, avoid and integrate every active agent; mirrors update.
 A driven agent keeps the position crowd_update read from its node.
 @param [inout] debug : "Filled for the agent it names; null for none."
 @require dt > 0
*>
fn void Crowd.update(&self, float dt, CrowdDebugInfo* debug = null) {
    self.velocity_sample_count = 0;
    CrowdAgent*[] agents = self.active[:self.active_agents(self.active)];

    check_path_validity(self, agents, dt);
    update_move_requests(self);
    update_topology_optimization(self, agents, dt);
    register_agents(self, agents);
    update_neighbourhoods(self, agents);
    update_corners(self, agents, debug);
    trigger_off_mesh_connections(self, agents);
    update_steering(self, agents);
    plan_velocities(self, agents, debug);
    integrate_agents(agents, dt);
    resolve_collisions(self, agents);
    move_agents(self, agents);
    update_traversals(self, agents, dt);
}

<*
 Move every agent, corridor, boundary, traversal and queued path request by the negated offset.
 @require offset.y == 0
*>
fn void Crowd.shift_origin(&self, Vec3 offset) {
    foreach (&agent : self.agents) {
        if (!agent.active) continue;
        agent.position -= offset;
        agent.corridor.position -= offset;
        agent.corridor.target -= offset;
        foreach (&corner : agent.corners[:agent.corner_count]) corner.position -= offset;
        if (agent.target_state != VELOCITY) agent.target_position -= offset;
        if (agent.boundary.center.x != float::max) {
            agent.boundary.center -= offset;
            foreach (&segment : agent.boundary.segments[:agent.boundary.segment_count]) {
                segment.start -= offset;
                segment.end -= offset;
            }
        }
    }
    foreach (&animation : self.animations) {
        if (!animation.active) continue;
        animation.initial_position -= offset;
        animation.start -= offset;
        animation.end -= offset;
    }
    foreach (&request : self.path_queue.queue) {
        if (!request.ref) continue;
        request.start -= offset;
        request.end -= offset;
    }
    self.path_queue.query.shift_origin(offset);
    self.query.shift_origin(offset);
}

<* Half extents used to place and recover agents on the mesh. *>
fn Vec3 Crowd.query_half_extents(&self) => self.placement_half_extents;

<*
 Crowd for max_agents over the mesh, with every array allocated here; mirrors dtCrowd::init.
 One crowd per scene: it owns the CrowdAgentRuntime remove hook.
 @param [&in] mesh : "Outlives the crowd."
 @param [&inout] scene : "Gains the CrowdAgentRuntime remove hook; outlives the crowd."
 @return? c3d::CAPACITY_EXCEEDED
 @require desc.max_agents > 0 && desc.max_agents <= MAX_CROWD_AGENTS, desc.max_agent_radius > 0
 @require scene.world.is_registered(CrowdAgentRuntime)
*>
fn Crowd? create_crowd(
    Allocator allocator,
    CrowdDesc desc,
    NavMesh* mesh,
    Scene* scene,
) {
    AgentRemovalQueue*? removals = alloc::new_try(allocator, AgentRemovalQueue);
    if (catch removals) return c3d::CAPACITY_EXCEEDED~;
    float radius = desc.max_agent_radius;
    Crowd crowd = {
        .allocator              = allocator,
        .scene                  = scene,
        .removals               = removals,
        .max_agents             = desc.max_agents,
        .max_agent_radius       = radius,
        .placement_half_extents = PLACEMENT_RADII * radius,
    };
    defer catch destroy_crowd(&crowd);

    crowd.grid = create_proximity_grid(allocator, desc.max_agents * GRID_ITEMS_PER_AGENT, radius * GRID_CELL_RADII)!;
    crowd.avoidance = create_obstacle_avoidance_query(allocator, AVOIDANCE_CIRCLES, AVOIDANCE_SEGMENTS)!;
    crowd.avoidance_params[..] = default_obstacle_avoidance_params();
    crowd.path_queue = create_path_queue(
        allocator:     allocator,
        max_path_size: CROWD_MAX_PATH,
        max_nodes:     CROWD_PATH_QUEUE_NODES,
        mesh:          mesh,
    )!;
    crowd.query = create_nav_query(allocator, mesh, CROWD_QUERY_NODES)!;
    crowd.filters[..] = default_query_filter();

    PolyRef[]? path_scratch = alloc::new_array_try(allocator, PolyRef, (sz)CROWD_MAX_PATH);
    if (catch path_scratch) return c3d::CAPACITY_EXCEEDED~;
    crowd.path_scratch = path_scratch;
    CrowdAgent[]? agents = alloc::new_array_try(allocator, CrowdAgent, desc.max_agents);
    if (catch agents) return c3d::CAPACITY_EXCEEDED~;
    crowd.agents = agents;
    CrowdAgent*[]? active = alloc::new_array_try(allocator, CrowdAgent*, desc.max_agents);
    if (catch active) return c3d::CAPACITY_EXCEEDED~;
    crowd.active = active;
    AgentAnimation[]? animations = alloc::new_array_try(allocator, AgentAnimation, desc.max_agents);
    if (catch animations) return c3d::CAPACITY_EXCEEDED~;
    crowd.animations = animations;
    Entity[]? orphans = alloc::new_array_try(allocator, Entity, desc.max_agents);
    if (catch orphans) return c3d::CAPACITY_EXCEEDED~;
    crowd.orphan_scratch = orphans;
    uint[]? queued = alloc::new_array_try(allocator, uint, desc.max_agents);
    if (catch queued) return c3d::CAPACITY_EXCEEDED~;
    removals.indices = queued;
    foreach (&agent : agents) agent.corridor = create_path_corridor(allocator, CROWD_MAX_PATH)!;

    scene.set_remove_hook(CrowdAgentRuntime, &queue_removed_agent, removals);
    return crowd;
}

<*
 Clear the remove hook, then free every agent, the queue, the grid and the queries.
 @param [&inout] crowd : "Left zeroed."
*>
fn void destroy_crowd(Crowd* crowd) {
    Allocator allocator = crowd.allocator;
    crowd.scene.set_remove_hook(CrowdAgentRuntime, null, null);
    foreach (&agent : crowd.agents) destroy_path_corridor(&agent.corridor);
    destroy_path_queue(&crowd.path_queue);
    destroy_obstacle_avoidance_query(&crowd.avoidance);
    destroy_proximity_grid(&crowd.grid);
    destroy_nav_query(&crowd.query);
    alloc::free(allocator, crowd.path_scratch.ptr);
    alloc::free(allocator, crowd.agents.ptr);
    alloc::free(allocator, crowd.active.ptr);
    alloc::free(allocator, crowd.animations.ptr);
    alloc::free(allocator, crowd.orphan_scratch.ptr);
    alloc::free(allocator, crowd.removals.indices.ptr);
    alloc::free(allocator, crowd.removals);
    *crowd = {};
}

<*
 Default agent of the default build's size, with every behaviour on and slot 0 settings.
*>
fn NavAgentParams default_nav_agent_params() {
    return {
        .radius                  = DEFAULT_AGENT_RADIUS,
        .height                  = DEFAULT_AGENT_HEIGHT,
        .max_acceleration        = DEFAULT_AGENT_ACCELERATION,
        .max_speed               = DEFAULT_AGENT_SPEED,
        .collision_query_range   = DEFAULT_AGENT_RADIUS * COLLISION_RANGE_RADII,
        .path_optimization_range = DEFAULT_AGENT_RADIUS * OPTIMIZATION_RANGE_RADII,
        .separation_weight       = DEFAULT_SEPARATION_WEIGHT,
        .update_flags            = {
            .anticipate_turns    = true,
            .obstacle_avoidance  = true,
            .separation          = true,
            .optimize_visibility = true,
            .optimize_topology   = true,
        },
    };
}

fn QueryFilter* agent_filter(Crowd* crowd, CrowdAgent* agent) @private {
    return &crowd.filters[agent.params.query_filter_type];
}

fn uint agent_index(Crowd* crowd, CrowdAgent* agent) @local => (uint)(agent - crowd.agents.ptr);

fn bool follows_path(CrowdAgent* agent) @local => agent.target_state != NONE && agent.target_state != VELOCITY;

fn void queue_removed_agent(Entity entity, void* component, void* user) @local {
    AgentRemovalQueue* removals = user;
    removals.indices[removals.count++] = ((CrowdAgentRuntime*)component).index;
}

// Mirrors requestMoveTargetReplan: a zero ref fails the request.
fn void request_move_target_replan(CrowdAgent* agent, PolyRef ref, Vec3 position) @local {
    agent.target_ref = ref;
    agent.target_position = position;
    agent.target_path_request = (PathQueueRef)0;
    agent.target_replan = true;
    agent.target_state = ref ? REQUESTING : FAILED;
}

// Mirrors checkPathValidity: recovers agents and targets whose polygons left, and replans broken corridors.
fn void check_path_validity(Crowd* crowd, CrowdAgent*[] agents, float dt) @local {
    foreach (agent : agents) {
        if (agent.state != WALKING) continue;
        agent.target_replan_time += dt;
        QueryFilter* filter = agent_filter(crowd, agent);
        bool replan;

        PolyRef agent_ref = agent.corridor.first_poly();
        Vec3 agent_position = agent.position;
        if (!crowd.query.is_valid_ref(agent_ref, filter)) {
            NearestPoly? nearest = crowd.query.find_nearest_poly(agent.position, crowd.placement_half_extents, filter);
            if (catch nearest) {
                agent.corridor.reset((PolyRef)0, agent_position);
                agent.partial = false;
                agent.boundary.reset();
                agent.state = INVALID;
                continue;
            }
            agent_ref = nearest.ref;
            agent_position = nearest.point;
            // Only the start is fixed; the rest of the corridor guides the replan.
            agent.corridor.fix_path_start(agent_ref, agent_position);
            agent.boundary.reset();
            agent.position = agent_position;
            replan = true;
        }

        if (!follows_path(agent)) continue;
        if (agent.target_state != FAILED) {
            if (!crowd.query.is_valid_ref(agent.target_ref, filter)) {
                agent.target_ref = (PolyRef)0;
                NearestPoly? target = crowd.query.find_nearest_poly(
                    agent.target_position,
                    crowd.placement_half_extents,
                    filter,
                );
                if (try target) {
                    agent.target_ref = target.ref;
                    agent.target_position = target.point;
                }
                replan = true;
            }
            if (!agent.target_ref) {
                agent.corridor.reset(agent_ref, agent_position);
                agent.partial = false;
                agent.target_state = NONE;
            }
        }

        if (!agent.corridor.is_valid(CHECK_LOOKAHEAD, &crowd.query, filter)) replan = true;
        // A corridor about to end short of its target is extended.
        if (agent.target_state == VALID && agent.target_replan_time > TARGET_REPLAN_DELAY
            && agent.corridor.count < CHECK_LOOKAHEAD && agent.corridor.last_poly() != agent.target_ref) {
            replan = true;
        }
        if (replan && agent.target_state != NONE) {
            request_move_target_replan(agent, agent.target_ref, agent.target_position);
        }
    }
}

// Mirrors updateMoveRequest: a quick search per new request, the path queue for the rest, then the results.
fn void update_move_requests(Crowd* crowd) @local {
    CrowdAgent*[PATH_REQUESTS_PER_UPDATE] queue;
    usz queued;
    foreach (&agent : crowd.agents) {
        if (!agent.active || agent.state == INVALID || !follows_path(agent)) continue;
        if (agent.target_state == REQUESTING) start_move_request(crowd, agent);
        if (agent.target_state == WAITING_FOR_QUEUE) {
            queued = insert_by_replan_time(queue[..], queued, agent);
        }
    }

    foreach (agent : queue[:queued]) {
        agent.target_path_request = crowd.path_queue.request(
            start_ref: agent.corridor.last_poly(),
            end_ref:   agent.target_ref,
            start:     agent.corridor.target,
            end:       agent.target_position,
            filter:    agent_filter(crowd, agent),
        );
        if (agent.target_path_request) agent.target_state = WAITING_FOR_PATH;
    }

    crowd.path_queue.update(CROWD_PATH_ITERATIONS);

    foreach (&agent : crowd.agents) {
        if (!agent.active || agent.target_state != WAITING_FOR_PATH) continue;
        switch (crowd.path_queue.request_state(agent.target_path_request)) {
            case FAILED:
                // Retried while the target polygon stands.
                agent.target_path_request = (PathQueueRef)0;
                agent.target_state = agent.target_ref ? REQUESTING : FAILED;
                agent.target_replan_time = 0;
            case DONE:
                apply_queued_path(crowd, agent);
            case PENDING:
            case IN_PROGRESS:
                break;
        }
    }
}

// Mirrors the requesting branch of updateMoveRequest.
fn void start_move_request(Crowd* crowd, CrowdAgent* agent) @local {
    QueryFilter* filter = agent_filter(crowd, agent);
    PolyRef[] path = agent.corridor.polys();
    PolyRef[QUICK_SEARCH_POLYS] request_path;
    usz request_count;
    Vec3 request_position;

    // A failed start or update leaves nothing to finalize, which the finalize reports.
    (void)crowd.query.init_sliced_find_path(
        start_ref: path[0],
        end_ref:   agent.target_ref,
        start:     agent.position,
        end:       agent.target_position,
        filter:    filter,
    );
    (void)crowd.query.update_sliced_find_path(QUICK_SEARCH_ITERATIONS);
    // A replan keeps as much of the steady corridor as the search reached.
    PathResult? found = agent.target_replan
        ? crowd.query.finalize_sliced_find_path_partial(path, request_path[..])
        : crowd.query.finalize_sliced_find_path(request_path[..]);
    if (try found) request_count = found.count;
    if (request_count) {
        PolyRef last = request_path[request_count - 1];
        if (last != agent.target_ref) {
            ClosestPoint? closest = crowd.query.closest_point_on_poly(last, agent.target_position);
            if (catch closest) {
                request_count = 0;
            } else {
                request_position = closest.point;
            }
        } else {
            request_position = agent.target_position;
        }
    }
    if (!request_count) {
        request_position = agent.position;
        request_path[0] = path[0];
        request_count = 1;
    }

    agent.corridor.set_corridor(request_position, request_path[:request_count]);
    agent.boundary.reset();
    agent.partial = false;
    if (request_path[request_count - 1] == agent.target_ref) {
        agent.target_state = VALID;
        agent.target_replan_time = 0;
    } else {
        agent.target_state = WAITING_FOR_QUEUE;
    }
}

// Mirrors the result branch of updateMoveRequest: the queued path joins the corridor at its last polygon.
fn void apply_queued_path(Crowd* crowd, CrowdAgent* agent) @local {
    PolyRef[] path = agent.corridor.polys();
    PolyRef[] result = crowd.path_scratch;
    Vec3 target_position = agent.target_position;
    agent.target_replan_time = 0;

    PathResult? queued = crowd.path_queue.path_result(agent.target_path_request, result);
    agent.partial = false;
    usz count;
    if (try queued) {
        agent.partial = queued.partial;
        count = queued.count;
    }
    // The request started at the corridor's last polygon; a moved corridor no longer joins it.
    if (!count || path[^1] != result[0]) {
        agent.target_state = FAILED;
        return;
    }

    if (path.len > 1) {
        usz kept = path.len - 1;
        if (kept + count > result.len) count = result.len - kept;
        mem::move(&result[kept], &result[0], (sz)count * (sz)PolyRef::size);
        result[:kept] = path[:kept];
        count += kept;
        count = remove_trackbacks(result, count);
    }

    if (result[count - 1] != agent.target_ref) {
        ClosestPoint? nearest = crowd.query.closest_point_on_poly(result[count - 1], target_position);
        if (catch nearest) {
            agent.target_state = FAILED;
            return;
        }
        target_position = nearest.point;
    }
    agent.corridor.set_corridor(target_position, result[:count]);
    agent.boundary.reset();
    agent.target_state = VALID;
}

// Mirrors the trackback removal: A B A becomes A.
fn usz remove_trackbacks(PolyRef[] path, usz count) @local {
    for (sz index = 1; index + 1 < (sz)count; index++) {
        if (path[index - 1] != path[index + 1]) continue;
        usz after = (usz)index + 1;
        mem::move(&path[index - 1], &path[after], (sz)(count - after) * (sz)PolyRef::size);
        count -= 2;
        index = math::max(index - 2, (sz)0);
    }
    return count;
}

// Mirrors addToPathQueue: the longest-waiting agents first, up to the queue's length.
fn usz insert_by_replan_time(CrowdAgent*[] queue, usz count, CrowdAgent* agent) @local {
    usz slot = count;
    if (count && agent.target_replan_time > queue[count - 1].target_replan_time) {
        slot = 0;
        while (slot < count && agent.target_replan_time < queue[slot].target_replan_time) slot++;
        usz moved = math::min(count - slot, queue.len - slot - 1);
        for (usz index = moved; index > 0; index--) queue[slot + index] = queue[slot + index - 1];
    } else if (count >= queue.len) {
        return count;
    }
    queue[slot] = agent;
    return math::min(count + 1, (usz)queue.len);
}

// Mirrors addToOptQueue: the agents longest without an optimisation first.
fn usz insert_by_optimization_time(CrowdAgent*[] queue, usz count, CrowdAgent* agent) @local {
    usz slot = count;
    if (count && agent.topology_optimization_time > queue[count - 1].topology_optimization_time) {
        slot = 0;
        while (slot < count && agent.topology_optimization_time < queue[slot].topology_optimization_time) slot++;
        usz moved = math::min(count - slot, queue.len - slot - 1);
        for (usz index = moved; index > 0; index--) queue[slot + index] = queue[slot + index - 1];
    } else if (count >= queue.len) {
        return count;
    }
    queue[slot] = agent;
    return math::min(count + 1, (usz)queue.len);
}

// Mirrors updateTopologyOptimization: one agent per update replans its corridor's start.
fn void update_topology_optimization(Crowd* crowd, CrowdAgent*[] agents, float dt) @local {
    CrowdAgent*[TOPOLOGY_AGENTS_PER_UPDATE] queue;
    usz queued;
    foreach (agent : agents) {
        if (agent.state != WALKING || !follows_path(agent) || !agent.params.update_flags.optimize_topology) continue;
        agent.topology_optimization_time += dt;
        if (agent.topology_optimization_time >= TOPOLOGY_OPTIMIZATION_TIME) {
            queued = insert_by_optimization_time(queue[..], queued, agent);
        }
    }
    foreach (agent : queue[:queued]) {
        agent.corridor.optimize_path_topology(&crowd.query, agent_filter(crowd, agent));
        agent.topology_optimization_time = 0;
    }
}

// Grid ids are indices into this update's active list.
fn void register_agents(Crowd* crowd, CrowdAgent*[] agents) @local {
    crowd.grid.clear();
    foreach (usz index, agent : agents) {
        float radius = agent.params.radius;
        crowd.grid.add_item(
            id:    (ushort)index,
            min_x: agent.position.x - radius,
            min_z: agent.position.z - radius,
            max_x: agent.position.x + radius,
            max_z: agent.position.z + radius,
        );
    }
}

// Mirrors the boundary and neighbour pass of update.
fn void update_neighbourhoods(Crowd* crowd, CrowdAgent*[] agents) @local {
    foreach (agent : agents) {
        if (agent.state != WALKING) continue;
        QueryFilter* filter = agent_filter(crowd, agent);
        float refresh = agent.params.collision_query_range * BOUNDARY_REFRESH_SHARE;
        if (distance_sqr_2d(agent.position, agent.boundary.center) > refresh * refresh
            || !agent.boundary.is_valid(&crowd.query, filter)) {
            agent.boundary.update(
                ref:                   agent.corridor.first_poly(),
                position:              agent.position,
                collision_query_range: agent.params.collision_query_range,
                query:                 &crowd.query,
                filter:                filter,
            );
        }
        agent.neighbour_count = gather_neighbours(crowd, agent, agents);
        foreach (&neighbour : agent.neighbours[:agent.neighbour_count]) {
            neighbour.index = agent_index(crowd, agents[neighbour.index]);
        }
    }
}

// Mirrors getNeighbours: indices into the active list, nearest first.
fn uint gather_neighbours(Crowd* crowd, CrowdAgent* agent, CrowdAgent*[] agents) @local {
    float range = agent.params.collision_query_range;
    ushort[MAX_GRID_NEIGHBOURS] ids;
    usz found = crowd.grid.query_items(
        min_x:   agent.position.x - range,
        min_z:   agent.position.z - range,
        max_x:   agent.position.x + range,
        max_z:   agent.position.z + range,
        out_ids: ids[..],
    );

    uint count;
    foreach (id : ids[:found]) {
        CrowdAgent* other = agents[id];
        if (other == agent) continue;
        Vec3 offset = agent.position - other.position;
        if (math::abs(offset.y) >= (agent.params.height + other.params.height) * 0.5f) continue;
        offset.y = 0;
        float distance_sqr = offset.length_sq();
        if (distance_sqr > range * range) continue;
        count = insert_neighbour(&agent.neighbours, count, id, distance_sqr);
    }
    return count;
}

// Mirrors addNeighbour: nearest first; a full list drops the furthest.
fn uint insert_neighbour(
    AgentNeighbour[MAX_AGENT_NEIGHBOURS]* neighbours,
    uint count,
    uint index,
    float distance_sqr,
) @local {
    uint slot = count;
    if (count && distance_sqr < (*neighbours)[count - 1].distance_sqr) {
        slot = 0;
        while (slot < count && distance_sqr > (*neighbours)[slot].distance_sqr) slot++;
        uint moved = math::min(count - slot, MAX_AGENT_NEIGHBOURS - slot - 1);
        for (uint entry = moved; entry > 0; entry--) (*neighbours)[slot + entry] = (*neighbours)[slot + entry - 1];
    } else if (count >= MAX_AGENT_NEIGHBOURS) {
        return count;
    }
    (*neighbours)[slot] = { .index = index, .distance_sqr = distance_sqr };
    return math::min(count + 1, MAX_AGENT_NEIGHBOURS);
}

// Mirrors the corner pass of update, with the visibility shortcut to the corner after next.
fn void update_corners(Crowd* crowd, CrowdAgent*[] agents, CrowdDebugInfo* debug) @local {
    foreach (agent : agents) {
        if (agent.state != WALKING || !follows_path(agent)) continue;
        agent.corner_count = (uint)agent.corridor.find_corners(agent.corners[..], &crowd.query);
        bool debugged = debug && debug.index == agent_index(crowd, agent);
        if (!agent.params.update_flags.optimize_visibility || !agent.corner_count) {
            if (debugged) {
                debug.optimization_start = {};
                debug.optimization_end = {};
            }
            continue;
        }
        Vec3 target = agent.corners[math::min(1u, agent.corner_count - 1)].position;
        agent.corridor.optimize_path_visibility(
            next:   target,
            range:  agent.params.path_optimization_range,
            query:  &crowd.query,
            filter: agent_filter(crowd, agent),
        );
        if (debugged) {
            debug.optimization_start = agent.corridor.position;
            debug.optimization_end = target;
        }
    }
}

// Mirrors the off-mesh trigger pass of update.
fn void trigger_off_mesh_connections(Crowd* crowd, CrowdAgent*[] agents) @local {
    foreach (agent : agents) {
        if (agent.state != WALKING || !follows_path(agent)) continue;
        if (!over_off_mesh_connection(agent, agent.params.radius * OFF_MESH_TRIGGER_RADII)) continue;
        // A blocked connection stays in the corridor; the validity check replans it.
        OffMeshCrossing? crossing = agent.corridor.move_over_off_mesh_connection(
            agent.corners[agent.corner_count - 1].ref,
            &crowd.query,
        );
        if (catch crossing) continue;
        AgentAnimation* animation = &crowd.animations[agent_index(crowd, agent)];
        *animation = {
            .active           = true,
            .initial_position = agent.position,
            .start            = crossing.start,
            .end              = crossing.end,
            .poly_ref         = crossing.refs[1],
            .t_max            = math::sqrt(distance_sqr_2d(crossing.start, crossing.end)) / agent.params.max_speed
                * TRAVERSAL_TIME_SCALE,
        };
        agent.state = OFF_MESH;
        agent.corner_count = 0;
        agent.neighbour_count = 0;
    }
}

fn bool over_off_mesh_connection(CrowdAgent* agent, float radius) @local {
    if (!agent.corner_count) return false;
    StraightPoint last = agent.corners[agent.corner_count - 1];
    return last.flags.off_mesh_connection && distance_sqr_2d(agent.position, last.position) < radius * radius;
}

// Mirrors the steering pass of update: toward the corners, slowing at the goal, pushed apart by separation.
fn void update_steering(Crowd* crowd, CrowdAgent*[] agents) @local {
    foreach (agent : agents) {
        if (agent.state != WALKING || agent.target_state == NONE) continue;
        Vec3 desired;
        if (agent.target_state == VELOCITY) {
            desired = agent.target_position;
            agent.desired_speed = agent.target_position.length();
        } else {
            bool anticipate = agent.params.update_flags.anticipate_turns;
            desired = anticipate ? smooth_steer_direction(agent) : straight_steer_direction(agent);
            float slow_down_radius = agent.params.radius * SLOW_DOWN_RADII;
            float speed_scale = distance_to_goal(agent, slow_down_radius) / slow_down_radius;
            agent.desired_speed = agent.params.max_speed;
            desired *= agent.desired_speed * speed_scale;
        }
        if (agent.params.update_flags.separation) desired = separate(crowd, agent, desired);
        agent.desired_velocity = desired;
    }
}

fn Vec3 separate(Crowd* crowd, CrowdAgent* agent, Vec3 desired) @local {
    float separation_distance = agent.params.collision_query_range;
    float inverse_distance = 1.0f / separation_distance;
    float weight_sum = 0;
    Vec3 push;
    foreach (neighbour : agent.neighbours[:agent.neighbour_count]) {
        Vec3 offset = agent.position - crowd.agents[neighbour.index].position;
        offset.y = 0;
        float distance_sqr = offset.length_sq();
        if (distance_sqr < MIN_SEPARATION_DISTANCE_SQR) continue;
        if (distance_sqr > separation_distance * separation_distance) continue;
        float distance = math::sqrt(distance_sqr);
        float falloff = distance * inverse_distance;
        float weight = agent.params.separation_weight * (1.0f - falloff * falloff);
        push += offset * (weight / distance);
        weight_sum += 1.0f;
    }
    if (weight_sum <= MIN_WEIGHT) return desired;

    desired += push * (1.0f / weight_sum);
    float speed_sqr = desired.length_sq();
    float desired_sqr = agent.desired_speed * agent.desired_speed;
    // Upstream scales by the squared ratio, which slows more than a clamp.
    if (speed_sqr > desired_sqr) desired *= desired_sqr / speed_sqr;
    return desired;
}

fn Vec3 smooth_steer_direction(CrowdAgent* agent) @local {
    if (!agent.corner_count) return {};
    Vec3 first = agent.corners[0].position - agent.position;
    Vec3 second = agent.corners[math::min(1u, agent.corner_count - 1)].position - agent.position;
    first.y = 0;
    second.y = 0;
    float first_length = first.length();
    float second_length = second.length();
    if (second_length > MIN_TURN_LENGTH) second *= 1.0f / second_length;
    Vec3 direction = { first.x - second.x * first_length * 0.5f, 0, first.z - second.z * first_length * 0.5f };
    return direction.normalize();
}

fn Vec3 straight_steer_direction(CrowdAgent* agent) @local {
    if (!agent.corner_count) return {};
    Vec3 direction = agent.corners[0].position - agent.position;
    direction.y = 0;
    return direction.normalize();
}

fn float distance_to_goal(CrowdAgent* agent, float range) @local {
    if (!agent.corner_count) return range;
    StraightPoint last = agent.corners[agent.corner_count - 1];
    if (!last.flags.end) return range;
    return math::min(math::sqrt(distance_sqr_2d(agent.position, last.position)), range);
}

// Mirrors the velocity planning pass of update; upstream always samples adaptively.
fn void plan_velocities(Crowd* crowd, CrowdAgent*[] agents, CrowdDebugInfo* debug) @local {
    foreach (agent : agents) {
        if (agent.state != WALKING) continue;
        if (!agent.params.update_flags.obstacle_avoidance) {
            agent.planned_velocity = agent.desired_velocity;
            continue;
        }

        ObstacleAvoidanceQuery* avoidance = &crowd.avoidance;
        avoidance.reset();
        foreach (neighbour : agent.neighbours[:agent.neighbour_count]) {
            CrowdAgent* other = &crowd.agents[neighbour.index];
            avoidance.add_circle(
                position:         other.position,
                radius:           other.params.radius,
                velocity:         other.velocity,
                desired_velocity: other.desired_velocity,
            );
        }
        foreach (segment : agent.boundary.segments[:agent.boundary.segment_count]) {
            // Walls the agent stands behind face away from it.
            if (tri_area_2d(agent.position, segment.start, segment.end) < 0) continue;
            avoidance.add_segment(segment.start, segment.end);
        }

        bool debugged = debug && debug.index == agent_index(crowd, agent);
        SampledVelocity sampled = avoidance.sample_velocity_adaptive(
            position:         agent.position,
            radius:           agent.params.radius,
            max_velocity:     agent.desired_speed,
            velocity:         agent.velocity,
            desired_velocity: agent.desired_velocity,
            params:           &crowd.avoidance_params[agent.params.obstacle_avoidance_type],
            out_samples:      debugged ? debug.samples : {},
        );
        if (debugged) debug.sample_count = sampled.recorded;
        agent.planned_velocity = sampled.velocity;
        crowd.velocity_sample_count += sampled.samples;
    }
}

// Mirrors integrate; a driven agent's node integrates its own position.
fn void integrate_agents(CrowdAgent*[] agents, float dt) @local {
    foreach (agent : agents) {
        if (agent.state != WALKING) continue;
        float max_delta = agent.params.max_acceleration * dt;
        Vec3 change = agent.planned_velocity - agent.velocity;
        float change_length = change.length();
        if (change_length > max_delta) change *= max_delta / change_length;
        agent.velocity += change;
        if (agent.velocity.length() <= MIN_INTEGRATION_SPEED) {
            agent.velocity = {};
        } else if (!agent.driven) {
            agent.position += agent.velocity * dt;
        }
    }
}

// Mirrors the collision passes of update: each pass pushes overlapping agents apart by part of the overlap.
fn void resolve_collisions(Crowd* crowd, CrowdAgent*[] agents) @local {
    for (uint pass = 0; pass < COLLISION_ITERATIONS; pass++) {
        foreach (agent : agents) {
            if (agent.state != WALKING || agent.driven) continue;
            agent.displacement = collision_displacement(crowd, agent);
        }
        foreach (agent : agents) {
            if (agent.state != WALKING || agent.driven) continue;
            agent.position += agent.displacement;
        }
    }
}

fn Vec3 collision_displacement(Crowd* crowd, CrowdAgent* agent) @local {
    uint own_index = agent_index(crowd, agent);
    Vec3 displacement;
    float weight_sum = 0;
    foreach (neighbour : agent.neighbours[:agent.neighbour_count]) {
        CrowdAgent* other = &crowd.agents[neighbour.index];
        Vec3 offset = agent.position - other.position;
        offset.y = 0;
        float combined = agent.params.radius + other.params.radius;
        float distance_sqr = offset.length_sq();
        if (distance_sqr > combined * combined) continue;
        float distance = math::sqrt(distance_sqr);
        float penetration;
        if (distance < COINCIDENT_DISTANCE) {
            // Coincident agents pick opposite sides of their desired motion.
            if (own_index > neighbour.index) {
                offset = { -agent.desired_velocity.z, 0, agent.desired_velocity.x };
            } else {
                offset = { agent.desired_velocity.z, 0, -agent.desired_velocity.x };
            }
            penetration = COINCIDENT_PENETRATION;
        } else {
            penetration = (1.0f / distance) * ((combined - distance) * 0.5f) * COLLISION_RESOLVE_FACTOR;
        }
        displacement += offset * penetration;
        weight_sum += 1.0f;
    }
    if (weight_sum > MIN_WEIGHT) displacement *= 1.0f / weight_sum;
    return displacement;
}

// Mirrors the move pass of update; a driven agent's corridor follows its node.
fn void move_agents(Crowd* crowd, CrowdAgent*[] agents) @local {
    foreach (agent : agents) {
        if (agent.state != WALKING) continue;
        // A corridor whose start polygon left is recovered by the next validity check.
        (void)agent.corridor.move_position(agent.position, &crowd.query, agent_filter(crowd, agent));
        if (!agent.driven) agent.position = agent.corridor.position;
        if (!follows_path(agent)) {
            agent.corridor.reset(agent.corridor.first_poly(), agent.corridor.position);
            agent.partial = false;
        }
    }
}

// Mirrors the off-mesh animation pass of update: to the connection's start, then across it.
fn void update_traversals(Crowd* crowd, CrowdAgent*[] agents, float dt) @local {
    foreach (agent : agents) {
        AgentAnimation* animation = &crowd.animations[agent_index(crowd, agent)];
        if (!animation.active) continue;
        animation.t += dt;
        if (animation.t > animation.t_max) {
            animation.active = false;
            agent.state = WALKING;
            continue;
        }
        agent.position = animation.position_at(animation.t);
        agent.velocity = {};
        agent.desired_velocity = {};
    }
}
