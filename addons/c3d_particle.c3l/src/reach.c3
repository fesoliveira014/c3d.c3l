module c3d::particle;

import c3d;
import c3d::maths;
import std::math;

<*
 Slices of one lifetime that a reach keeps apart.
*>
const uint REACH_SLOTS = 8; // 400 bytes per system; a start leaves the reach at most one slice late

const float TURBULENCE_CURL_BOUND @private = 8.5f; // curl length at unit strength; the supremum is 8.386

<*
 Where the emitter and the air have been during one slice of time.
*>
struct ReachSlice {
    Aabb emitter; // emission shape placed by the emitter's world matrix
    Aabb wind; // holds the zero vector
    bool recorded;
}

<*
 Emitter placements and winds over the last lifetime, kept in slices.
*>
struct ParticleReach {
    ReachSlice[REACH_SLOTS] slices;
    uint newest;
    float clock; // seconds into the newest slice
    float inherited_speed; // fastest velocity a delivery has added to a child; never decays
}

struct ReachUnion @private {
    Aabb emitters;
    Aabb winds;
    bool recorded;
}

<*
 Record one step's emitter placement and wind, and retire the slices older than a lifetime.
 @param [&in] desc : "The system's descriptor."
 @param emitter_world : "Published affine emitter matrix."
 @param seconds : "Simulated duration of the step."
*>
fn void ParticleReach.record(
    &self,
    ParticleSystemDesc* desc,
    Mat4 emitter_world,
    Vec3 wind,
    float seconds,
) {
    float slice_seconds = desc.lifetime.max / (REACH_SLOTS - 1);
    self.clock += seconds;
    uint elapsed = (uint)(self.clock / slice_seconds);
    self.clock -= (float)elapsed * slice_seconds;
    for (uint retired = 0; retired < math::min(elapsed, REACH_SLOTS); retired++) {
        self.newest = (self.newest + 1) % REACH_SLOTS;
        self.slices[self.newest] = {};
    }

    ReachSlice* slice = &self.slices[self.newest];
    Aabb placed = maths::aabb_transform(emission_bounds(desc), emitter_world);
    Aabb air = { .min = math::min(wind, (Vec3){}), .max = math::max(wind, (Vec3){}) };
    if (slice.recorded) {
        slice.emitter = maths::aabb_merge(slice.emitter, placed);
        slice.wind = maths::aabb_merge(slice.wind, air);
    } else {
        *slice = { .emitter = placed, .wind = air, .recorded = true };
    }
}

<*
 Add a box where children of another system can appear, and the speed they inherit, to the newest slice.
 @param inherited_speed : "Fastest velocity the delivery adds to a child."
 @require self.slices[self.newest].recorded
*>
fn void ParticleReach.record_origins(&self, Aabb origins, float inherited_speed) {
    ReachSlice* slice = &self.slices[self.newest];
    slice.emitter = maths::aabb_merge(slice.emitter, origins);
    self.inherited_speed = math::max(self.inherited_speed, inherited_speed);
}

<*
 Move every recorded emitter placement by the negated offset.
*>
fn void ParticleReach.shift(&self, Vec3 offset) {
    foreach (&slice : self.slices) {
        slice.emitter.min -= offset;
        slice.emitter.max -= offset;
    }
}

<*
 Fastest speed a particle of the system can reach, from the slices recorded so far.
 @param [&in] desc : "The system's descriptor."
*>
fn float ParticleReach.speed_bound(&self, ParticleSystemDesc* desc) {
    ReachUnion slices = union_slices(self);
    return particle_speed_bound(
        desc: desc,
        inherited_speed: self.inherited_speed,
        wind_speed: desc.drag > 0 ? union_wind_speed(&slices) : 0,
    );
}

<*
 Scene-space box that holds every billboard or mesh the system can draw, from the slices recorded so far.
 @param [&in] desc : "The system's descriptor."
 @param mesh_radius : "MESH only; the radius of the geometry's bound."
