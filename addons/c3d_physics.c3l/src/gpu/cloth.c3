module c3d::render::cloth_gpu @feat(C3D_PHYSICS_GPU);

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::material;
import c3d::maths;
import c3d::physics @public;
import c3d::physics::cloth @public;
import c3d::render;
import c3d::scene;
import std::math;

const uint GROUP_SIZE @private = 64; // mirrored as local_size_x in cloth_root.glsl
const float NO_GROUND @private = -1e30f; // below every particle; disables the ground contact
const float REACH_FACTOR @private = 1; // rest diagonals the bounds grow by; the sheet cannot stretch past its extent
const String INIT_KEY @private = "c3d_physics/cloth_init";
const String PREDICT_KEY @private = "c3d_physics/cloth_predict";
const String PROJECT_KEY @private = "c3d_physics/cloth_project";
const String COLLIDE_KEY @private = "c3d_physics/cloth_collide";
const String INTEGRATE_KEY @private = "c3d_physics/cloth_integrate";
const String OUTPUT_KEY @private = "c3d_physics/cloth_output";

struct Stages @private {
    ComputeShaderId init;
    ComputeShaderId predict;
    ComputeShaderId project;
    ComputeShaderId collide;
    ComputeShaderId integrate;
    ComputeShaderId output;
}

// Mirrors ClothRoot in cloth_root.glsl.
struct ClothRoot @private {
    ulong     positions;
    ulong     predicted;
    ulong     velocities;
    ulong     edges;
    ulong     initial;
    ulong     rest;
    ulong     adjacency;
    ulong     triangles;
    ulong     geometry_positions;
    ulong     geometry_normals;
    float[16] world;
    float[16] inverse_world;
    float[4]  gravity_step;
    float[4]  sphere;
    uint      particle_count;
    uint      first;
    uint      count;
    uint      triangle_count;
    float     stiffness;
    float     damping;
    float     ground;
    float     _pad0;
}

$assert ClothRoot::size == 272;
$assert $reflect(ClothRoot.world).offset == 80;
$assert $reflect(ClothRoot.inverse_world).offset == 144;
$assert $reflect(ClothRoot.gravity_step).offset == 208;
$assert $reflect(ClothRoot.sphere).offset == 224;
$assert $reflect(ClothRoot.particle_count).offset == 240;
$assert $reflect(ClothRoot.stiffness).offset == 256;

struct EdgeGpu @private {
    uint  first;
    uint  second;
    float rest_length;
    uint  _pad0;
}

$assert EdgeGpu::size == 16;

struct Sections @private {
    usz initial;
    usz rest;
    usz edges;
    usz adjacency;
    usz triangles;
    usz total;
}

<*
 Cloth simulated by compute dispatches, with the buffers and settings its steps replay.
*>
struct GpuCloth {
    Allocator                   allocator;
    Entity                      node;
    GeometryId                  geometry;
    BufferId                    positions;    // READBACK: world positions, inverse mass in w
    BufferId                    work;
    BufferId                    constants;
    Stages                      stages;
    Sections                    sections;
    char[]                      pending_constants; // the first step uploads and frees it
    uint                        particle_count;
    uint                        triangle_count;
    uint                        color_count;
    ColorStarts                 color_starts;
    uint                        substeps;
    uint                        iterations;
    float                       stretch_stiffness; // per pass
    float                       damping;
    float                       gravity_scale;
    float[4]                    sphere;
    float                       ground;
    Aabb                        bounds;
    bool                        initialized;
}

struct Recorder @private {
    Renderer* renderer;
    ClothRoot root;
}

<*
 Simulate one fixed step and write the node's geometry positions and normals.
 Pins follow the node's world matrix as it stands now, held for every substep.
 @param [&inout] self : "Records dispatches; the first call also uploads the constants."
 @param [&inout] renderer : "Frame open, before the cloth's mesh is drawn."
 @param [&in] scene : "Holds the cloth's node."
 @param gravity : "World gravity in m/s^2; scaled by the cloth's gravity scale."
 @param step_seconds : "Fixed step length; split over the cloth's substeps."
 @require renderer.frame_open
 @return? Renderer.dispatch!, Renderer.write_buffer!, Renderer.geometry_stream_address!
