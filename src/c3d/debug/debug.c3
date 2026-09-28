module c3d::debug;

import c3d;
import c3d::anim::ik;
import c3d::asset;
import c3d::light;
import c3d::maths;
import c3d::scene;
import std::collections::list;
import std::math;

<*
 Segments one sink holds before it drops further lines.
*>
const usz DEBUG_LINE_CAPACITY = 16384; // 512 KiB of vertices; a full scene of bounds, frusta and joints

<*
 Segments approximating one circle.
*>
const uint DEBUG_CIRCLE_SEGMENTS = 32;

const uint COLOR_RED    = 0xFF0000FF;
const uint COLOR_GREEN  = 0xFF00FF00;
const uint COLOR_BLUE   = 0xFFFF0000;
const uint COLOR_WHITE  = 0xFFFFFFFF;
const uint COLOR_YELLOW = 0xFF00FFFF;

const float LIGHT_ARROW_LENGTH @local = 2;
const float LIGHT_MARKER_RADIUS @local = 0.25f;
const float JOINT_AXES_SIZE @local = 0.05f;
const float IK_TARGET_RADIUS @local = 0.05f; // metres; visible at character scale without hiding the hand
const float BASIS_PARALLEL_THRESHOLD @local = 0.99f; // a normal this close to Y takes X as its reference
const float PROBE_MARKER_SCALE @local = 0.1f;        // of the smallest spacing; small enough to keep neighbours apart

<*
 Line endpoint with a packed color, red in the low byte.
*>
struct DebugVertex {
    Vec3 position;
    uint rgba;
}

<*
 Line list an application fills each frame and hands to views.
*>
struct DebugDraw {
    Allocator         allocator;
    usz               capacity;
    List{DebugVertex} vertices;
}

<*
 Drop every segment and keep the capacity.
*>
fn void DebugDraw.clear(&self) {
    self.vertices.clear();
}

<*
 Append one segment; dropped once the sink is full.
*>
fn void DebugDraw.line(&self, Vec3 from, Vec3 to, uint rgba) {
    if ((usz)self.vertices.len() + 2 > self.capacity) return;
    self.vertices.push({ .position = from, .rgba = rgba });
    self.vertices.push({ .position = to, .rgba = rgba });
}

<*
 Append the twelve edges of an axis-aligned box.
*>
fn void DebugDraw.aabb(&self, Aabb bounds, uint rgba) {
    Vec3[8] corners = box_corners(bounds);
    box_edges(self, corners, rgba);
}

<*
 Append the twelve edges of a local box under a world matrix.
*>
fn void DebugDraw.box(&self, Mat4 world, Aabb local, uint rgba) {
    Vec3[8] corners = box_corners(local);
    foreach (&corner : corners) *corner = maths::transform_point(world, *corner);
    box_edges(self, corners, rgba);
}

<*
 Append the twelve edges of a reverse-Z view frustum.
 @param inv_view_proj : "Inverse of the camera's view-projection matrix."
*>
fn void DebugDraw.frustum(&self, Mat4 inv_view_proj, uint rgba) {
    Vec3[8] corners;
    for (uint index = 0; index < corners.len; index++) {
        Vec4 corner = inv_view_proj.apply({
            (index & 1) != 0 ? 1.0f : -1.0f,
            (index & 2) != 0 ? 1.0f : -1.0f,
            (index & 4) != 0 ? 0.0f : 1.0f,
            1,
        });
        corners[index] = corner.xyz / corner.w;
    }
    box_edges(self, corners, rgba);
}

<*
 Append a circle around a normal.
 @require radius > 0
*>
fn void DebugDraw.circle(&self, Vec3 center, Vec3 normal, float radius, uint rgba) {
    Vec3 reference = math::abs(normal.y) > BASIS_PARALLEL_THRESHOLD ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 1, 0 };
    Vec3 right = normal.cross(reference).normalize();
    Vec3 up = right.cross(normal);

    Vec3 previous = center + right * radius;
    for (uint segment = 1; segment <= DEBUG_CIRCLE_SEGMENTS; segment++) {
        float angle = (float)segment / DEBUG_CIRCLE_SEGMENTS * 2 * (float)math::PI;
        Vec3 point = center + (right * math::cos(angle) + up * math::sin(angle)) * radius;
        self.line(previous, point, rgba);
        previous = point;
    }
}

<*
 Append a capsule outline.
 @param axis : "Unit length; direction of the segment."
 @param half_height : "Half the segment length, caps excluded."
