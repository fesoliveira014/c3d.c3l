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
const uint PASS_SOFT_BEFORE @private = 64; // mirrored in cloth_step.glsl
const uint PASS_SOFT_AFTER @private = 128; // mirrored in cloth_step.glsl
const uint PASS_STAGE @private = 256; // mirrored in cloth_step.glsl
const float NO_GROUND @private = -1e30f; // below every particle; disables the ground contact

// Mirrors ClothRoot in cloth_root.glsl.
struct ClothRoot @private {
    ulong     positions;
    ulong     predicted;
    ulong     velocities;
    ulong     lambdas;
    ulong     reference;
    ulong     constraints;
    ulong     initial;
    ulong     rest;
    ulong     marks;
    ulong     color_starts;
    ulong     adjacency;
    ulong     triangles;
    ulong     geometry_positions;
    ulong     geometry_normals;
    ulong     soft;
    ulong     transport;
    float[16] anchor_frame;
    float[16] target_frame;
    float[16] inverse_world;
    float[4]  gravity_step;
    float[4]  sphere;
    float[4]  wind;
    float[4]  aero;
    uint      particle_count;
    float     stretch_stiffness;
    float     bend_stiffness;
    float     damping;
    float     ground;
    uint      substeps;
    uint      iterations;
    uint      color_count;
    uint      edge_colors;
    uint      features;
    uint      first;
    uint      count;
    uint      phases;
    uint      member_bit;
    float     progress;
    float     previous_progress;
    float     stiffness;
}

$assert ClothRoot::size == 456;
$assert $reflect(ClothRoot.anchor_frame).offset == 128;
$assert $reflect(ClothRoot.target_frame).offset == 192;
$assert $reflect(ClothRoot.inverse_world).offset == 256;
$assert $reflect(ClothRoot.gravity_step).offset == 320;
$assert $reflect(ClothRoot.sphere).offset == 336;
$assert $reflect(ClothRoot.wind).offset == 352;
$assert $reflect(ClothRoot.aero).offset == 368;
$assert $reflect(ClothRoot.particle_count).offset == 384;
$assert $reflect(ClothRoot.features).offset == 420;
$assert $reflect(ClothRoot.stiffness).offset == 448;

const usz PAYLOAD_OFFSET @private = (ClothRoot::size + render::STREAM_ALIGNMENT - 1)
    / render::STREAM_ALIGNMENT * render::STREAM_ALIGNMENT; // the reference payload follows its root here; mirrored as CLOTH_PAYLOAD_OFFSET in cloth_root.glsl

$assert PAYLOAD_OFFSET == 464;

struct StepRecorder @private {
    Renderer*       renderer;
    ClothRoot       root;
    ComputeShaderId stage;
    BufferId[2]     state_writes;
    GeometryWrite[] output;
    char[]          staging;       // the root, then the reference payload that follows it
    usz             payload_bytes; // zero when the cloth keeps its reference in matrices
}

fn char[] StepRecorder.root_bytes(&self, bool with_payload) {
    if (!with_payload || !self.payload_bytes) return material::@as_bytes(self.root);

    self.staging[:ClothRoot::size] = material::@as_bytes(self.root)[..];
    return self.staging[:PAYLOAD_OFFSET + self.payload_bytes];
}

fn void? StepRecorder.run(&self, uint threads, bool writes_output = false, bool with_payload = false) {
    return self.renderer.dispatch({
        .shader   = self.stage,
        .root     = self.root_bytes(with_payload),
        .groups   = { (threads + FUSED_GROUP_SIZE - 1) / FUSED_GROUP_SIZE, 1, 1 },
        .writes   = self.state_writes[..],
        .geometry = writes_output ? self.output : {},
    });
}

