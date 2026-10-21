module cloth_gpu_hooks;

import c3d;
import c3d::asset;
import c3d::render;
import c3d::render::cloth_gpu;
import c3d::scene;
import std::io;
import std::math;

const bool ENABLED = true;

struct State {
    GpuCloths cloths;
    bool      attached;
}

fn void? attach(State* state, AssetStore* assets) {
    state.cloths = cloth_gpu::create_gpu_cloths(mem, assets)!;
    state.attached = true;
}

fn void? step(
    State* state,
    Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
) {
    if (!state.attached) return;

    return cloth_gpu::update(&state.cloths, renderer, assets, scene);
}

fn void report(
    State* state,
    uint particles,
    uint cloths,
    uint dispatches,
) {
    GpuClothsDesc* budget = &state.cloths.desc;
    usz positions = (usz)budget.max_particles * Vec4::size;
    io::printfn(
        "gpu_cloth,shape,%s,cloths,%d,particles,%d,dispatches_per_step,%d",
        cloth_gpu::step_shape(particles),
        cloths,
        particles,
        dispatches / cloths,
    );
    io::printfn(
        "gpu_cloth,memory,device_bytes,%d,host_readback_bytes,%d,host_tables_bytes,%d,particles_used,%d,table_bytes_used,%d",
        positions + 2 * positions + budget.table_bytes,
        (render::FRAMES_IN_FLIGHT + 1) * positions,
        budget.table_bytes,
        state.cloths.particles_used(),
        state.cloths.tables_used(),
    );
}

fn void detach(State* state, Renderer* renderer) {
    if (!state.attached) return;

    cloth_gpu::destroy_gpu_cloths(&state.cloths, renderer);
    state.attached = false;
}
