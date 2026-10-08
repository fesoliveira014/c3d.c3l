module c3d::nav;

import std::math;
import c3d;
import c3d::maths;
import c3d::scene;

<* What an agent is asked to do. *>
enum AgentTargetKind : char {
    NONE,
    POSITION,
    VELOCITY,
}

<* Geometry rasterized into the navmesh; walkable or obstacle, placed by the node's world matrix. *>
struct NavSource {
    GeometryId geometry;    // the zero id names the node's Mesh geometry
    bool       walkable;    // false rasterizes every triangle as NULL_AREA
    char       area;        // area id given to walkable triangles
    bool       changed;
}

<* Area marking volume in node space; the node's world matrix places it. *>
struct NavVolume {
    VolumeKind             kind;
    char                   area;
    Aabb                   box;       // BOX
    Vec3[MAX_VOLUME_VERTS] verts;     // CONVEX; Y ignored
    uint                   vert_count;
    float                  min_y;     // CONVEX
    float                  max_y;
    Vec3                   base;      // CYLINDER
    float                  radius;
    float                  height;
    bool                   changed;
}

<* Off-mesh connection authored on a node; endpoints in node space. *>
struct NavLink {
    Vec3   start;
    Vec3   end;
    float  radius;           // metres around each endpoint searched for a landing polygon
    bool   bidirectional;
    char   area;
    ushort flags;            // POLY_FLAG_WALK when authored as 0
    uint   user_id;
    bool   changed;
}

<* Obstacle in node space; the node's world matrix places it when added or changed. *>
struct NavObstacle {
    ObstacleKind kind;
    Vec3         position;       // CYLINDER base; ORIENTED_BOX centre
    float        radius;         // CYLINDER
    float        height;
    Aabb         box;            // BOX
    Vec3         half_extents;   // ORIENTED_BOX; turned by the node's yaw
    bool         changed;
}

<* Agent authored on a node; the crowd steers the node unless driven. *>
struct NavAgent {
    NavAgentParams  params;
    AgentTargetKind target_kind;
    Vec3            target;         // world position, or velocity
    bool            driven;         // the node owns the position; the crowd steers through CrowdAgent.velocity
    bool            changed;        // params or target changed since the last crowd_update
}

<* Runtime mirror of a NavSource: dirtied world bounds and the geometry revision they came from. *>
struct NavSourceRuntime {
    Aabb bounds;
    uint geometry_revision;
}

<* Runtime mirror of a NavVolume: its world bounds and world-space record. *>
struct NavVolumeRuntime {
    Aabb         bounds;
    VolumeRecord record;
}

<* Runtime mirror of a NavLink: its world endpoints as built into tiles. *>
struct NavLinkRuntime {
    Vec3 start;
    Vec3 end;
}

<* Runtime mirror of a NavObstacle: the cache obstacle it holds. *>
struct NavObstacleRuntime {
    ObstacleRef ref;    // 0 while no addition is queued
}

<* Runtime mirror of a NavAgent: its crowd slot. *>
struct CrowdAgentRuntime {
    uint index;
}

<*
 Request a rebuild of the tiles under the old and new bounds on the next sync.
 Moving the node or editing the geometry does nothing until this is called.
*>
fn void NavSource.mark_changed(&self) {
    self.changed = true;
}

<*
 Request a rebuild, or a relayer with cached layers, of the tiles under the old and new bounds on the next sync.
 Moving the node does nothing until this is called.
*>
fn void NavVolume.mark_changed(&self) {
    self.changed = true;
}

<*
 Request a relink of the tiles under the old and new endpoints on the next sync.
 Moving the node or editing the link does nothing until this is called.
*>
fn void NavLink.mark_changed(&self) {
    self.changed = true;
}

<*
 Request re-adding the obstacle at the node's current world matrix on the next sync.
 Moving the node does nothing until this is called.
*>
fn void NavObstacle.mark_changed(&self) {
    self.changed = true;
}

<* Push params and target to the crowd on the next crowd_update. *>
fn void NavAgent.mark_changed(&self) {
    self.changed = true;
}

<*
 Author a source on the node.
 @param [&in] node : "Carries a Mesh when geometry is the zero id."
 @return? c3d::INVALID_ARGUMENT, SOURCE_EXISTS
 @require self.world.is_registered(NavSource)
