module cloth_gpu_hooks;

import c3d;
import c3d::asset;
import c3d::render;
import c3d::scene;

const bool ENABLED = false;

struct State {
    bool attached;
}

fn void? attach(State* state, AssetStore* assets) {
    return c3d::UNSUPPORTED~;
}

fn void? step(
    State* state,
    Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
) {}

fn void report(
    State* state,
    uint particles,
    uint cloths,
    uint dispatches,
) {}

fn void detach(State* state, Renderer* renderer) {}
