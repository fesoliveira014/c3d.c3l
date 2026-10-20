module cloth_gpu_hooks;

import c3d;
import c3d::asset;
import c3d::render;
import c3d::scene;

const bool ENABLED = false;

struct State {
    bool attached;
}

fn void? attach(
    State* state,
    Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    Node* node,
    String shape,
) {
    return c3d::UNSUPPORTED~;
}

fn void? step(
    State* state,
    Renderer* renderer,
    Scene* scene,
    float step_seconds,
) {}

fn void report(State* state) {}

fn void? dump(State* state, Renderer* renderer, String path) {
    return c3d::UNSUPPORTED~;
}

fn void detach(State* state, Renderer* renderer) {}