*>
fn void? GpuCloth.step(&self, Renderer* renderer, Scene* scene, Vec3 gravity, float step_seconds) {
    if (self.pending_constants.len) {
        renderer.write_buffer(self.constants, self.pending_constants)!;
        alloc::free(self.allocator, self.pending_constants.ptr);
        self.pending_constants = {};
    }

    Node* node = scene.node(self.node);
    float substep_seconds = step_seconds / (float)self.substeps;
    ClothRoot root = {
        .positions          = (ulong)renderer.buffer_address(self.positions),
        .predicted          = (ulong)renderer.buffer_address(self.work),
        .velocities         = (ulong)renderer.buffer_address(self.work) + (ulong)self.particle_count * Vec4::size,
        .edges              = (ulong)renderer.buffer_address(self.constants) + self.sections.edges,
        .initial            = (ulong)renderer.buffer_address(self.constants) + self.sections.initial,
        .rest               = (ulong)renderer.buffer_address(self.constants) + self.sections.rest,
        .adjacency          = (ulong)renderer.buffer_address(self.constants) + self.sections.adjacency,
        .triangles          = (ulong)renderer.buffer_address(self.constants) + self.sections.triangles,
        .geometry_positions = (ulong)renderer.geometry_stream_address(self.geometry, GeometryStream.POSITIONS)!,
        .geometry_normals   = (ulong)renderer.geometry_stream_address(self.geometry, GeometryStream.NORMALS)!,
        .world              = bitcast(node.world, float[16]),
        .inverse_world      = bitcast(maths::inverse_affine(node.world), float[16]),
        .gravity_step       = {
            gravity.x * self.gravity_scale,
            gravity.y * self.gravity_scale,
            gravity.z * self.gravity_scale,
            substep_seconds,
        },
        .sphere             = self.sphere,
        .particle_count     = self.particle_count,
        .triangle_count     = self.triangle_count,
        .stiffness          = self.stretch_stiffness,
        .damping            = math::max(0.0f, 1 - self.damping * substep_seconds),
        .ground             = self.ground,
    };
    BufferId[2] state_writes = { self.positions, self.work };
    BufferId[1] work_writes = { self.work };
    Recorder recorder = { .renderer = renderer, .root = root };

    if (!self.initialized) {
        recorder.run(self.stages.init, self.particle_count, state_writes[..])!;
        self.initialized = true;
    }
    for (uint substep = 0; substep < self.substeps; substep++) {
        recorder.run(self.stages.predict, self.particle_count, work_writes[..])!;
        for (uint iteration = 0; iteration < self.iterations; iteration++) {
            for (uint color = 0; color < self.color_count; color++) {
                recorder.root.first = self.color_starts[color];
                recorder.root.count = self.color_starts[color + 1] - self.color_starts[color];
                recorder.run(self.stages.project, recorder.root.count, work_writes[..])!;
            }
            recorder.run(self.stages.collide, self.particle_count, work_writes[..])!;
        }
        recorder.run(self.stages.integrate, self.particle_count, state_writes[..])!;
    }

    GeometryWrite[1] geometry_writes = {{
        .geometry     = self.geometry,
        .streams      = { .positions = true, .normals = true },
        .local_bounds = self.bounds,
    }};
    return recorder.run(
        stage:    self.stages.output,
        threads:  self.particle_count,
        writes:   {},
        geometry: geometry_writes[..],
    );
}

<*
 Positions as they stood FRAMES_IN_FLIGHT frames ago, in world space with the inverse mass in w.
 The view borrows mapped memory and is valid until the next begin_frame.
 @param [&in] self : "Created for this renderer."
 @param [&inout] renderer : "Frame open."
 @require renderer.frame_open
 @return? Renderer.read_buffer!
