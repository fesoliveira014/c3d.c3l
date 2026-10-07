module c3d::nav @feat(C3D_NAV_SERIAL);

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::maths;
import c3d::scene;
import c3d::serial;
import std::math;

struct NavSourceAuthoring @private {
    GeometryId geometry;
    bool walkable;
    char area;
}

struct NavVolumeAuthoring @private {
    VolumeKind kind;
    char area;
    Aabb box;
    Vec3[MAX_VOLUME_VERTS] verts;
    uint vert_count;
    float min_y;
    float max_y;
    Vec3 base;
    float radius;
    float height;
}

struct NavLinkAuthoring @private {
    Vec3 start;
    Vec3 end;
    float radius;
    bool bidirectional;
    char area;
    ushort flags;
    uint user_id;
}

struct NavObstacleAuthoring @private {
    ObstacleKind kind;
    Vec3 position;
    float radius;
    float height;
    Aabb box;
    Vec3 half_extents;
}

struct NavAgentParamsAuthoring @private {
    float radius;
    float height;
    float max_acceleration;
    float max_speed;
    float collision_query_range;
    float path_optimization_range;
    float separation_weight;
    char update_flags;
    char obstacle_avoidance_type;
    char query_filter_type;
}

struct NavAgentAuthoring @private {
    NavAgentParamsAuthoring params;
    AgentTargetKind target_kind;
    Vec3 target;
    bool driven;
}

<*
 Register navigation authoring codecs and transient runtime mirrors.
 @return? describe::DESCRIPTION_CONFLICT, describe::MISSING_DESCRIPTION
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn void? register_serial_codecs() {
    serial::register_core_value_types()!;
    register_value(NavSourceAuthoring, 0x92e51405ee3d3b38, &defaults_nav_source)!;
    register_value(NavVolumeAuthoring, 0x751ce47375bc297a, &defaults_nav_volume)!;
    register_value(NavLinkAuthoring, 0xf6e1d7fd06715801, &defaults_nav_link)!;
    register_value(NavObstacleAuthoring, 0x86fb0afd9d99f20b, &defaults_nav_obstacle)!;
    register_value(NavAgentParamsAuthoring, 0x1c765a3b425abafa, &defaults_nav_agent_params)!;
    register_value(NavAgentAuthoring, 0xe9692a3bee8bc525, &defaults_nav_agent)!;
    serial::register_described_owner(NavSource, NavSourceAuthoring, {
        .name = "nav_source",
        .phase = REFERENCES,
        .project = &project_source,
        .validate = &validate_source,
        .attach = &attach_source,
    })!;
    serial::register_described_owner(NavVolume, NavVolumeAuthoring, {
        .name = "nav_volume",
        .phase = REFERENCES,
        .project = &project_volume,
        .validate = &validate_volume,
        .attach = &attach_volume,
    })!;
    serial::register_described_owner(NavLink, NavLinkAuthoring, {
        .name = "nav_link",
        .phase = REFERENCES,
        .project = &project_link,
        .validate = &validate_link,
        .attach = &attach_link,
    })!;
    serial::register_described_owner(NavObstacle, NavObstacleAuthoring, {
        .name = "nav_obstacle",
        .phase = REFERENCES,
        .project = &project_obstacle,
        .validate = &validate_obstacle,
        .attach = &attach_obstacle,
    })!;
    serial::register_described_owner(NavAgent, NavAgentAuthoring, {
        .name = "nav_agent",
        .phase = REFERENCES,
        .project = &project_agent,
        .validate = &validate_agent,
        .attach = &attach_agent,
    })!;
    serial::register_transient(NavSourceRuntime)!;
    serial::register_transient(NavVolumeRuntime)!;
    serial::register_transient(NavLinkRuntime)!;
    serial::register_transient(NavObstacleRuntime)!;
    serial::register_transient(CrowdAgentRuntime)!;
}

macro void? register_value($Type, ulong layout, serial::DefaultsFn defaults) @private {
    describe::register_reflected($Type)!;
    serial::register_described_type(
        $Type: $Type,
        version: 1,
        layout: layout,
        defaults: defaults,
    )!;
}

fn void defaults_nav_source(void* value) @private => *(NavSourceAuthoring*)value = { .walkable = true, .area = WALKABLE_AREA };

