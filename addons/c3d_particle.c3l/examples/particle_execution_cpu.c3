module particle_execution;

import c3d;
import c3d::asset;
import c3d::render;
import c3d::scene;
import std::math;

const bool ENABLED = false;

struct Context {
    bool unused;
}

fn void? create(Context* context, AssetStore* assets) {}

fn void? update(
    Context* context,
    Renderer* renderer,
    Scene* scene,
    float dt,
    Vec3 wind,
) {}

fn void destroy(Context* context, Renderer* renderer) {}
