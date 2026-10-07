module c3d_nav_domains_test;

import c3d;
import c3d::nav;
import c3d::scene;
import std::math;

enum DomainOwner @private {
    VOLUME,
    LINK,
    OBSTACLE,
    AGENT,
}

struct DomainFixture @private {
    DomainOwner owner;
    String name;
    NavVolume volume;
    NavLink link;
    NavObstacle obstacle;
    NavAgent agent;
    float*[nav::MAX_VOLUME_VERTS * 3 + 2] fields;
    uint count;
}

fn void DomainFixture.add_vector_fields(&self, Vec3* value) {
    self.fields[self.count++] = &value.x;
    self.fields[self.count++] = &value.y;
    self.fields[self.count++] = &value.z;
}

fn uint domain_variants(DomainOwner owner) @private {
    return owner == VOLUME || owner == OBSTACLE ? 3 : 1;
}

fn void setup_domain(DomainFixture* fixture, DomainOwner owner, uint variant) @private {
    float unused = bitcast(0x7fc0abcdu, float);
    Vec3 absent = { unused, unused, unused };
    *fixture = {
        .owner = owner,
        .volume = {
            .box = { .min = absent, .max = absent }, .base = absent,
            .min_y = unused, .max_y = unused, .radius = unused, .height = unused,
        },
        .obstacle = {
            .position = absent, .radius = unused, .height = unused,
            .box = { .min = absent, .max = absent }, .half_extents = absent,
        },
        .agent = { .params = nav::default_nav_agent_params(), .target_kind = POSITION },
    };
    fixture.volume.verts[..] = absent;
    switch (owner) {
        case VOLUME:
            fixture.name = "nav_volume";
            fixture.volume.kind = (VolumeKind)variant;
            switch (fixture.volume.kind) {
                case BOX:
                    fixture.add_vector_fields(&fixture.volume.box.min);
                    fixture.add_vector_fields(&fixture.volume.box.max);
                case CONVEX:
                    fixture.volume.vert_count = nav::MAX_VOLUME_VERTS - 1;
                    foreach (&point : fixture.volume.verts[:fixture.volume.vert_count]) fixture.add_vector_fields(point);
                    fixture.fields[fixture.count++] = &fixture.volume.min_y;
                    fixture.fields[fixture.count++] = &fixture.volume.max_y;
                case CYLINDER:
                    fixture.add_vector_fields(&fixture.volume.base);
                    fixture.fields[fixture.count++] = &fixture.volume.radius;
                    fixture.fields[fixture.count++] = &fixture.volume.height;
            }
        case LINK:
            fixture.name = "nav_link";
            fixture.link.flags = nav::POLY_FLAG_WALK;
            fixture.add_vector_fields(&fixture.link.start);
            fixture.add_vector_fields(&fixture.link.end);
            fixture.fields[fixture.count++] = &fixture.link.radius;
        case OBSTACLE:
            fixture.name = "nav_obstacle";
            fixture.obstacle.kind = (ObstacleKind)variant;
            switch (fixture.obstacle.kind) {
                case CYLINDER:
                    fixture.add_vector_fields(&fixture.obstacle.position);
                    fixture.fields[fixture.count++] = &fixture.obstacle.radius;
                    fixture.fields[fixture.count++] = &fixture.obstacle.height;
                case BOX:
                    fixture.add_vector_fields(&fixture.obstacle.box.min);
                    fixture.add_vector_fields(&fixture.obstacle.box.max);
                case ORIENTED_BOX:
                    fixture.add_vector_fields(&fixture.obstacle.position);
                    fixture.add_vector_fields(&fixture.obstacle.half_extents);
            }
        case AGENT:
            fixture.name = "nav_agent";
            fixture.fields[:7] = ((float*[7]){
                &fixture.agent.params.radius, &fixture.agent.params.height,
                &fixture.agent.params.max_acceleration, &fixture.agent.params.max_speed,
                &fixture.agent.params.collision_query_range, &fixture.agent.params.path_optimization_range,
                &fixture.agent.params.separation_weight,
            })[..];
            fixture.count = 7;
            fixture.add_vector_fields(&fixture.agent.target);
    }
    uint bits = 0x3f912301;
    foreach (field : fixture.fields[:fixture.count]) {
        *field = bitcast(bits, float);
        bits += 0x1234;
    }
}

fn void? add_domain(Scene* scene, Node* node, DomainFixture* fixture) @private {
    switch (fixture.owner) {
        case VOLUME: return scene.add_nav_volume(node, fixture.volume);
        case LINK: return scene.add_nav_link(node, fixture.link);
        case OBSTACLE: return scene.add_nav_obstacle(node, fixture.obstacle);
        case AGENT: return scene.add_nav_agent(node, fixture.agent.params);
    }
}

fn void replace_domain(Scene* scene, Node* node, DomainFixture* fixture) @private {
    switch (fixture.owner) {
        case VOLUME: *scene.get(node, NavVolume) = fixture.volume;
        case LINK: *scene.get(node, NavLink) = fixture.link;
        case OBSTACLE: *scene.get(node, NavObstacle) = fixture.obstacle;
        case AGENT: *scene.get(node, NavAgent) = fixture.agent;
    }
}
