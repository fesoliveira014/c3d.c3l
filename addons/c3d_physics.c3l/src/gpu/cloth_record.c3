module c3d::render::cloth_gpu @feat(C3D_PHYSICS_GPU);

import c3d;
import c3d::asset;
import c3d::material;
import c3d::maths;
import c3d::physics::cloth @public;
import c3d::render;
import c3d::scene;
import std::math;

const uint FUSED_GROUP_SIZE @private = 64; // mirrored as the default CLOTH_LOCAL_SIZE in cloth_root.glsl
const uint PASS_PREDICT @private = 1; // mirrored in cloth_step.glsl
const uint PASS_COLLIDE @private = 2; // mirrored in cloth_step.glsl
const uint PASS_INTEGRATE @private = 4; // mirrored in cloth_step.glsl
const uint PASS_INITIALIZE @private = 8; // mirrored in cloth_step.glsl
const uint PASS_OUTPUT @private = 16; // mirrored in cloth_step.glsl
const uint PASS_FINAL_SUBSTEP @private = 32; // mirrored in cloth_step.glsl
const float NO_GROUND @private = -1e30f; // below every particle; disables the ground contact

// Mirrors ClothRoot in cloth_root.glsl.
struct ClothRoot @private {
    ulong     positions;
    ulong     predicted;
    ulong     velocities;
    ulong     edges;
    ulong     initial;
    ulong     rest;
    ulong     marks;
    ulong     color_starts;
    ulong     adjacency;
    ulong     triangles;
    ulong     geometry_positions;
    ulong     geometry_normals;
    float[16] anchor_frame;
    float[16] target_frame;
    float[16] inverse_world;
    float[4]  gravity_step;
    float[4]  sphere;
    uint      particle_count;
    float     stiffness;
    float     damping;
    float     ground;
    uint      substeps;
    uint      iterations;
    uint      color_count;
    uint      first;
    uint      count;
    uint      phases;
    uint      member_bit;
    float     progress;
}

$assert ClothRoot::size == 368;
$assert $reflect(ClothRoot.anchor_frame).offset == 96;
$assert $reflect(ClothRoot.target_frame).offset == 160;
$assert $reflect(ClothRoot.inverse_world).offset == 224;
$assert $reflect(ClothRoot.gravity_step).offset == 288;
$assert $reflect(ClothRoot.sphere).offset == 304;
$assert $reflect(ClothRoot.particle_count).offset == 320;
$assert $reflect(ClothRoot.progress).offset == 364;

struct StepRecorder @private {
    Renderer*       renderer;
    ClothRoot       root;
    ComputeShaderId stage;
    BufferId[2]     state_writes;
    GeometryWrite[] output;
}

fn void? StepRecorder.run(&self, uint threads, bool writes_output = false) {
    return self.renderer.dispatch({
        .shader   = self.stage,
        .root     = material::@as_bytes(self.root),
        .groups   = { (threads + FUSED_GROUP_SIZE - 1) / FUSED_GROUP_SIZE, 1, 1 },
        .writes   = self.state_writes[..],
        .geometry = writes_output ? self.output : {},
    });
}

// Predict joins the first color of a substep, collide the last color of each iteration, integrate the last pass.
fn void? StepRecorder.record_fused(&self, uint[] color_starts, bool first) {
    uint colors = self.root.color_count;
    uint substeps = self.root.substeps;
    for (uint substep = 0; substep < substeps; substep++) {
        self.root.progress = (float)(substep + 1) / (float)substeps;
        for (uint iteration = 0; iteration < self.root.iterations; iteration++) {
            for (uint color = 0; color < colors; color++) {
                uint phases = substep + 1 == substeps ? PASS_FINAL_SUBSTEP : 0;
                if (iteration == 0 && color == 0) phases |= PASS_PREDICT;
                if (first && substep == 0 && iteration == 0 && color == 0) phases |= PASS_INITIALIZE;
                if (color + 1 == colors) {
                    phases |= PASS_COLLIDE;
                    if (iteration + 1 == self.root.iterations) phases |= PASS_INTEGRATE;
                }

                self.root.first = color_starts[color];
                self.root.count = color_starts[color + 1] - color_starts[color];
                self.root.phases = phases;
                self.root.member_bit = color == 0 ? FIRST_COLOR_BIT : LAST_COLOR_BIT;
                uint owned_particles = (phases & (PASS_PREDICT | PASS_COLLIDE)) != 0 ? self.root.particle_count : 0;
                self.run(self.root.count + owned_particles)!;
            }
        }
    }
    self.root.phases = PASS_OUTPUT;
    return self.run(self.root.particle_count, writes_output: true);
}

