module c3d::render::cloth_gpu @feat(C3D_PHYSICS_GPU);

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics @public;
import c3d::physics::cloth @public;
import c3d::render;
import c3d::scene;
import std::math;

<*
 Most particles of a cloth that steps in one dispatch; a larger cloth steps in fused passes.
*>
const uint DEVICE_SINGLE_PASS_PARTICLES = 1_500; // one 128-thread group beats fused passes up to about 1,600 particles on an RTX 4090 (0.52 against 0.79 ms at 1,089) and records about 20x less CPU; it grows about 0.53 µs per particle

<*
 Budgets of one device cloth context.
*>
struct GpuClothsDesc {
    uint max_cloths;    // cloths stepped at once; the workgroups of the one dispatch the small ones share
    uint max_particles; // across every cloth; 96 B of device state each, 16 B of it copied out every frame, and 32 B of host staging
    usz  table_bytes;   // topology, rest, color and routing tables of every cloth; about 280 B per particle of a bent sheet, so tables bound before particles do
}

<*
 Most cloths a context holds; Vulkan guarantees this many workgroups in one dispatch.
*>
const uint MAX_GPU_CLOTHS = 65_535;

<*
 Budgets that fit a handful of flags or capes.
*>
const GpuClothsDesc GPU_CLOTHS_DEFAULT = { .max_cloths = 64, .max_particles = 65_536, .table_bytes = 4 * 1024 * 1024 }; // 6 MiB of device state, 4 MiB of tables, 3 MiB of host copies of the positions and 2 MiB of staging; three of the renderer's 64 buffers

<*
 How a step lays its passes over dispatches.
*>
enum ClothStepShape {
    SINGLE, // one dispatch for the whole step
    FUSED,  // one dispatch per color pass, then the output
}

const usz WORK_SECTIONS @private = 5; // vec4 per particle for predicted positions, velocities and lambdas, then two for the reference pair

const String FUSED_KEY @private = "c3d_physics/cloth_fused";
const String SINGLE_KEY @private = "c3d_physics/cloth_single";
const String FUSED_LEAN_KEY @private = "c3d_physics/cloth_fused_lean";
const String SINGLE_LEAN_KEY @private = "c3d_physics/cloth_single_lean";

struct ClothStages @private {
    ComputeShaderId fused;
    ComputeShaderId single;
    ComputeShaderId fused_lean;  // the same steps without soft attachments, transport, wind or skinned references
    ComputeShaderId single_lean;
}

<*
 Compute stages, shared buffers and per-cloth ranges of the application's GPU cloths.
*>
struct GpuCloths {
    Allocator     allocator;
    GpuClothsDesc desc;
    ClothStages   stages;
    ClothSlot[]   slots;
    StepBatch     batch;        // scratch of the update in progress
    BufferId      positions;    // READBACK; the world positions of every cloth, inverse mass in w
    BufferId      work;         // predicted positions, velocities, soft attachment lambdas, then reference pairs
    BufferId      tables;       // UPLOAD; topology, rest and routing tables
    char[]        tables_cpu;   // the tables buffer as the CPU keeps it
    bool          tables_dirty; // the buffer lacks a cloth's tables
    bool          tables_sent;  // an upload is recorded and its frame not yet known to be submitted
    ulong         tables_frame; // frame that recorded it
    uint          stamp;
}

<*
 Step shape a cloth of this many particles takes.
 @pure
*>
fn ClothStepShape step_shape(uint particle_count) {
    return particle_count <= DEVICE_SINGLE_PASS_PARTICLES ? ClothStepShape.SINGLE : ClothStepShape.FUSED;
}

<*
 Create a context and add its compute stages to the store.
 @param [&inout] assets : "The store the renderer draws from."
 @return? AssetStore.add_compute_shader!
 @require desc.max_cloths > 0 && desc.max_cloths <= MAX_GPU_CLOTHS && desc.max_particles > 0 && desc.table_bytes > 0