fn void? project_source(void* component, void* value, serial::WriteContext* context) @private {
    NavSource* source = component;
    *(NavSourceAuthoring*)value = {
        .geometry = source.geometry,
        .walkable = source.walkable,
        .area = source.area,
    };
    check_source((NavSourceAuthoring*)value, context.scene.has(context.node, Mesh))!;
}

fn void? attach_source(void* value, serial::ReadContext* context) @private {
    NavSourceAuthoring* source = value;
    context.scene.add_nav_source(
        node: context.node,
        geometry: source.geometry,
        walkable: source.walkable,
        area: source.area,
    )!;
}

fn void defaults_nav_volume(void* value) @private => *(NavVolumeAuthoring*)value = {};

fn void? project_volume(void* component, void* value, serial::WriteContext* context) @private {
    NavVolume* source = component;
    *(NavVolumeAuthoring*)value = {
        .kind = source.kind,
        .area = source.area,
        .box = source.box,
        .verts = source.verts,
        .vert_count = source.vert_count,
        .min_y = source.min_y,
        .max_y = source.max_y,
        .base = source.base,
        .radius = source.radius,
        .height = source.height,
    };
    check_volume((NavVolumeAuthoring*)value)!;
}

fn NavVolume volume_value(NavVolumeAuthoring* value) @private {
    return {
        .kind = value.kind,
        .area = value.area,
        .box = value.box,
        .verts = value.verts,
        .vert_count = value.vert_count,
        .min_y = value.min_y,
        .max_y = value.max_y,
        .base = value.base,
        .radius = value.radius,
        .height = value.height,
    };
}

fn void? attach_volume(void* value, serial::ReadContext* context) @private {
    context.scene.add_nav_volume(context.node, volume_value((NavVolumeAuthoring*)value))!;
}

fn void defaults_nav_link(void* value) @private => *(NavLinkAuthoring*)value = { .flags = POLY_FLAG_WALK };

fn void? project_link(void* component, void* value, serial::WriteContext* context) @private {
    NavLink* source = component;
    *(NavLinkAuthoring*)value = {
        .start = source.start,
        .end = source.end,
        .radius = source.radius,
        .bidirectional = source.bidirectional,
        .area = source.area,
        .flags = source.flags,
        .user_id = source.user_id,
    };
    check_link((NavLinkAuthoring*)value)!;
}

fn NavLink link_value(NavLinkAuthoring* value) @private {
    return {
        .start = value.start,
        .end = value.end,
        .radius = value.radius,
        .bidirectional = value.bidirectional,
        .area = value.area,
        .flags = value.flags,
        .user_id = value.user_id,
    };
}

fn void? attach_link(void* value, serial::ReadContext* context) @private {
    context.scene.add_nav_link(context.node, link_value((NavLinkAuthoring*)value))!;
}

fn void defaults_nav_obstacle(void* value) @private => *(NavObstacleAuthoring*)value = {};

fn void? project_obstacle(void* component, void* value, serial::WriteContext* context) @private {
    NavObstacle* source = component;
    *(NavObstacleAuthoring*)value = {
        .kind = source.kind,
        .position = source.position,
        .radius = source.radius,
        .height = source.height,
        .box = source.box,
        .half_extents = source.half_extents,
    };
    check_obstacle((NavObstacleAuthoring*)value)!;
}

fn NavObstacle obstacle_value(NavObstacleAuthoring* value) @private {
    return {
        .kind = value.kind,
        .position = value.position,
        .radius = value.radius,
        .height = value.height,
        .box = value.box,
        .half_extents = value.half_extents,
    };
}

fn void? attach_obstacle(void* value, serial::ReadContext* context) @private {
    context.scene.add_nav_obstacle(context.node, obstacle_value((NavObstacleAuthoring*)value))!;
}

fn NavAgentParamsAuthoring params_authoring(NavAgentParams value) @private {
    return {
        .radius = value.radius,
        .height = value.height,
        .max_acceleration = value.max_acceleration,
        .max_speed = value.max_speed,
        .collision_query_range = value.collision_query_range,
        .path_optimization_range = value.path_optimization_range,
        .separation_weight = value.separation_weight,
        .update_flags = (char)value.update_flags,
        .obstacle_avoidance_type = value.obstacle_avoidance_type,
        .query_filter_type = value.query_filter_type,
    };
}

fn NavAgentParams params_value(NavAgentParamsAuthoring value) @private {
    return {
        .radius = value.radius,
        .height = value.height,
        .max_acceleration = value.max_acceleration,
        .max_speed = value.max_speed,
        .collision_query_range = value.collision_query_range,
        .path_optimization_range = value.path_optimization_range,
        .separation_weight = value.separation_weight,
        .update_flags = (AgentUpdateFlags)value.update_flags,
        .obstacle_avoidance_type = value.obstacle_avoidance_type,
        .query_filter_type = value.query_filter_type,
    };
}

