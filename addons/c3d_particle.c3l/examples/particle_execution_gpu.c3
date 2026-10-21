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
    ViewId depth_view,
    Entity depth_camera,
) {
    gpu::update(
        particles: &context.particles,
        renderer: renderer,
        scene: scene,
        dt: dt,
        wind: wind,
        depth: { .view = depth_view, .camera = depth_camera },
    )!;
}

fn void destroy(Context* context, Renderer* renderer) {
    gpu::destroy_gpu_particles(&context.particles, renderer);
}