fn void? StepRecorder.record_single(&self, bool first) {
    self.root.phases = first ? PASS_INITIALIZE : 0;
    return self.renderer.dispatch({
        .shader   = self.stage,
        .root     = material::@as_bytes(self.root),
        .groups   = { 1, 1, 1 },
        .writes   = self.state_writes[..],
        .geometry = self.output,
    });
}

// The due steps are taken here, so a frame that is not submitted loses them.
fn void? step_cloth(GpuCloths* cloths, Renderer* renderer, Scene* scene, ClothSlot* slot) @private {
    Node* node = scene.node(slot.cloth);
    ClothState* state = scene.get(node, Cloth).state;
    ClothDeviceStep* device = &state.device;
    uint steps = device.steps;
    if (!steps) return;

    device.steps = 0;
    ClothDesc* desc = &state.desc;
    if (desc.substeps > uint::max / steps) return c3d::CAPACITY_EXCEEDED~;

    bool first = !slot.started;
    if (first) {
        slot.started = true;
        slot.pending = true;
        slot.first_frame = renderer.frame_index;
    }

    float substep_seconds = device.step_seconds / (float)desc.substeps;
    Vec3 gravity = device.gravity * desc.gravity_scale;
    ulong positions = (ulong)renderer.buffer_address(cloths.positions) + slot.first_particle * Vec4::size;
    ulong work = (ulong)renderer.buffer_address(cloths.work);
    ulong velocities = work + (ulong)(cloths.desc.max_particles + slot.first_particle) * Vec4::size;
    ulong tables = (ulong)renderer.buffer_address(cloths.tables) + slot.tables_offset;
    GeometryWrite[1] output = {{
        .geometry     = slot.geometry,
        .streams      = { .positions = true, .normals = true },
        .local_bounds = slot.bounds,
    }};
    StepRecorder recorder = {
        .renderer     = renderer,
        .stage        = slot.shape == ClothStepShape.SINGLE ? cloths.stages.single : cloths.stages.fused,
        .state_writes = { cloths.positions, cloths.work },
        .output       = output[..],
        .root         = {
            .positions          = positions,
            .predicted          = work + slot.first_particle * Vec4::size,
            .velocities         = velocities,
            .edges              = tables + slot.tables.edges,
            .initial            = tables + slot.tables.initial,
            .rest               = tables + slot.tables.rest,
            .marks              = tables + slot.tables.marks,
            .color_starts       = tables + slot.tables.color_starts,
            .adjacency          = tables + slot.tables.adjacency,
            .triangles          = tables + slot.tables.triangles,
            .geometry_positions = (ulong)renderer.geometry_stream_address(slot.geometry, GeometryStream.POSITIONS)!,
            .geometry_normals   = (ulong)renderer.geometry_stream_address(slot.geometry, GeometryStream.NORMALS)!,
            .anchor_frame       = bitcast(device.anchor, float[16]),
            .target_frame       = bitcast(device.target, float[16]),
            .inverse_world      = bitcast(maths::inverse_affine(node.world), float[16]),
            .gravity_step       = { gravity.x, gravity.y, gravity.z, substep_seconds },
            .sphere             = sphere_of(scene, state),
            .particle_count     = slot.particle_count,
            .stiffness          = 1 - math::pow(1 - desc.stretch_stiffness, 1 / (float)desc.iterations),
            .damping            = math::max(0.0f, 1 - desc.damping * substep_seconds),
            .ground             = desc.collide_ground ? desc.ground_height + desc.thickness : NO_GROUND,
            .substeps           = steps * desc.substeps,
            .iterations         = desc.iterations,
            .color_count        = state.edge_colors,
        },
    };
    if (slot.shape == ClothStepShape.SINGLE) return recorder.record_single(first);

    return recorder.record_fused(state.edge_color_starts[:state.edge_colors + 1], first);
}

// The sphere is placed at its owner's pose of this update; one whose owner is gone does not push.
fn float[4] sphere_of(Scene* scene, ClothState* state) @private {
    if (!state.shapes.len) return {};

    ClothShape* shape = &state.shapes[0];
    Entity owner = state.bodies[shape.body].owner;
    if (!scene.world.is_alive(owner)) return {};

    maths::Transform pose = maths::transform_from_mat4(scene.node(owner).world);
    pose.scale = { 1, 1, 1 };
    Vec3 center = maths::transform_point(pose.to_mat4().mul(shape.local.to_mat4()), shape.start);
    return { center.x, center.y, center.z, shape.radius + state.desc.thickness };
}