fn void defaults_nav_agent_params(void* value) @private {
    *(NavAgentParamsAuthoring*)value = params_authoring(default_nav_agent_params());
}

fn void defaults_nav_agent(void* value) @private {
    *(NavAgentAuthoring*)value = { .params = params_authoring(default_nav_agent_params()) };
}

fn void? project_agent(void* component, void* value, serial::WriteContext* context) @private {
    NavAgent* source = component;
    *(NavAgentAuthoring*)value = {
        .params = params_authoring(source.params),
        .target_kind = source.target_kind,
        .target = source.target,
        .driven = source.driven,
    };
    check_agent((NavAgentAuthoring*)value)!;
}

fn void? attach_agent(void* value, serial::ReadContext* context) @private {
    NavAgentAuthoring* source = value;
    context.scene.add_nav_agent(context.node, params_value(source.params))!;
    NavAgent* agent = context.scene.get(context.node, NavAgent);
    agent.target_kind = source.target_kind;
    agent.target = source.target;
    agent.driven = source.driven;
}

fn void? validate_source(void* value, serial::ReadContext* context) @private {
    check_source((NavSourceAuthoring*)value, context.has_component(Mesh))!;
}

fn void? check_source(NavSourceAuthoring* value, bool has_mesh) @private {
    NavSourceAuthoring* source = value;
    if (source.area > WALKABLE_AREA) return c3d::INVALID_ARGUMENT~;
    if (!source.geometry.generation && !has_mesh) return c3d::INVALID_ARGUMENT~;
}

fn void? validate_volume(void* value, serial::ReadContext* context) @private {
    check_volume((NavVolumeAuthoring*)value)!;
}

fn void? check_volume(NavVolumeAuthoring* value) @private {
    NavVolumeAuthoring* volume = value;
    if (volume.area > WALKABLE_AREA) return c3d::INVALID_ARGUMENT~;
    switch (volume.kind) {
        case BOX:
            break;
        case CONVEX:
            if (volume.vert_count < 3 || volume.vert_count > MAX_VOLUME_VERTS) return c3d::INVALID_ARGUMENT~;
            if (volume.min_y > volume.max_y) return c3d::INVALID_ARGUMENT~;
        case CYLINDER:
            if (volume.radius <= 0 || volume.height <= 0) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? validate_link(void* value, serial::ReadContext* context) @private {
    check_link((NavLinkAuthoring*)value)!;
}

fn void? check_link(NavLinkAuthoring* value) @private {
    NavLinkAuthoring* link = value;
    if (link.radius <= 0 || link.area >= MAX_AREAS || link.start == link.end) return c3d::INVALID_ARGUMENT~;
}

fn void? validate_obstacle(void* value, serial::ReadContext* context) @private {
    check_obstacle((NavObstacleAuthoring*)value)!;
}

fn void? check_obstacle(NavObstacleAuthoring* value) @private {
    NavObstacleAuthoring* obstacle = value;
    switch (obstacle.kind) {
        case CYLINDER:
            if (obstacle.radius <= 0 || obstacle.height <= 0) return c3d::INVALID_ARGUMENT~;
        case BOX:
            Vec3 extent = obstacle.box.max - obstacle.box.min;
            if (extent.x < 0 || extent.y < 0 || extent.z < 0) return c3d::INVALID_ARGUMENT~;
        case ORIENTED_BOX:
            Vec3 half = obstacle.half_extents;
            if (half.x <= 0 || half.y <= 0 || half.z <= 0) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? validate_agent(void* value, serial::ReadContext* context) @private {
    check_agent((NavAgentAuthoring*)value)!;
}

fn void? check_agent(NavAgentAuthoring* value) @private {
    NavAgentParamsAuthoring* params = &((NavAgentAuthoring*)value).params;
    if (params.radius < 0 || params.height <= 0 || params.max_speed < 0) return c3d::INVALID_ARGUMENT~;
    if (params.query_filter_type >= MAX_CROWD_FILTERS) return c3d::INVALID_ARGUMENT~;
    if (params.obstacle_avoidance_type >= MAX_AVOIDANCE_PARAMS) return c3d::INVALID_ARGUMENT~;
}
