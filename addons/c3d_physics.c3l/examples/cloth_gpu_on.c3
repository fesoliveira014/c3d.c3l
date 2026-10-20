module cloth_gpu_hooks;

import c3d;
import c3d::asset;
import c3d::physics;
import c3d::render;
import c3d::render::cloth_gpu;
import c3d::scene;

const bool ENABLED = true;

struct State {
    GpuCloth cloth;
    bool     attached;
}

fn void? attach(
    State* state,
    Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    Node* node,
) {
    state.cloth = cloth_gpu::create_gpu_cloth(renderer, assets, scene, node)!;
    state.attached = true;
}

fn void? step(State* state, Renderer* renderer, Scene* scene, float step_seconds) {
    if (!state.attached) return;

    return state.cloth.step(renderer, scene, physics::DEFAULT_GRAVITY, step_seconds);
}

fn void detach(State* state, Renderer* renderer) {
    if (!state.attached) return;

    cloth_gpu::destroy_gpu_cloth(renderer, &state.cloth);
    state.attached = false;
}