// Predict joins the first pass of a substep, collide the last pass of each iteration, integrate the last pass.
// A triangle's three edges take three colors, so predict and integrate never share a pass.
fn void? StepRecorder.record_fused(&self, uint[] pass_starts, bool first) {
    uint passes = self.root.color_count;
    uint substeps = self.root.substeps;
    bool soft = (self.root.features & FEATURE_SOFT) != 0;
    bool windy = (self.root.features & FEATURE_WIND) != 0;

    if ((self.root.features & FEATURE_REFERENCE) != 0) {
        self.root.phases = PASS_STAGE;
        self.run(2 * self.root.particle_count, with_payload: true)!;
    }
    // The wind gather reads every neighbour's start state, so it cannot share a pass with the initialization.
    if (first && windy) {
        self.root.phases = PASS_INITIALIZE;
        self.run(self.root.particle_count)!;
    }
    bool merge_initialize = first && !windy;

    for (uint substep = 0; substep < substeps; substep++) {
        self.root.progress = (float)(substep + 1) / (float)substeps;
        self.root.previous_progress = (float)substep / (float)substeps;
        for (uint iteration = 0; iteration < self.root.iterations; iteration++) {
            for (uint pass = 0; pass < passes; pass++) {
                uint phases = substep + 1 == substeps ? PASS_FINAL_SUBSTEP : 0;
                if (iteration == 0 && pass == 0) {
                    phases |= PASS_PREDICT;
                    if (soft) phases |= PASS_SOFT_BEFORE;
                    if (merge_initialize && substep == 0) phases |= PASS_INITIALIZE;
                }
                if (pass + 1 == passes) {
                    phases |= PASS_COLLIDE;
                    if (iteration + 1 == self.root.iterations) {
                        phases |= PASS_INTEGRATE;
                    } else if (soft) {
                        phases |= PASS_SOFT_AFTER;
                    }
                }

                self.root.first = pass_starts[pass];
                self.root.count = pass_starts[pass + 1] - pass_starts[pass];
                self.root.phases = phases;
                self.root.member_bit = pass == 0 ? FIRST_COLOR_BIT : LAST_COLOR_BIT;
                self.root.stiffness = pass < self.root.edge_colors
                    ? self.root.stretch_stiffness
                    : self.root.bend_stiffness;
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
        .root     = self.root_bytes(true),
        .groups   = { 1, 1, 1 },
        .writes   = self.state_writes[..],
        .geometry = self.output,
    });
}

fn float pass_stiffness(float stiffness, uint iterations) @private {
    return 1 - math::pow(1 - stiffness, 1 / (float)iterations);
}

// Pairs of solved and current reference positions, in the staging block after the root.
fn usz stage_reference(char[] staging, ClothState* state) @private {
    Vec4[] pairs = ((Vec4*)&staging[PAYLOAD_OFFSET])[:2 * state.positions.len];
    foreach (index, solved : state.solved_reference) {
        Vec3 current = state.current_reference[index];
        pairs[2 * index] = { solved.x, solved.y, solved.z, 0 };
        pairs[2 * index + 1] = { current.x, current.y, current.z, 0 };
    }
    return pairs.len * Vec4::size;
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
    uint features = slot.features;
    Wind* wind = &device.wind;
    if (device.wind_present) features |= FEATURE_WIND;
    usz payload_bytes = (features & FEATURE_REFERENCE) != 0 ? stage_reference(cloths.staging, state) : 0;

    ulong vector = Vec4::size;
    usz capacity = cloths.desc.max_particles;
    ulong positions = (ulong)renderer.buffer_address(cloths.positions) + slot.first_particle * vector;
    ulong work = (ulong)renderer.buffer_address(cloths.work);
    ulong tables = (ulong)renderer.buffer_address(cloths.tables) + slot.tables_offset;
    GeometryWrite[1] output = {{
        .geometry     = slot.geometry,
        .streams      = { .positions = true, .normals = true },
        .local_bounds = slot.bounds,
    }};
    StepRecorder recorder = {
        .renderer      = renderer,
        .stage         = slot.shape == ClothStepShape.SINGLE ? cloths.stages.single : cloths.stages.fused,
        .state_writes  = { cloths.positions, cloths.work },
        .output        = output[..],
        .staging       = cloths.staging,
        .payload_bytes = payload_bytes,
        .root          = {
            .positions          = positions,
            .predicted          = work + slot.first_particle * vector,
            .velocities         = work + (capacity + slot.first_particle) * vector,
            .lambdas            = work + (2 * capacity + slot.first_particle) * vector,
            .reference          = work + (3 * capacity + 2 * (usz)slot.first_particle) * vector,
            .constraints        = tables + slot.tables.constraints,
            .initial            = tables + slot.tables.initial,
            .rest               = tables + slot.tables.rest,
            .marks              = tables + slot.tables.marks,
            .color_starts       = tables + slot.tables.color_starts,
            .adjacency          = tables + slot.tables.adjacency,
            .triangles          = tables + slot.tables.triangles,
            .geometry_positions = (ulong)renderer.geometry_stream_address(slot.geometry, GeometryStream.POSITIONS)!,
            .geometry_normals   = (ulong)renderer.geometry_stream_address(slot.geometry, GeometryStream.NORMALS)!,
            .soft               = tables + slot.tables.soft,
            .transport          = tables + slot.tables.transport,
            .anchor_frame       = bitcast(device.anchor, float[16]),
            .target_frame       = bitcast(device.target, float[16]),
            .inverse_world      = bitcast(maths::inverse_affine(node.world), float[16]),
            .gravity_step       = { gravity.x, gravity.y, gravity.z, substep_seconds },
            .sphere             = sphere_of(scene, state),
            .wind               = { wind.velocity.x, wind.velocity.y, wind.velocity.z, wind.max_speed },
            .aero               = {
                0.5f * cloth::AIR_DENSITY * desc.drag_coefficient,
                cloth::AIR_DENSITY * desc.lift_coefficient,
                0,
                0,
            },
            .particle_count     = slot.particle_count,
            .stretch_stiffness  = pass_stiffness(desc.stretch_stiffness, desc.iterations),
            .bend_stiffness     = pass_stiffness(desc.bend_stiffness, desc.iterations),
            .damping            = math::max(0.0f, 1 - desc.damping * substep_seconds),
            .ground             = desc.collide_ground ? desc.ground_height + desc.thickness : NO_GROUND,
            .substeps           = steps * desc.substeps,
            .iterations         = desc.iterations,
            .color_count        = slot.passes,
            .edge_colors        = slot.edge_colors,
            .features           = features,
        },
    };
    if (slot.shape == ClothStepShape.SINGLE) return recorder.record_single(first);

    uint[] pass_starts = ((uint*)&cloths.tables_cpu[slot.tables_offset + slot.tables.color_starts])[:slot.passes + 1];
    return recorder.record_fused(pass_starts, first);
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