*>
fn GpuCloths? create_gpu_cloths(
    Allocator allocator,
    AssetStore* assets,
    GpuClothsDesc desc = GPU_CLOTHS_DEFAULT,
) {
    ClothStages stages = {
        .fused = stage(assets, FUSED_KEY, physics::CLOTH_FUSED_SPIRV[..])!,
        .single = stage(assets, SINGLE_KEY, physics::CLOTH_SINGLE_SPIRV[..])!,
        .fused_lean = stage(assets, FUSED_LEAN_KEY, physics::CLOTH_FUSED_CLOTH_LEAN_SPIRV[..])!,
        .single_lean = stage(assets, SINGLE_LEAN_KEY, physics::CLOTH_SINGLE_CLOTH_LEAN_SPIRV[..])!,
    };
    return {
        .allocator = allocator,
        .desc = desc,
        .stages = stages,
        .slots = alloc::new_array(allocator, ClothSlot, (sz)desc.max_cloths),
        .batch = create_step_batch(allocator, (sz)desc.max_cloths, (sz)desc.max_particles),
        .tables_cpu = alloc::new_array(allocator, char, (sz)desc.table_bytes),
    };
}

<*
 Retire every buffer of the context after its last submitted use.
 @param [&inout] cloths : "Left zeroed."
 @param [&inout] renderer : "The renderer every update recorded into."
*>
fn void destroy_gpu_cloths(GpuCloths* cloths, Renderer* renderer) {
    BufferId[3] buffers = { cloths.positions, cloths.work, cloths.tables };
    foreach (buffer : buffers) {
        if (buffer.generation) (void)renderer.destroy_buffer(buffer);
    }
    alloc::free(cloths.allocator, cloths.slots.ptr);
    destroy_step_batch(cloths.allocator, &cloths.batch);
    alloc::free(cloths.allocator, cloths.tables_cpu.ptr);
    *cloths = {};
}

<*
 Record the due steps of every prepared GPU cloth.
 An aborted frame is replayed; one followed by FRAMES_IN_FLIGHT frames without an update counts as applied.
 A fault that closes the frame ends the update and is returned.
 @param [&inout] cloths : "Retires the ranges of cloths it no longer sees."
 @param [&inout] renderer : "Frame open, with no dispatch recorded yet."
 @param [&inout] assets : "Holds the output geometry of every cloth."
 @param [&inout] scene : "Registered; matrices current; cloths updated by update_cloths."
 @return? c3d::CAPACITY_EXCEEDED, Renderer.create_buffer!, Renderer.write_buffer!, Renderer.upload_geometry!
 @return? Renderer.geometry_stream_address!, Renderer.dispatch!
 @require renderer.frame_open
*>
fn void? update(GpuCloths* cloths, Renderer* renderer, AssetStore* assets, Scene* scene) {
    cloths.stamp++;
    settle_tables(cloths, renderer);
    foreach (&slot : cloths.slots) {
        if (slot.cloth.generation) settle_slot(slot, renderer);
    }

    scene.@each(Cloth; entity, cloth) {
        if (runs_on_device(cloth)) keep_cloth(cloths, scene, entity);
    };
    retire_unseen(cloths);

    fault failure;
    scene.@each(Cloth; entity, cloth) {
        if (runs_on_device(cloth)) {
            if (catch excuse = admit_cloth(
                cloths:   cloths,
                renderer: renderer,
                assets:   assets,
                scene:    scene,
                entity:   entity,
            )) {
                if (!failure) failure = excuse;
            }
        }
    };

    if (catch upload_failure = send_tables(cloths, renderer)) {
        if (!failure) failure = upload_failure;
    } else {
        // The fused cloths record first: they borrow the start of the block the batch assembles its roots in.
        if (catch excuse = step_cloths(cloths, renderer, scene, ClothStepShape.FUSED)) {
            if (!failure) failure = excuse;
        }
        if (catch excuse = step_cloths(cloths, renderer, scene, ClothStepShape.SINGLE)) {
            if (!failure) failure = excuse;
        }
        if (catch excuse = record_batch(cloths, renderer, scene)) {
            if (!failure) failure = excuse;
        }
    }
    if (failure) return failure~;
}

