module particle_execution;

import c3d;
import c3d::asset;
import c3d::particle::gpu;
import c3d::render;
import c3d::scene;
import std::math;

const bool ENABLED = true;

struct Context {
    GpuParticles particles;
}

fn void? create(Context* context, AssetStore* assets) {
    context.particles = gpu::create_gpu_particles(mem, assets)!;
}

fn void? update(
    Context* context,
    Renderer* renderer,
    Scene* scene,
    float dt,
    Vec3 wind,
) {
    gpu::update(
        particles: &context.particles,
        renderer: renderer,
        scene: scene,
        dt: dt,
        wind: wind,
    )!;
}

fn void destroy(Context* context, Renderer* renderer) {
    gpu::destroy_gpu_particles(&context.particles, renderer);
}
