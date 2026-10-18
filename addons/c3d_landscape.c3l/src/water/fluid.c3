module c3d::landscape::water;

import std::math;

<*
 Buoyancy context for one water body: its view, time and a uniform current.
*>
struct WaterFluid {
    SurfaceView view;
    double      time;
    Vec3        current; // metres per second, added to the orbital velocity
}

<*
 Fluid sampler over a WaterFluid context, matching the physics sampler signature.
 @param [&in] context : "A WaterFluid."
 @param [&out] velocity : "Fluid velocity in m/s; unspecified when the result is empty."
 @return? NOT_FOUND
*>
fn float? fluid_sample(
    void* context,
    float x,
    float z,
    float step_offset,
    Vec3* velocity,
) {
    WaterFluid* fluid = context;
    WaterSample sample = sample_surface_detail(
        view:    &fluid.view,
        world_x: x,
        world_z: z,
        time:    fluid.time + step_offset,
    )!;
    *velocity = sample.velocity + fluid.current;
    return sample.height;
}