*>
fn Vec4[]? GpuCloth.read_positions(&self, Renderer* renderer) {
    char[] bytes = renderer.read_buffer(self.positions)!;
    return ((Vec4*)bytes.ptr)[:self.particle_count];
}

fn void? Recorder.run(
    &self,
    ComputeShaderId stage,
    uint threads,
    BufferId[] writes,
    GeometryWrite[] geometry = {},
) {
    return self.renderer.dispatch({
        .shader   = stage,
        .root     = material::@as_bytes(self.root),
        .groups   = { (threads + GROUP_SIZE - 1) / GROUP_SIZE, 1, 1 },
        .writes   = writes,
        .geometry = geometry,
    });
}

<*
 Fault UNSUPPORTED for a cloth outside the subset the device solver runs.
 Wind, bends, soft attachments, tangent frames, seams, cuts, transport, self-contact, continuous contact,
 skinned and crowd sources, and colliders other than one sphere that stays where it is are outside it.
 @param [&in] scene : "Holds the node and its cloth."
 @param [&in] node : "Carries a prepared Cloth."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
*>
fn void? check_gpu_cloth(Scene* scene, Node* node) {
    Cloth* cloth = scene.get(node, Cloth);
    if (!cloth || !cloth.is_prepared()) return c3d::INVALID_ARGUMENT~;

    ClothState* state = cloth.state;
    ClothDesc* desc = &state.desc;
    if (state.skinned || state.crowd || scene.has(node, Wind)) return c3d::UNSUPPORTED~;
    if (desc.bend_mode != ClothBendMode.DISTANCE || desc.bend_stiffness != 0) return c3d::UNSUPPORTED~;
    if (desc.tangent_frame || desc.cuts.len || desc.seams.len || desc.render_particles.len) return c3d::UNSUPPORTED~;
    if (desc.collisions.self_collision || desc.collisions.continuous) return c3d::UNSUPPORTED~;
    if (state.soft_attachments.len || state.positions.len != state.base_particle_count) return c3d::UNSUPPORTED~;
    if (state.shapes.len > 1 || (state.shapes.len == 1 && !sphere_of(scene, state))) return c3d::UNSUPPORTED~;
    if (state.material_particles.len != state.positions.len) return c3d::UNSUPPORTED~;
    foreach (vertex, particle : state.material_particles) {
        if (vertex != particle) return c3d::UNSUPPORTED~;
    }
    foreach (weight : state.transport) {
        if (weight != 0) return c3d::UNSUPPORTED~;
    }
    return;
}

<*
 Prepare the node's cloth for the device and hold its CPU solve.
 The first step uploads the cloth's constants, so it runs before any other dispatch of its frame.
 @param [&inout] renderer : "Owns the buffers and the output geometry's mirror."
 @param [&inout] assets : "Receives the compute stages; outlives the cloth."
 @param [&inout] scene : "Holds the node; its cloth is held until the application wakes it."
 @param [&in] node : "Carries a prepared Cloth over the owned geometry copy."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, AssetStore.add_compute_shader!
 @return? Renderer.create_buffer!, Renderer.upload_geometry!