<*
 World positions of a GPU cloth as the frame FRAMES_IN_FLIGHT frames earlier left them.
 The view borrows mapped memory and is valid until the next begin_frame.
 @param [&inout] renderer : "Frame open."
 @param cloth : "A cloth the latest update packed."
 @return "Vectors of world position and inverse mass, one per particle."
 @return? render::NOT_READY, c3d::INVALID_ID, Renderer.read_buffer!
 @require renderer.frame_open
*>
fn Vec4[]? read_positions(GpuCloths* cloths, Renderer* renderer, Entity cloth) {
    ClothSlot* slot = find_slot(cloths, cloth);
    if (!slot) return c3d::INVALID_ID~;
    if (!slot.started || renderer.frame_index < slot.first_frame + render::FRAMES_IN_FLIGHT) {
        return render::NOT_READY~;
    }

    char[] bytes = renderer.read_buffer(cloths.positions)!;
    return ((Vec4*)&bytes[slot.first_particle * Vec4::size])[:slot.particle_count];
}

fn void? step_cloths(GpuCloths* cloths, Renderer* renderer, Scene* scene, ClothStepShape shape) @private {
    fault failure;
    foreach (&slot : cloths.slots) {
        if (!renderer.frame_open) break; // a dispatch fault closed the frame; the first fault is returned below
        if (!slot.cloth.generation || slot.stamp != cloths.stamp || slot.shape != shape) continue;

        if (catch excuse = step_cloth(
            cloths:   cloths,
            renderer: renderer,
            scene:    scene,
            slot:     slot,
        )) {
            if (!failure) failure = excuse;
        }
    }
    if (failure) return failure~;
}

fn bool runs_on_device(Cloth* cloth) @private {
    return cloth.is_prepared() && cloth.state.desc.execution == ClothExecution.GPU;
}

fn ComputeShaderId? stage(AssetStore* assets, String key, char[] spirv) @private {
    if (try found = assets.find_compute_shader(key)) return found;

    ComputeShaderDesc desc = { .compute = spirv };
    return assets.add_compute_shader(&desc, key);
}

// A table upload that no submitted frame carried is sent again; the tables are rewritten whole, so a replay is safe.
fn void settle_tables(GpuCloths* cloths, Renderer* renderer) @private {
    if (!cloths.tables_sent) return;

    bool landed = renderer.frame_was_submitted(cloths.tables_frame)
        || renderer.frame_index - cloths.tables_frame > render::FRAMES_IN_FLIGHT;
    cloths.tables_sent = false;
    if (!landed) cloths.tables_dirty = true;
}

fn void? create_buffers(GpuCloths* cloths, Renderer* renderer) @private {
    if (cloths.positions.generation) return;

    usz particles = cloths.desc.max_particles;
    BufferId positions = renderer.create_buffer({
        .size       = particles * Vec4::size,
        .usage      = BufferUsage.READBACK,
        .debug_name = "cloth_positions",
    })!;
    defer catch (void)renderer.destroy_buffer(positions);
    BufferId work = renderer.create_buffer({
        .size       = WORK_SECTIONS * particles * Vec4::size,
        .debug_name = "cloth_work",
    })!;
    defer catch (void)renderer.destroy_buffer(work);
    BufferId tables = renderer.create_buffer({
        .size       = cloths.desc.table_bytes,
        .usage      = BufferUsage.UPLOAD,
        .debug_name = "cloth_tables",
    })!;

    cloths.positions = positions;
    cloths.work = work;
    cloths.tables = tables;
}

fn void? send_tables(GpuCloths* cloths, Renderer* renderer) @private {
    usz used = cloths.tables_used();
    if (!used) return;

    create_buffers(cloths, renderer)!;
    if (!cloths.tables_dirty) return;

    renderer.write_buffer(cloths.tables, cloths.tables_cpu[:used])!;
    cloths.tables_dirty = false;
    cloths.tables_sent = true;
    cloths.tables_frame = renderer.frame_index;
}
