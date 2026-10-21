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
const uint PASS_SHAPES @private = 512; // mirrored in cloth_step.glsl
const uint PASS_FIRST_CONTACT @private = 1024; // mirrored in cloth_step.glsl
const uint SHAPE_VECTORS @private = 6; // vec4s of a ShapeGpu; mirrored as CLOTH_SHAPE_VECTORS in cloth_root.glsl
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
    ulong     shapes;
    ulong     push;
    ulong     limits;
    uint      particle_count;
    uint      shape_count;
    float[16] anchor_frame;
    float[16] target_frame;
    float[16] inverse_world;
    float[4]  gravity_step;
    float[4]  wind;
    float[4]  aero;
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
    uint      payload_offset;
    float     contact_tolerance;
    uint[2]   padding;
}

$assert ClothRoot::size == 480;
$assert ClothRoot::size % render::STREAM_ALIGNMENT == 0; // the roots of a batch sit at this stride and are read as 16-byte aligned
$assert $reflect(ClothRoot.shapes).offset == 128;
$assert $reflect(ClothRoot.particle_count).offset == 152;
$assert $reflect(ClothRoot.anchor_frame).offset == 160;
$assert $reflect(ClothRoot.target_frame).offset == 224;
$assert $reflect(ClothRoot.inverse_world).offset == 288;
$assert $reflect(ClothRoot.gravity_step).offset == 352;
$assert $reflect(ClothRoot.wind).offset == 368;
$assert $reflect(ClothRoot.aero).offset == 384;
$assert $reflect(ClothRoot.stretch_stiffness).offset == 400;
$assert $reflect(ClothRoot.features).offset == 432;
$assert $reflect(ClothRoot.stiffness).offset == 460;
$assert $reflect(ClothRoot.payload_offset).offset == 464;

// Mirrors the shape records of cloth_step.glsl: six vectors a shape, staged once per step.
struct ShapeGpu @private {
    float[4] solved_position;  // owner position at the request's start; w is the radius with the contact offset
    float[4] solved_rotation;
    float[4] current_position; // owner position at the request's end
    float[4] current_rotation;
    float[4] start;            // owner-local end points of the segment
    float[4] end;
}

$assert ShapeGpu::size == SHAPE_VECTORS * Vec4::size;

struct StepRecorder @private {
    Renderer*       renderer;
    ClothRoot       root;
    ComputeShaderId stage;
    BufferId[2]     state_writes;
    GeometryWrite[] output;
    char[]          staging;       // the root, then the reference pairs that follow it
    usz             payload_bytes; // zero when the cloth stages neither reference pairs nor shapes
}

// Parameters of the small cloths of one update: roots at a fixed stride, then the reference pairs they stage.
struct StepBatch @private {
    ClothRoot[]     roots;   // the leading cells of staging; parameters of workgroup i
    char[]          staging; // roots, then reference pairs; the fused shape borrows its start between batches
    GeometryWrite[] outputs; // geometry workgroup i writes
    ClothSlot*[]    members; // cloth workgroup i steps
    usz             count;
}

fn void StepBatch.add(&self, ClothSlot* slot, ClothRoot root) {
    root.phases = slot.started ? 0 : PASS_INITIALIZE;
    self.roots[self.count] = root;
    self.outputs[self.count] = output_of(slot);
    self.members[self.count] = slot;
    self.count++;
}