*>
fn Aabb ParticleReach.bound(&self, ParticleSystemDesc* desc, float mesh_radius = 0) {
    ReachUnion slices = union_slices(self);
    if (!slices.recorded) return {};

    float lifetime = desc.lifetime.max;
    bool driven = desc.drag > 0;
    float turbulence = driven ? turbulence_speed_bound(&desc.turbulence) : 0;
    Vec3 gravity = PARTICLE_GRAVITY * desc.gravity_scale;
    Vec3 fall = gravity * (0.5f * lifetime * (lifetime + MAX_PARTICLE_STEP_SECONDS));
    Aabb bound = {
        .min = slices.emitters.min + math::min(fall, (Vec3){}),
        .max = slices.emitters.max + math::max(fall, (Vec3){}),
    };
    float wind_speed;
    if (driven) {
        bound.min += slices.winds.min * lifetime;
        bound.max += slices.winds.max * lifetime;
        wind_speed = union_wind_speed(&slices);
    }

    ParticleCollision* collision = &desc.collision;
    float width = desc.size.max * peak_scale(&desc.size_over_life);
    if (collision.response != CollisionResponse.NONE && collision.ground_plane) {
        bound.min.y = math::min(bound.min.y, collision.ground_height);
        bound.max.y = math::max(bound.max.y, collision.ground_height + width * collision.radius_scale);
    }

    float height = width;
    if (desc.render_mode == ParticleRenderMode.STRETCHED) {
        height += particle_speed_bound(
            desc: desc,
            inherited_speed: self.inherited_speed,
            wind_speed: wind_speed,
        ) * desc.stretch;
    }
    float half_extent = desc.render_mode == ParticleRenderMode.MESH
      ? width * mesh_radius : 0.5f * math::sqrt(width * width + height * height);
    float travel = (desc.speed.max + self.inherited_speed + turbulence) * lifetime + half_extent;
    Vec3 margin = { travel, travel, travel };
    bound.min -= margin;
    bound.max += margin;
    return bound;
}

<*
 Scene-space box that holds every trail strip of the system, from the slices recorded so far.
 @param [&in] desc : "The system's descriptor, with a trail."
*>
fn Aabb ParticleReach.trail_bound(&self, ParticleSystemDesc* desc) {
    Aabb bound = self.bound(desc);
    float half_width = 0.5f * desc.trail.width * peak_scale(&desc.trail.width_over_trail);
    Vec3 margin = { half_width, half_width, half_width };
    return { .min = bound.min - margin, .max = bound.max + margin };
}

fn float bound_radius(Aabb bounds) @private {
    return math::max(math::abs(bounds.min), math::abs(bounds.max)).length();
}

fn ReachUnion union_slices(ParticleReach* reach) @private {
    ReachUnion total;
    foreach (&slice : reach.slices) {
        if (!slice.recorded) continue;

        total.emitters = total.recorded ? maths::aabb_merge(total.emitters, slice.emitter) : slice.emitter;
        total.winds = total.recorded ? maths::aabb_merge(total.winds, slice.wind) : slice.wind;
        total.recorded = true;
    }
    return total;
}

fn float union_wind_speed(ReachUnion* slices) @private {
    return math::max(math::abs(slices.winds.min), math::abs(slices.winds.max)).length();
}

fn float particle_speed_bound(ParticleSystemDesc* desc, float inherited_speed, float wind_speed) @private {
    float turbulence = desc.drag > 0 ? turbulence_speed_bound(&desc.turbulence) : 0;
    float gravity = (PARTICLE_GRAVITY * desc.gravity_scale).length();
    return desc.speed.max + inherited_speed + gravity * desc.lifetime.max + wind_speed + turbulence;
}

fn Aabb emission_bounds(ParticleSystemDesc* desc) @private {
    float radius = desc.radius;
    switch (desc.shape) {
        case POINT: return {};
        case SPHERE: return { .min = { -radius, -radius, -radius }, .max = { radius, radius, radius } };
        case BOX: return { .min = -desc.half_extents, .max = desc.half_extents };
        case CONE: return { .min = { -radius, 0, -radius }, .max = { radius, 0, radius } };
    }
}

fn float peak_scale(LifetimeTable* table) @private {
    float peak = table.values[0];
    foreach (value : table.values) peak = math::max(peak, value);
    return peak;
}

fn float turbulence_speed_bound(ParticleTurbulence* turbulence) @private {
    float amplitude = turbulence.strength * CURL_SCALE;
    float total;
    for (uint octave = 0; octave < turbulence.octaves; octave++) {
        total += amplitude;
        amplitude *= OCTAVE_GAIN;
    }
    return total * TURBULENCE_CURL_BOUND;
}