*>
fn void? Scene.add_nav_source(
    &self,
    Node* node,
    GeometryId geometry = {},
    bool walkable = true,
    char area = WALKABLE_AREA,
) {
    if (self.has(node, NavSource)) return SOURCE_EXISTS~;
    check_nav_source(geometry, area, self.has(node, scene::Mesh))!;
    self.add(node, (NavSource){ .geometry = geometry, .walkable = walkable, .area = area });
}

<*
 Author one walkable source per Mesh node under root that has none.
 @param [&in] root : "Walked including root."
 @return "How many sources were authored."
 @require self.world.is_registered(NavSource)
*>
fn uint Scene.add_nav_sources(&self, Node* root, char area = WALKABLE_AREA) {
    uint added;
    if (self.has(root, scene::Mesh) && !self.has(root, NavSource)) {
        self.add(root, (NavSource){ .walkable = true, .area = area });
        added++;
    }
    for (Node* child = root.first_child; child; child = child.next_sibling) {
        added += self.add_nav_sources(child, area);
    }
    return added;
}

<*
 Author a volume on the node.
 @return? c3d::INVALID_ARGUMENT, VOLUME_EXISTS
 @require self.world.is_registered(NavVolume)
*>
fn void? Scene.add_nav_volume(&self, Node* node, NavVolume volume) {
    if (self.has(node, NavVolume)) return VOLUME_EXISTS~;
    check_nav_volume(&volume)!;
    volume.changed = false;
    self.add(node, volume);
}

<*
 Author an off-mesh connection on the node.
 @param [&in] node : "Places the endpoints through its world matrix."
 @return? c3d::INVALID_ARGUMENT, LINK_EXISTS
 @require self.world.is_registered(NavLink)
*>
fn void? Scene.add_nav_link(&self, Node* node, NavLink link) {
    if (self.has(node, NavLink)) return LINK_EXISTS~;
    check_nav_link(&link)!;
    if (link.flags == 0) link.flags = POLY_FLAG_WALK;
    link.changed = false;
    self.add(node, link);
}

<*
 Author an obstacle on the node; a builder without cache_layers skips it.
 @param [&in] node : "Places the obstacle through its world matrix."
 @return? c3d::INVALID_ARGUMENT, OBSTACLE_EXISTS
 @require self.world.is_registered(NavObstacle)
*>
fn void? Scene.add_nav_obstacle(&self, Node* node, NavObstacle obstacle) {
    if (self.has(node, NavObstacle)) return OBSTACLE_EXISTS~;
    check_nav_obstacle(&obstacle)!;
    obstacle.changed = false;
    self.add(node, obstacle);
}

<*
 Author an agent on the node; the next crowd_update binds it to a crowd slot.
 @param [&in] node : "Its world position places the agent."
 @return? c3d::INVALID_ARGUMENT, AGENT_EXISTS
 @require self.world.is_registered(NavAgent)
*>
fn void? Scene.add_nav_agent(&self, Node* node, NavAgentParams params) {
    if (self.has(node, NavAgent)) return AGENT_EXISTS~;
    check_nav_agent_params(params)!;
    self.add(node, (NavAgent){ .params = params });
}

<*
 Ask the node's agent to walk to a world position, snapped to the mesh at the next crowd_update.
 A target beyond CROWD_MAX_PATH polygons is reached partially.
 @param [&in] node : "Carries a NavAgent."
 @require self.has(node, NavAgent)
*>
fn void Scene.set_nav_target(&self, Node* node, Vec3 position) {
    NavAgent* agent = self.get(node, NavAgent);
    agent.target_kind = POSITION;
    agent.target = position;
    agent.changed = true;
}

<*
 Ask the node's agent to move at a world velocity.
 @param [&in] node : "Carries a NavAgent."
 @require self.has(node, NavAgent)
*>
fn void Scene.set_nav_velocity(&self, Node* node, Vec3 velocity) {
    NavAgent* agent = self.get(node, NavAgent);
    agent.target_kind = VELOCITY;
    agent.target = velocity;
    agent.changed = true;
}

<*
 Stop the node's agent where it stands.
 @param [&in] node : "Carries a NavAgent."
 @require self.has(node, NavAgent)
*>
fn void Scene.clear_nav_target(&self, Node* node) {
    NavAgent* agent = self.get(node, NavAgent);
    agent.target_kind = NONE;
    agent.target = {};
    agent.changed = true;
}