fn char[] StepRecorder.root_bytes(&self, bool with_payload) {
    if (!with_payload || !self.payload_bytes) return material::@as_bytes(self.root);

    self.staging[:ClothRoot::size] = material::@as_bytes(self.root)[..];
    return self.staging[:ClothRoot::size + self.payload_bytes];
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
    bool shapes = (self.root.features & FEATURE_SHAPES) != 0;

    if (self.payload_bytes) {
        self.root.phases = PASS_STAGE;
        self.run((uint)(self.payload_bytes / Vec4::size), with_payload: true)!;
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
                    if (shapes) {
                        phases |= PASS_SHAPES;
                        if (iteration == 0) phases |= PASS_FIRST_CONTACT;
                    }
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

// Roots first, so the cell count of the staging block bounds the cloths; the reference pairs and shapes of every cloth after them.
fn StepBatch create_step_batch(Allocator allocator, sz capacity, sz max_particles) @private {
    sz payload_bytes = 2 * max_particles * Vec4::size + capacity * cloth::MAX_DEVICE_SHAPES * ShapeGpu::size;
    sz payload_cells = (payload_bytes + ClothRoot::size - 1) / ClothRoot::size;
    ClothRoot[] cells = alloc::new_array(allocator, ClothRoot, capacity + payload_cells);
    return {
        .roots   = cells[:capacity],
        .staging = ((char*)cells.ptr)[:cells.len * ClothRoot::size],
        .outputs = alloc::new_array(allocator, GeometryWrite, capacity),
        .members = alloc::new_array(allocator, ClothSlot*, capacity),
    };
}

fn void destroy_step_batch(Allocator allocator, StepBatch* batch) @private {
    alloc::free(allocator, batch.roots.ptr);
    alloc::free(allocator, batch.outputs.ptr);
    alloc::free(allocator, batch.members.ptr);
    *batch = {};
}

fn GeometryWrite output_of(ClothSlot* slot) @private {
    return {
        .geometry     = slot.geometry,
        .streams      = { .positions = true, .normals = true },
        .local_bounds = slot.bounds,
    };
}

// The first step counts as taken once it is recorded; a cloth whose recording faulted initializes again.
fn void note_first_step(ClothSlot* slot, Renderer* renderer) @private {
    if (slot.started) return;

    slot.started = true;
    slot.pending = true;
    slot.first_frame = renderer.frame_index;
}

fn float pass_stiffness(float stiffness, uint iterations) @private {
    return 1 - math::pow(1 - stiffness, 1 / (float)iterations);
}

// Pairs of solved and current reference positions of a skinned cloth, then its shapes; returns the bytes written.
fn usz stage_payload(char[] destination, ClothState* state, uint features) @private {
    usz written;
    if ((features & FEATURE_REFERENCE) != 0) {
        Vec4[] pairs = ((Vec4*)destination.ptr)[:2 * state.positions.len];
        foreach (index, solved : state.solved_reference) {
            Vec3 current = state.current_reference[index];
            pairs[2 * index] = { solved.x, solved.y, solved.z, 0 };
            pairs[2 * index + 1] = { current.x, current.y, current.z, 0 };
        }
        written = pairs.len * Vec4::size;
    }

    ShapeGpu[] records = ((ShapeGpu*)&destination[written])[:state.device.shape_count];
    foreach (index, &record : records) {
        ClothDeviceShape* shape = &state.device_shapes[index];
        Vec3 solved = shape.solved.position;
        Vec3 current = shape.current.position;
        *record = {
            .solved_position  = { solved.x, solved.y, solved.z, shape.reach },
            .solved_rotation  = bitcast(shape.solved.rotation.v, float[4]),
            .current_position = { current.x, current.y, current.z, 0 },
            .current_rotation = bitcast(shape.current.rotation.v, float[4]),
            .start            = { shape.start.x, shape.start.y, shape.start.z, 0 },
            .end              = { shape.end.x, shape.end.y, shape.end.z, 0 },
        };
    }
    return written + records.len * ShapeGpu::size;
}

// The due steps are taken here, so a frame that is not submitted loses them.
fn void? step_cloth(GpuCloths* cloths, Renderer* renderer, Scene* scene, ClothSlot* slot) @private {
    ClothState* state = scene.get(scene.node(slot.cloth), Cloth).state;
    uint steps = state.device.steps;
    if (!steps) return;

    state.device.steps = 0;
    if (state.desc.substeps > uint::max / steps) return c3d::CAPACITY_EXCEEDED~;

    ClothRoot root = step_root(cloths, renderer, scene, slot, steps)!;
    if (slot.shape == ClothStepShape.SINGLE) {
        cloths.batch.add(slot, root);
        return;
    }

    usz payload_bytes = stage_payload(cloths.batch.staging[ClothRoot::size..], state, root.features);
    if (payload_bytes) root.payload_offset = ClothRoot::size;
    GeometryWrite[1] output = { output_of(slot) };
    StepRecorder recorder = {
        .renderer      = renderer,
        .stage         = cloths.stages.fused,
        .state_writes  = { cloths.positions, cloths.work },
        .output        = output[..],
        .staging       = cloths.batch.staging,
        .payload_bytes = payload_bytes,
        .root          = root,
    };
    uint[] pass_starts = ((uint*)&cloths.tables_cpu[slot.tables_offset + slot.tables.color_starts])[:slot.passes + 1];
    recorder.record_fused(pass_starts, !slot.started)!;
    note_first_step(slot, renderer);
}

fn void? record_batch(GpuCloths* cloths, Renderer* renderer, Scene* scene) @private {
    StepBatch* batch = &cloths.batch;
    usz count = batch.count;
    batch.count = 0;
    if (!count || !renderer.frame_open) return; // an earlier fault closed the frame and took the batch with it

    usz parameter_bytes = count * ClothRoot::size;
    foreach (index, slot : batch.members[:count]) {
        ClothRoot* root = &batch.roots[index];
        ClothState* state = scene.get(scene.node(slot.cloth), Cloth).state;
        usz staged = stage_payload(batch.staging[parameter_bytes..], state, root.features);
        if (!staged) continue;

        root.payload_offset = (uint)parameter_bytes;
        parameter_bytes += staged;
    }

    BufferId[2] state_writes = { cloths.positions, cloths.work };
    renderer.dispatch({
        .shader   = cloths.stages.single,
        .root     = batch.staging[:parameter_bytes],
        .groups   = { (uint)count, 1, 1 },
        .writes   = state_writes[..],
        .geometry = batch.outputs[:count],
    })!;
    foreach (slot : batch.members[:count]) note_first_step(slot, renderer);
}

fn ClothRoot? step_root(
    GpuCloths* cloths,
    Renderer* renderer,
    Scene* scene,
    ClothSlot* slot,
    uint steps,
) @private {
    Node* node = scene.node(slot.cloth);
    ClothState* state = scene.get(node, Cloth).state;
    ClothDeviceStep* device = &state.device;
    ClothDesc* desc = &state.desc;

    float substep_seconds = device.step_seconds / (float)desc.substeps;
    Vec3 gravity = device.gravity * desc.gravity_scale;
    if (device.shape_count > cloth::MAX_DEVICE_SHAPES) return c3d::CAPACITY_EXCEEDED~;

    uint features = slot.features;
    if (device.wind_present) features |= FEATURE_WIND;
    Wind* wind = &device.wind;

    ulong vector = Vec4::size;
    usz capacity = cloths.desc.max_particles;
    ulong positions = (ulong)renderer.buffer_address(cloths.positions) + slot.first_particle * vector;
    ulong work = (ulong)renderer.buffer_address(cloths.work);
    ulong tables = (ulong)renderer.buffer_address(cloths.tables) + slot.tables_offset;
    usz shape_stride = cloth::MAX_DEVICE_SHAPES * ShapeGpu::size;
    ulong shapes = work + WORK_SECTIONS * capacity * vector + slot_index(cloths, slot) * shape_stride;
    return {
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
        .shapes             = shapes,
        .push               = work + (PUSH_SECTION * capacity + slot.first_particle) * vector,
        .limits             = tables + slot.tables.limits,
        .particle_count     = slot.particle_count,
        .shape_count        = device.shape_count,
        .anchor_frame       = bitcast(device.anchor, float[16]),
        .target_frame       = bitcast(device.target, float[16]),
        .inverse_world      = bitcast(maths::inverse_affine(node.world), float[16]),
        .gravity_step       = { gravity.x, gravity.y, gravity.z, substep_seconds },
        .wind               = { wind.velocity.x, wind.velocity.y, wind.velocity.z, wind.max_speed },
        .aero               = {
            0.5f * cloth::AIR_DENSITY * desc.drag_coefficient,
            cloth::AIR_DENSITY * desc.lift_coefficient,
            0,
            0,
        },
        .stretch_stiffness  = pass_stiffness(desc.stretch_stiffness, desc.iterations),
        .bend_stiffness     = pass_stiffness(desc.bend_stiffness, desc.iterations),
        .damping            = math::max(0.0f, 1 - desc.damping * substep_seconds),
        .ground             = desc.collide_ground ? desc.ground_height + desc.thickness : NO_GROUND,
        .substeps           = steps * desc.substeps,
        .iterations         = desc.iterations,
        .color_count        = slot.passes,
        .edge_colors        = slot.edge_colors,
        .features           = features,
        .contact_tolerance  = desc.collisions.contact_tolerance,
    };
}
