module c3d::light;

import std::math;

<* Fewest probes on one axis of a volume. *>
const uint PROBE_COUNT_MIN = 2;

<* Most probes on one axis of a volume. *>
const uint PROBE_COUNT_MAX = 32; // 48 MiB of atlases per volume at 32^3; 384 MiB for eight

<* Fewest rays a probe casts per update. *>
const uint PROBE_RAYS_MIN = 32; // below it a one-update estimate, which a first sweep shows, is mostly noise

<* Most rays a probe casts per update. *>
const uint PROBE_RAYS_MAX = 256; // the blend reads every ray per texel; 128 MiB of ray results for 32^3 probes

<* Ray budget of a constructed volume. *>
const ProbeUpdateDesc PROBE_UPDATE_DEFAULT = {
    .rays_per_probe   = 128,   // 4.2 M primary rays and 64 MiB of ray results for 32^3 probes per update
    .probes_per_frame = 0,
    .hysteresis       = 0.97f, // 95 percent of a change after 99 updates of a probe
};

const float PROBE_NORMAL_BIAS_SCALE @local = 0.05f;
const float PROBE_VIEW_BIAS_SCALE @local = 0.1f;
const float PROBE_MAX_DISTANCE_SCALE @local = 1.5f;

<* Source of a volume's atlas texels. *>
enum ProbeFill {
    NONE,
    ENVIRONMENT,
    SCENE,
}

<* Per-update ray budget and temporal blend of a SCENE volume. *>
struct ProbeUpdateDesc {
    uint  rays_per_probe;
    uint  probes_per_frame; // 0 or at least the probe count: every probe each update
    float hysteresis;       // share of the previous texel kept per update, in [0, 1)
}

<* Grid of light probes centered on its node, axis aligned; node rotation and scale are ignored. *>
struct ProbeVolume {
    Vec3            half_extents;
    uint[<3>]       counts;       // probes per axis
    float           normal_bias;  // world units along the surface normal
    float           view_bias;    // world units toward the viewer
    float           energy;
    float           max_distance; // visibility clamp, world units
    ProbeFill       fill;
    ProbeUpdateDesc update;
}

<*
 Distance between neighbor probes on each axis.
 @pure
*>
fn Vec3 ProbeVolume.spacing(&self) {
    return self.half_extents * 2 / (Vec3)(self.counts - 1);
}

<*
 World position of one probe.
 @param center : "World position of the volume's node."
 @pure
*>
fn Vec3 ProbeVolume.probe_position(&self, Vec3 center, uint[<3>] cell) {
    return center - self.half_extents + (Vec3)cell * self.spacing();
}

<*
 Probes in the volume.
 @pure
*>
fn uint ProbeVolume.probe_count(&self) {
    return self.counts.x * self.counts.y * self.counts.z;
}

<*
 Whether a volume can be read by the renderer.
 @param [&in] volume : "Component to check."
 @pure
*>
fn bool probe_volume_valid(ProbeVolume* volume) {
    foreach (axis : volume.half_extents) {
        if (!math::is_finite(axis) || axis <= 0) return false;
    }
    foreach (count : volume.counts) {
        if (count < PROBE_COUNT_MIN || count > PROBE_COUNT_MAX) return false;
    }
    float[4] scalars = { volume.normal_bias, volume.view_bias, volume.energy, volume.max_distance };
    foreach (scalar : scalars) {
        if (!math::is_finite(scalar) || scalar < 0) return false;
    }
    ProbeUpdateDesc* update = &volume.update;
    if (update.rays_per_probe < PROBE_RAYS_MIN || update.rays_per_probe > PROBE_RAYS_MAX) return false;
    return math::is_finite(update.hysteresis) && update.hysteresis >= 0 && update.hysteresis < 1;
}

<*
 Volume with biases and visibility clamp derived from its spacing.
 @require half_extents.x > 0, half_extents.y > 0, half_extents.z > 0
 @require math::is_finite(half_extents.x), math::is_finite(half_extents.y), math::is_finite(half_extents.z)
 @require counts.x >= PROBE_COUNT_MIN, counts.y >= PROBE_COUNT_MIN, counts.z >= PROBE_COUNT_MIN
 @require counts.x <= PROBE_COUNT_MAX, counts.y <= PROBE_COUNT_MAX, counts.z <= PROBE_COUNT_MAX
 @pure
*>
fn ProbeVolume probe_volume(Vec3 half_extents, uint[<3>] counts, ProbeFill fill = ProbeFill.ENVIRONMENT) {
    ProbeVolume volume = {
        .half_extents = half_extents,
        .counts       = counts,
        .energy       = 1,
        .fill         = fill,
        .update       = PROBE_UPDATE_DEFAULT,
    };
    Vec3 spacing = volume.spacing();
    float smallest = math::min(spacing.x, spacing.y, spacing.z);
    float largest = math::max(spacing.x, spacing.y, spacing.z);
    volume.normal_bias = PROBE_NORMAL_BIAS_SCALE * smallest;
    volume.view_bias = PROBE_VIEW_BIAS_SCALE * smallest;
    volume.max_distance = PROBE_MAX_DISTANCE_SCALE * largest;
    return volume;
}