*>
fn GpuCloth? create_gpu_cloth(Renderer* renderer, AssetStore* assets, Scene* scene, Node* node) {
    check_gpu_cloth(scene, node)!;

    Cloth* cloth = scene.get(node, Cloth);
    ClothState* state = cloth.state;
    ClothDesc* desc = &state.desc;
    GpuCloth gpu_cloth = {
        .allocator         = renderer.allocator,
        .node              = node.id,
        .geometry          = state.geometry,
        .particle_count    = (uint)state.positions.len,
        .substeps          = desc.substeps,
        .iterations        = desc.iterations,
        .stretch_stiffness = 1 - math::pow(1 - desc.stretch_stiffness, 1 / (float)desc.iterations),
        .damping           = desc.damping,
        .gravity_scale     = desc.gravity_scale,
        .ground            = desc.collide_ground ? desc.ground_height + desc.thickness : NO_GROUND,
    };
    if (state.shapes.len) {
        Vec3 center = sphere_center(scene, state);
        gpu_cloth.sphere = { center.x, center.y, center.z, state.shapes[0].radius + desc.thickness };
    }

    @pool() {
        gpu_cloth.pending_constants = build_constants(&gpu_cloth, state, assets)!;
    };
    defer catch alloc::free(gpu_cloth.allocator, gpu_cloth.pending_constants.ptr);

    gpu_cloth.stages = add_stages(assets)!;
    gpu_cloth.positions = renderer.create_buffer({
        .size       = (usz)gpu_cloth.particle_count * Vec4::size,
        .usage      = BufferUsage.READBACK,
        .debug_name = "cloth_positions",
    })!;
    defer catch (void)renderer.destroy_buffer(gpu_cloth.positions);
    gpu_cloth.work = renderer.create_buffer({
        .size       = 2 * (usz)gpu_cloth.particle_count * Vec4::size,
        .debug_name = "cloth_work",
    })!;
    defer catch (void)renderer.destroy_buffer(gpu_cloth.work);
    gpu_cloth.constants = renderer.create_buffer({
        .size       = gpu_cloth.sections.total,
        .usage      = BufferUsage.UPLOAD,
        .debug_name = "cloth_constants",
    })!;
    defer catch (void)renderer.destroy_buffer(gpu_cloth.constants);
    renderer.upload_geometry(gpu_cloth.geometry)!;

    cloth.sleep();
    return gpu_cloth;
}

<*
 Release the cloth's buffers; the owned geometry copy stays with the physics cloth.
 @param [&inout] renderer : "Retires the buffers after their last submitted use."
 @param [&inout] gpu_cloth : "Zeroed."
*>
fn void destroy_gpu_cloth(Renderer* renderer, GpuCloth* gpu_cloth) {
    alloc::free(gpu_cloth.allocator, gpu_cloth.pending_constants.ptr);
    (void)renderer.destroy_buffer(gpu_cloth.positions);
    (void)renderer.destroy_buffer(gpu_cloth.work);
    (void)renderer.destroy_buffer(gpu_cloth.constants);
    *gpu_cloth = {};
}

fn bool sphere_of(Scene* scene, ClothState* state) @private {
    ClothShape* shape = &state.shapes[0];
    return shape.kind == ColliderKind.SPHERE && shape.start == shape.end
      && scene.world.is_alive(state.bodies[shape.body].owner);
}

// The body is placed once; a collider that moves afterwards is not followed.
fn Vec3 sphere_center(Scene* scene, ClothState* state) @private {
    ClothShape* shape = &state.shapes[0];
    maths::Transform pose = maths::transform_from_mat4(scene.node(state.bodies[shape.body].owner).world);
    pose.scale = { 1, 1, 1 };
    return maths::transform_point(pose.to_mat4().mul(shape.local.to_mat4()), shape.start);
}

fn Stages? add_stages(AssetStore* assets) @private {
    return {
        .init      = stage(assets, INIT_KEY, physics::CLOTH_INIT_SPIRV[..])!,
        .predict   = stage(assets, PREDICT_KEY, physics::CLOTH_PREDICT_SPIRV[..])!,
        .project   = stage(assets, PROJECT_KEY, physics::CLOTH_PROJECT_SPIRV[..])!,
        .collide   = stage(assets, COLLIDE_KEY, physics::CLOTH_COLLIDE_SPIRV[..])!,
        .integrate = stage(assets, INTEGRATE_KEY, physics::CLOTH_INTEGRATE_SPIRV[..])!,
        .output    = stage(assets, OUTPUT_KEY, physics::CLOTH_OUTPUT_SPIRV[..])!,
    };
}

fn ComputeShaderId? stage(AssetStore* assets, String key, char[] spirv) @private {
    if (try found = assets.find_compute_shader(key)) return found;

    ComputeShaderDesc desc = { .compute = spirv };
    return assets.add_compute_shader(&desc, key);
}