*>
fn void DebugDraw.capsule(
    &self,
    Vec3 center,
    Vec3 axis,
    float half_height,
    float radius,
    uint rgba,
) {
    Vec3 reference = math::abs(axis.y) < BASIS_PARALLEL_THRESHOLD ? (Vec3){ 0, 1, 0 } : (Vec3){ 1, 0, 0 };
    Vec3 side = axis.cross(reference).normalize();
    Vec3 forward = axis.cross(side);
    Vec3 top = center + axis * half_height;
    Vec3 bottom = center - axis * half_height;

    self.circle(top, axis, radius, rgba);
    self.circle(bottom, axis, radius, rgba);
    self.circle(top, side, radius, rgba);
    self.circle(top, forward, radius, rgba);
    self.circle(bottom, side, radius, rgba);
    self.circle(bottom, forward, radius, rgba);
    self.line(top + side * radius, bottom + side * radius, rgba);
    self.line(top - side * radius, bottom - side * radius, rgba);
    self.line(top + forward * radius, bottom + forward * radius, rgba);
    self.line(top - forward * radius, bottom - forward * radius, rgba);
}

<*
 Append red, green and blue axes of a world matrix, unscaled.
*>
fn void DebugDraw.axes(&self, Mat4 world, float size) {
    Vec3 origin = maths::translation(world);
    self.line(origin, origin + maths::transform_dir(world, { 1, 0, 0 }).normalize() * size, COLOR_RED);
    self.line(origin, origin + maths::transform_dir(world, { 0, 1, 0 }).normalize() * size, COLOR_GREEN);
    self.line(origin, origin + maths::transform_dir(world, { 0, 0, 1 }).normalize() * size, COLOR_BLUE);
}

<*
 Append the world-space box of every visible mesh.
 @param [&in] scene : "Pose as left by the last update_world."
 @param [&in] assets : "Resolves geometry bounds."
*>
fn void DebugDraw.mesh_bounds(&self, Scene* scene, AssetStore* assets, uint rgba) {
    scene.world.@each(Mesh; entity, mesh) {
        Node* node = scene.node(entity);
        if (node.visible_effective) {
            if (mesh.has_bounds_override) {
                self.box(node.world, mesh.local_bounds, rgba);
            } else if (assets.geometries.is_live(mesh.geometry)) {
                self.box(node.world, assets.geometry(mesh.geometry).data.bounds, rgba);
            }
        }
    };
}

<*
 Append the reach of every light: arrow, range circles or cone.
 @param [&in] scene : "Pose as left by the last update_world."
*>
fn void DebugDraw.light_volumes(&self, Scene* scene, uint rgba) {
    scene.world.@each(Light; entity, light) {
        Node* node = scene.node(entity);
        Vec3 position = node.world_position();
        Vec3 direction = maths::transform_dir(node.world, { 0, 0, -1 }).normalize();
        switch (light.kind) {
            case DIRECTIONAL:
                self.line(position, position + direction * LIGHT_ARROW_LENGTH, rgba);
            case POINT:
                float radius = light.range > 0 ? light.range : LIGHT_MARKER_RADIUS;
                self.circle(position, { 1, 0, 0 }, radius, rgba);
                self.circle(position, { 0, 1, 0 }, radius, rgba);
                self.circle(position, { 0, 0, 1 }, radius, rgba);
            case SPOT:
                float range = light.range > 0 ? light.range : LIGHT_ARROW_LENGTH;
                Vec3 base = position + direction * range;
                float radius = range * math::tan(light.outer_cone);
                Vec3 reference = math::abs(direction.y) > BASIS_PARALLEL_THRESHOLD ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 1, 0 };
                Vec3 right = direction.cross(reference).normalize();
                Vec3 up = right.cross(direction);
                self.line(position, base + right * radius, rgba);
                self.line(position, base - right * radius, rgba);
                self.line(position, base + up * radius, rgba);
                self.line(position, base - up * radius, rgba);
                self.circle(base, direction, radius, rgba);
        }
    };
}

<*
 Append the box and a cross per probe of every volume on a visible node.
 @param [&in] scene : "Pose as left by the last update_world."
*>
fn void DebugDraw.probe_volumes(&self, Scene* scene, uint rgba) {
    scene.world.@each(ProbeVolume; entity, volume) {
        Node* node = scene.node(entity);
        if (node.visible_effective) probe_volume_lines(self, node.world_position(), volume, rgba);
    };
}

<*
 Append the bone segments and joint axes of every skin binding.
 @param [&in] scene : "Pose as left by the last update_world."
*>
fn void DebugDraw.joints(&self, Scene* scene, uint rgba) {
    scene.world.@each(SkinBinding; entity, binding) {
        foreach (joint : binding.joints) {
            if (joint.parent && joint_of(binding, joint.parent)) {
                self.line(joint.parent.world_position(), joint.world_position(), rgba);
            }
            self.axes(joint.world, JOINT_AXES_SIZE);
        }
    };
}

