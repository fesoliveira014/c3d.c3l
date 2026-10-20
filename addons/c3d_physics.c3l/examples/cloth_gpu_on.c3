module cloth_gpu_hooks;

import c3d;
import c3d::asset;
import c3d::physics;
import c3d::render;
import c3d::render::cloth_gpu;
import c3d::scene;
import std::io;
import std::io::file;
import std::math;

const bool ENABLED = true;

struct State {
    GpuCloth cloth;
    bool     attached;
}

fn ClothStepShape? shape_named(String name) @local {
    if (!name.len || name == "pr0") return PR0;
    if (name == "fused") return FUSED;
    if (name == "single") return SINGLE;
    return c3d::INVALID_ARGUMENT~;
}

fn void? attach(
    State* state,
    Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    Node* node,
    String shape,
) {
    ClothStepShape selected = shape_named(shape)!;
    state.cloth = cloth_gpu::create_gpu_cloth(renderer, assets, scene, node)!;
    state.cloth.shape = selected;
    state.attached = true;
}

fn void? step(
    State* state,
    Renderer* renderer,
    Scene* scene,
    float step_seconds,
) {
    if (!state.attached) return;

    return state.cloth.step(
        renderer:     renderer,
        scene:        scene,
        gravity:      physics::DEFAULT_GRAVITY,
        step_seconds: step_seconds,
    );
}

fn void report(State* state) {
    GpuCloth* cloth = &state.cloth;
    io::printfn(
        "gpu_cloth,shape,%s,dispatches_per_step,%d,particles,%d,substeps,%d,iterations,%d,colors,%d",
        cloth.shape,
        cloth.dispatches,
        cloth.particle_count,
        cloth.substeps,
        cloth.iterations,
        cloth.color_count,
    );
}

fn void? dump(State* state, Renderer* renderer, String path) {
    Vec4[] positions = state.cloth.read_positions(renderer)!;
    return file::save(path, ((char*)positions.ptr)[:positions.len * Vec4::size]);
}

fn void detach(State* state, Renderer* renderer) {
    if (!state.attached) return;

    cloth_gpu::destroy_gpu_cloth(renderer, &state.cloth);
    state.attached = false;
}
