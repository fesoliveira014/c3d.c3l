module c3d::light;

import c3d;
import std::math;

<* Inward fade width of a constructed reflection probe, in world units. *>
const float DEFAULT_REFLECTION_BLEND_DISTANCE = 0.5f; // hides face seams; a wider fade reads two cubes on more pixels

<* Lookup a reflection probe applies to a reflected direction. *>
enum ReflectionProjection {
    BOX,
    INFINITE,
}

<* Oriented box of local specular reflections centred on its node; node scale is ignored. *>
struct ReflectionProbe {
    Vec3                 half_extents;   // along the node's rotated axes
    Vec3                 capture_offset; // capture point in the node's rotated frame, unscaled
    float                blend_distance; // inward fade at every face; 0 is a hard edge
    float                intensity;
    int                  priority;       // a higher priority is selected before a smaller box
    ReflectionProjection projection;
    EnvironmentId        environment;    // zero applies nothing
}

<*
 Whether the renderer can read the probe.
 @param [&in] probe : "Component to check."
 @pure
*>
fn bool reflection_probe_valid(ReflectionProbe* probe) {
    foreach (axis, extent : probe.half_extents) {
        if (!math::is_finite(extent) || extent <= 0) return false;
        float offset = probe.capture_offset[axis];
        // Strictly inside: a reflected ray's exit point then never meets the capture point.
        if (!math::is_finite(offset) || math::abs(offset) >= extent) return false;
    }
    float[2] scalars = { probe.blend_distance, probe.intensity };
    foreach (scalar : scalars) {
        if (!math::is_finite(scalar) || scalar < 0) return false;
    }
    return true;
}

<*
 Box-projected probe with unit intensity, captured at its node.
 @require half_extents.x > 0, half_extents.y > 0, half_extents.z > 0
 @require math::is_finite(half_extents.x), math::is_finite(half_extents.y), math::is_finite(half_extents.z)
 @pure
*>
fn ReflectionProbe reflection_probe(Vec3 half_extents, EnvironmentId environment) {
    return {
        .half_extents   = half_extents,
        .blend_distance = DEFAULT_REFLECTION_BLEND_DISTANCE,
        .intensity      = 1,
        .projection     = ReflectionProjection.BOX,
        .environment    = environment,
    };
}