<*
 Append IK chains, foot hits and look-at lines of every component.
 @param [&in] scene : "Pose as left by the last update_world."
*>
fn void DebugDraw.ik(&self, Scene* scene, uint rgba) {
    scene.world.@each(IkChain; entity, chain) {
        chain_lines(self, chain, rgba);
    };
    scene.world.@each(FootIk; entity, foot) {
        chain_lines(self, &foot.leg, rgba);
        if (foot.grounded) {
            self.line(foot.ground.point, foot.ground.point + foot.ground.normal * (IK_TARGET_RADIUS * 2), rgba);
        }
    };
    scene.world.@each(LookAt; entity, look_at) {
        self.line(look_at.joints[look_at.joint_count - 1].world_position(), look_at.target.world_position(), rgba);
    };
}

<*
 Append the axes of one node's world matrix.
 @param [&in] node : "Pose as left by the last update_world."
*>
fn void DebugDraw.node_axes(&self, Node* node, float size) {
    self.axes(node.world, size);
}

<*
 Pack a color with red in the low byte, as unpackUnorm4x8 reads it.
 @param red : "Clamped to [0, 1]."
 @param green : "Clamped to [0, 1]."
 @param blue : "Clamped to [0, 1]."
 @param alpha : "Clamped to [0, 1]."
*>
fn uint rgba(float red, float green, float blue, float alpha = 1) {
    return channel_byte(red) | channel_byte(green) << 8 | channel_byte(blue) << 16 | channel_byte(alpha) << 24;
}

<*
 Create an empty sink of fixed capacity.
 @require capacity >= 2
*>
fn DebugDraw create_debug_draw(Allocator allocator, usz capacity = DEBUG_LINE_CAPACITY) {
    DebugDraw draw = { .allocator = allocator, .capacity = capacity };
    draw.vertices.init(allocator, (sz)capacity);
    return draw;
}

<*
 Free the sink's storage.
*>
fn void destroy_debug_draw(DebugDraw* draw) {
    draw.vertices.free();
    *draw = {};
}

fn void probe_volume_lines(DebugDraw* draw, Vec3 center, ProbeVolume* volume, uint rgba) @local {
    draw.aabb({ .min = center - volume.half_extents, .max = center + volume.half_extents }, rgba);
    Vec3 spacing = volume.spacing();
    float half_size = PROBE_MARKER_SCALE * math::min(spacing.x, spacing.y, spacing.z);
    for (uint z = 0; z < volume.counts.z; z++) {
        for (uint y = 0; y < volume.counts.y; y++) {
            for (uint x = 0; x < volume.counts.x; x++) {
                Vec3 probe = volume.probe_position(center, { x, y, z });
                draw.line(probe - { half_size, 0, 0 }, probe + { half_size, 0, 0 }, rgba);
                draw.line(probe - { 0, half_size, 0 }, probe + { 0, half_size, 0 }, rgba);
                draw.line(probe - { 0, 0, half_size }, probe + { 0, 0, half_size }, rgba);
            }
        }
    }
}

fn void box_edges(DebugDraw* draw, Vec3[8] corners, uint rgba) @local {
    for (uint index = 0; index < corners.len; index++) {
        if ((index & 1) == 0) draw.line(corners[index], corners[index | 1], rgba);
        if ((index & 2) == 0) draw.line(corners[index], corners[index | 2], rgba);
        if ((index & 4) == 0) draw.line(corners[index], corners[index | 4], rgba);
    }
}

fn void chain_lines(DebugDraw* draw, IkChain* chain, uint rgba) @local {
    Vec3 middle = chain.joints[1].world_position();
    draw.line(chain.joints[0].world_position(), middle, rgba);
    draw.line(middle, chain.joints[2].world_position(), rgba);
    draw.circle(chain.target.world_position(), { 0, 1, 0 }, IK_TARGET_RADIUS, rgba);
    if (chain.pole) draw.line(middle, chain.pole.world_position(), rgba);
}

fn uint channel_byte(float value) @local {
    return (uint)math::round(math::clamp(value, 0.0f, 1.0f) * 255);
}

fn Vec3[8] box_corners(Aabb bounds) @local {
    Vec3[8] corners;
    for (uint index = 0; index < corners.len; index++) {
        corners[index] = {
            (index & 1) != 0 ? bounds.max.x : bounds.min.x,
            (index & 2) != 0 ? bounds.max.y : bounds.min.y,
            (index & 4) != 0 ? bounds.max.z : bounds.min.z,
        };
    }
    return corners;
}

fn bool joint_of(SkinBinding* binding, Node* node) @local {
    foreach (joint : binding.joints) {
        if (joint == node) return true;
    }
    return false;
}
