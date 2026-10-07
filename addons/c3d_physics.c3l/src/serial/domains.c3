module c3d::physics @feat(C3D_PHYSICS_SERIAL);

import c3d;
import c3d::serial;
import std::math;

fn bool finite_authoring_vector(Vec3 value) @local {
    return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
}

fn bool body_authoring_valid(BodyDesc body) @private {
    return finite_authoring_vector(body.linear_velocity) && finite_authoring_vector(body.angular_velocity)
        && math::is_finite(body.linear_damping) && math::is_finite(body.angular_damping)
        && math::is_finite(body.gravity_scale);
}

fn bool wind_authoring_valid(Wind wind) @local {
    return finite_authoring_vector(wind.velocity) && math::is_finite(wind.drag)
        && math::is_finite(wind.lift) && math::is_finite(wind.max_speed);
}

fn bool force_authoring_valid(Force force) @local {
    return finite_authoring_vector(force.force) && finite_authoring_vector(force.local_point);
}

fn bool buoyancy_authoring_valid(float fluid_density, float linear_drag) @private {
    return math::is_finite(fluid_density) && math::is_finite(linear_drag);
}

fn void? project_wind(void* component, void* value, serial::WriteContext* context) @private {
    Wind wind = *(Wind*)component;
    if (!wind_authoring_valid(wind)) return c3d::INVALID_ARGUMENT~;
    *(Wind*)value = wind;
}

fn void? validate_wind(void* value, serial::ReadContext* context) @private {
    if (!wind_authoring_valid(*(Wind*)value)) return c3d::INVALID_ARGUMENT~;
}

fn void? project_force(void* component, void* value, serial::WriteContext* context) @private {
    Force force = *(Force*)component;
    if (!force_authoring_valid(force)) return c3d::INVALID_ARGUMENT~;
    *(Force*)value = force;
}

fn void? validate_force(void* value, serial::ReadContext* context) @private {
    if (!force_authoring_valid(*(Force*)value)) return c3d::INVALID_ARGUMENT~;
}