<*
 Register the nav components and their mirrors.
 @param [&inout] scene : "Gains NavSource, NavVolume, NavLink, NavObstacle, NavAgent and their runtime mirrors."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? register_nav(Scene* scene) {
    scene.register(NavSource)!;
    scene.register(NavVolume)!;
    scene.register(NavLink)!;
    scene.register(NavObstacle)!;
    scene.register(NavAgent)!;
    scene.register(NavSourceRuntime)!;
    scene.register(NavVolumeRuntime)!;
    scene.register(NavLinkRuntime)!;
    scene.register(NavObstacleRuntime)!;
    scene.register(CrowdAgentRuntime)!;
}

fn void? check_nav_source(GeometryId geometry, char area, bool has_mesh) @private {
    if (area > WALKABLE_AREA) return c3d::INVALID_ARGUMENT~;
    if (c3d::same_id(geometry, (GeometryId){}) && !has_mesh) return c3d::INVALID_ARGUMENT~;
}

fn void? check_nav_volume(NavVolume* volume) @private {
    if (volume.area > WALKABLE_AREA) return c3d::INVALID_ARGUMENT~;
    switch (volume.kind) {
        case BOX:
            if (!nav_vector_finite(volume.box.min) || !nav_vector_finite(volume.box.max)) return c3d::INVALID_ARGUMENT~;
        case CONVEX:
            if (volume.vert_count < 3 || volume.vert_count > MAX_VOLUME_VERTS) return c3d::INVALID_ARGUMENT~;
            if (!(volume.min_y <= volume.max_y) || !math::is_finite(volume.min_y) || !math::is_finite(volume.max_y)) {
                return c3d::INVALID_ARGUMENT~;
            }
            foreach (point : volume.verts[:volume.vert_count]) if (!nav_vector_finite(point)) return c3d::INVALID_ARGUMENT~;
        case CYLINDER:
            if (!(volume.radius > 0) || !(volume.height > 0)
                || !math::is_finite(volume.radius) || !math::is_finite(volume.height)
                || !nav_vector_finite(volume.base)) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_nav_link(NavLink* link) @private {
    if (!(link.radius > 0) || !math::is_finite(link.radius)
        || !nav_vector_finite(link.start) || !nav_vector_finite(link.end)
        || link.area >= MAX_AREAS || link.start == link.end) return c3d::INVALID_ARGUMENT~;
}

fn void? check_nav_obstacle(NavObstacle* obstacle) @private {
    switch (obstacle.kind) {
        case CYLINDER:
            if (!(obstacle.radius > 0) || !(obstacle.height > 0)
                || !math::is_finite(obstacle.radius) || !math::is_finite(obstacle.height)
                || !nav_vector_finite(obstacle.position)) return c3d::INVALID_ARGUMENT~;
        case BOX:
            if (!nav_vector_finite(obstacle.box.min) || !nav_vector_finite(obstacle.box.max)) return c3d::INVALID_ARGUMENT~;
            Vec3 extent = obstacle.box.max - obstacle.box.min;
            if (!(extent.x >= 0) || !(extent.y >= 0) || !(extent.z >= 0)) return c3d::INVALID_ARGUMENT~;
        case ORIENTED_BOX:
            Vec3 half = obstacle.half_extents;
            if (!(half.x > 0) || !(half.y > 0) || !(half.z > 0)
                || !nav_vector_finite(half) || !nav_vector_finite(obstacle.position)) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_nav_agent_params(NavAgentParams params) @private {
    if (!(params.radius >= 0) || !(params.height > 0) || !(params.max_speed >= 0)) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(params.radius) || !math::is_finite(params.height) || !math::is_finite(params.max_acceleration)
        || !math::is_finite(params.max_speed) || !math::is_finite(params.collision_query_range)
        || !math::is_finite(params.path_optimization_range) || !math::is_finite(params.separation_weight)) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (params.query_filter_type >= MAX_CROWD_FILTERS) return c3d::INVALID_ARGUMENT~;
    if (params.obstacle_avoidance_type >= MAX_AVOIDANCE_PARAMS) return c3d::INVALID_ARGUMENT~;
}

fn void? check_nav_agent(NavAgent* agent) @private {
    check_nav_agent_params(agent.params)!;
    if (agent.target_kind == POSITION && !nav_vector_finite(agent.target)) return c3d::INVALID_ARGUMENT~;
}

fn bool nav_vector_finite(Vec3 value) @local {
    return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
}