// Fills the cloth's section offsets and bounds and returns the constants block the first step uploads.
fn char[]? build_constants(GpuCloth* gpu_cloth, ClothState* state, AssetStore* assets) @private {
    uint particles = gpu_cloth.particle_count;
    uint[] indices = assets.geometry(state.geometry).data.indices;
    gpu_cloth.triangle_count = (uint)(indices.len / 3);

    ClothConstraint[] edges = alloc::new_array(tmem, ClothConstraint, state.edges.len);
    edges[..] = state.edges[..];
    uint[] used_colors = alloc::new_array(tmem, uint, particles);
    uint[] destinations = alloc::new_array(tmem, uint, edges.len);
    gpu_cloth.color_count = cloth::order_constraints_by_color(
        constraints:  edges,
        used_colors:  used_colors,
        destinations: destinations,
        starts:       &gpu_cloth.color_starts,
    );
    if (!gpu_cloth.color_count) return c3d::UNSUPPORTED~;

    Vec4[] initial = alloc::new_array(tmem, Vec4, particles);
    Vec4[] rest = alloc::new_array(tmem, Vec4, particles);
    Vec3 low = state.rest[0];
    Vec3 high = state.rest[0];
    foreach (index, position : state.positions) {
        initial[index] = { position.x, position.y, position.z, state.inverse_masses[index] };
        Vec3 local = state.rest[index];
        rest[index] = { local.x, local.y, local.z, state.inverse_masses[index] };
        low = { math::min(low.x, local.x), math::min(low.y, local.y), math::min(low.z, local.z) };
        high = { math::max(high.x, local.x), math::max(high.y, local.y), math::max(high.z, local.z) };
    }
    float reach = REACH_FACTOR * (high - low).length();
    Vec3 margin = { reach, reach, reach };
    gpu_cloth.bounds = { .min = low - margin, .max = high + margin };

    EdgeGpu[] gpu_edges = alloc::new_array(tmem, EdgeGpu, edges.len);
    foreach (index, edge : edges) {
        gpu_edges[index] = { .first = edge.first, .second = edge.second, .rest_length = edge.rest_length };
    }

    // Offsets table, then the triangle numbers incident to each particle.
    uint[] adjacency = alloc::new_array(tmem, uint, (usz)particles + 1 + indices.len);
    foreach (vertex : indices) adjacency[vertex + 1]++;
    for (usz particle = 0; particle < particles; particle++) adjacency[particle + 1] += adjacency[particle];
    uint[] cursor = alloc::new_array(tmem, uint, particles);
    cursor[..] = adjacency[:particles];
    foreach (corner, vertex : indices) {
        adjacency[(usz)particles + 1 + cursor[vertex]++] = (uint)(corner / 3);
    }

    Sections* sections = &gpu_cloth.sections;
    usz cursor_bytes;
    sections.initial = place(&cursor_bytes, initial.len * Vec4::size);
    sections.rest = place(&cursor_bytes, rest.len * Vec4::size);
    sections.edges = place(&cursor_bytes, gpu_edges.len * EdgeGpu::size);
    sections.adjacency = place(&cursor_bytes, adjacency.len * uint::size);
    sections.triangles = place(&cursor_bytes, indices.len * uint::size);
    sections.total = cursor_bytes;

    char[] block = alloc::new_array(gpu_cloth.allocator, char, (sz)sections.total);
    mem::copy(&block[sections.initial], initial.ptr, (sz)(initial.len * Vec4::size));
    mem::copy(&block[sections.rest], rest.ptr, (sz)(rest.len * Vec4::size));
    mem::copy(&block[sections.edges], gpu_edges.ptr, (sz)(gpu_edges.len * EdgeGpu::size));
    mem::copy(&block[sections.adjacency], adjacency.ptr, (sz)(adjacency.len * uint::size));
    mem::copy(&block[sections.triangles], indices.ptr, (sz)(indices.len * uint::size));
    return block;
}

fn usz place(usz* cursor, usz bytes) @private {
    usz offset = *cursor;
    *cursor = (offset + bytes + render::STREAM_ALIGNMENT - 1) / render::STREAM_ALIGNMENT * render::STREAM_ALIGNMENT;
    return offset;
}
