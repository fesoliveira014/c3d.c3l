module c3d::nav;

import std::math;
import c3d;

<* Adaptive sampling divisions; mirrors DT_MAX_PATTERN_DIVS. *>
const uint MAX_PATTERN_DIVISIONS = 32;

<* Adaptive sampling rings; mirrors DT_MAX_PATTERN_RINGS. *>
const uint MAX_PATTERN_RINGS = 4;

const usz   PATTERN_CAPACITY @local = MAX_PATTERN_DIVISIONS * MAX_PATTERN_RINGS + 1; // every ring plus the zero sample
const float MIN_SWEEP_SPEED_SQR @local = 0.0001f; // mirrors sweepCircleCircle's EPS: slower relative motion never meets
const float PARALLEL_RAY_EPSILON @local = 1e-6f; // mirrors isectRaySeg's parallel test
const float SIDE_AREA_THRESHOLD @local = 0.01f; // mirrors prepare's side choice
const float TOUCH_DISTANCE @local = 0.01f; // metres; mirrors prepare: a segment this close touches the agent
const float MIN_IMPACT_TIME @local = 0.1f; // seconds; mirrors processSample's floor under the impact penalty
const float WALL_TIME_SCALE @local = 2; // mirrors processSample: walls ahead count as twice as far as agents
const float ADAPTIVE_SPEED_MARGIN @local = 0.001f; // metres per second; mirrors sampleVelocityAdaptive's speed limit slack
const float ADAPTIVE_SAMPLE_SCALE @local = 0.1f; // mirrors sampleVelocityAdaptive: a sample's size is a tenth of the ring

<* Moving circular obstacle; mirrors dtObstacleCircle. *>
struct ObstacleCircle {
    Vec3  position;
    Vec3  velocity;
    Vec3  desired_velocity;
    float radius;
    Vec3  direction;    // from the sampling agent; side selection
    Vec3  normal;       // the side the agent passes on
}

<* Static wall segment; mirrors dtObstacleSegment. *>
struct ObstacleSegment {
    Vec3 start;
    Vec3 end;
    bool touch;    // the sampling agent stands on the segment
}

<* Weights and sampling pattern of one avoidance configuration; mirrors dtObstacleAvoidanceParams. *>
struct ObstacleAvoidanceParams {
    float velocity_bias;              // share of the desired velocity the samples centre on
    float weight_desired_velocity;
    float weight_current_velocity;
    float weight_side;
    float weight_time_of_impact;
    float horizon_time;               // seconds
    char  grid_size;
    char  adaptive_divisions;
    char  adaptive_rings;
    char  adaptive_depth;
}

<* Velocity sampler over the obstacles of one agent; mirrors dtObstacleAvoidanceQuery. *>
struct ObstacleAvoidanceQuery {
    Allocator               allocator;
    ObstacleAvoidanceParams params;
    float                   inverse_horizon_time;
    float                   max_velocity;
    float                   inverse_max_velocity;
    ObstacleCircle[]        circles;
    uint                    circle_count;
    ObstacleSegment[]       segments;
    uint                    segment_count;
}

<* Sample record for debugging; mirrors dtObstacleAvoidanceDebugData. *>
struct AvoidanceSample {
    Vec3  velocity;
    float size;
    float penalty;
    float desired_velocity_penalty;
    float current_velocity_penalty;
    float side_penalty;
    float collision_time_penalty;
}

<* Result of a velocity sampling. *>
struct SampledVelocity {
    Vec3 velocity;
    uint samples;     // candidates within the speed limit
    usz  recorded;    // written to out_samples
}

struct SamplingAgent @local {
    Vec3  position;
    float radius;
    Vec3  velocity;
    Vec3  desired_velocity;
}

struct SampleRecorder @local {
    AvoidanceSample[] samples;
    usz               count;
}

<* Drop every obstacle. *>
fn void ObstacleAvoidanceQuery.reset(&self) {
    self.circle_count = 0;
    self.segment_count = 0;
}

<* Add a moving circle; ignored past capacity. *>
fn void ObstacleAvoidanceQuery.add_circle(
    &self,
    Vec3 position,
    float radius,
    Vec3 velocity,
    Vec3 desired_velocity,
) {
    if (self.circle_count >= self.circles.len) return;
    self.circles[self.circle_count++] = {
        .position         = position,
        .radius           = radius,
        .velocity         = velocity,
        .desired_velocity = desired_velocity,
    };
}

<* Add a wall segment; ignored past capacity. *>
fn void ObstacleAvoidanceQuery.add_segment(&self, Vec3 start, Vec3 end) {
    if (self.segment_count >= self.segments.len) return;
    self.segments[self.segment_count++] = { .start = start, .end = end };
}

<*
 Best velocity from a grid of samples around the biased desired velocity; mirrors sampleVelocityGrid.
 @param [&in] params : "Copied into the query."
 @param out_samples : "Every sample scored in full; empty when not wanted."
 @require params.grid_size >= 2, params.horizon_time > 0
*>
fn SampledVelocity ObstacleAvoidanceQuery.sample_velocity_grid(
    &self,
    Vec3 position,
    float radius,
    float max_velocity,
    Vec3 velocity,
    Vec3 desired_velocity,
    ObstacleAvoidanceParams* params,
    AvoidanceSample[] out_samples = {},
) {
    SamplingAgent agent = begin_sampling(
        query:            self,
        position:         position,
        radius:           radius,
        max_velocity:     max_velocity,
        velocity:         velocity,
        desired_velocity: desired_velocity,
        params:           params,
    );
    SampleRecorder recorder = { .samples = out_samples };
    SampledVelocity result;

    int grid_size = (int)self.params.grid_size;
    float center_x = desired_velocity.x * self.params.velocity_bias;
    float center_z = desired_velocity.z * self.params.velocity_bias;
    float cell = max_velocity * 2 * (1 - self.params.velocity_bias) / (float)(grid_size - 1);
    float half = (float)(grid_size - 1) * cell * 0.5f;
    float limit = max_velocity + cell * 0.5f;
    float min_penalty = float::max;
    for (int y = 0; y < grid_size; y++) {
        for (int x = 0; x < grid_size; x++) {
            Vec3 candidate = { center_x + x * cell - half, 0, center_z + y * cell - half };
            if (candidate.x * candidate.x + candidate.z * candidate.z > limit * limit) continue;
            float penalty = process_sample(
                query:       self,
                candidate:   candidate,
                sample_size: cell,
                agent:       &agent,
                min_penalty: min_penalty,
                recorder:    &recorder,
            );
            result.samples++;
            if (penalty < min_penalty) {
                min_penalty = penalty;
                result.velocity = candidate;
            }
        }
    }
    result.recorded = recorder.count;
    return result;
}

<*
 Best velocity from rings of samples refined around the best so far; mirrors sampleVelocityAdaptive.
 @param [&in] params : "Copied into the query."
 @param out_samples : "Every sample scored in full; empty when not wanted."
 @require params.horizon_time > 0
*>
fn SampledVelocity ObstacleAvoidanceQuery.sample_velocity_adaptive(
    &self,
    Vec3 position,
    float radius,
    float max_velocity,
    Vec3 velocity,
    Vec3 desired_velocity,
    ObstacleAvoidanceParams* params,
    AvoidanceSample[] out_samples = {},
) {
    SamplingAgent agent = begin_sampling(
        query:            self,
        position:         position,
        radius:           radius,
        max_velocity:     max_velocity,
        velocity:         velocity,
        desired_velocity: desired_velocity,
        params:           params,
    );
    SampleRecorder recorder = { .samples = out_samples };
    SampledVelocity result;

    float[<2>][PATTERN_CAPACITY] pattern;
    usz pattern_count = sampling_pattern(&self.params, desired_velocity, &pattern);
    float ring = max_velocity * (1 - self.params.velocity_bias);
    float limit = max_velocity + ADAPTIVE_SPEED_MARGIN;
    Vec3 best = { desired_velocity.x * self.params.velocity_bias, 0, desired_velocity.z * self.params.velocity_bias };
    for (int level = 0; level < (int)self.params.adaptive_depth; level++) {
        float min_penalty = float::max;
        Vec3 level_best;
        foreach (offset : pattern[:pattern_count]) {
            Vec3 candidate = { best.x + offset[0] * ring, 0, best.z + offset[1] * ring };
            if (candidate.x * candidate.x + candidate.z * candidate.z > limit * limit) continue;
            float penalty = process_sample(
                query:       self,
                candidate:   candidate,
                sample_size: ring * ADAPTIVE_SAMPLE_SCALE,
                agent:       &agent,
                min_penalty: min_penalty,
                recorder:    &recorder,
            );
            result.samples++;
            if (penalty < min_penalty) {
                min_penalty = penalty;
                level_best = candidate;
            }
        }
        best = level_best;
        ring *= 0.5f;
    }
    result.velocity = best;
    result.recorded = recorder.count;
    return result;
}

<* Upstream's crowd configuration: adaptive sampling of 7 divisions, 2 rings and depth 5. *>
fn ObstacleAvoidanceParams default_obstacle_avoidance_params() {
    return {
        .velocity_bias           = 0.4f,
        .weight_desired_velocity = 2,
        .weight_current_velocity = 0.75f,
        .weight_side             = 0.75f,
        .weight_time_of_impact   = 2.5f,
        .horizon_time            = 2.5f,
        .grid_size               = 33,
        .adaptive_divisions      = 7,
        .adaptive_rings          = 2,
        .adaptive_depth          = 5,
    };
}

<*
 Free the obstacle arrays.
 @param [&inout] query : "Left zeroed."
*>
fn void destroy_obstacle_avoidance_query(ObstacleAvoidanceQuery* query) {
    alloc::free(query.allocator, query.circles.ptr);
    alloc::free(query.allocator, query.segments.ptr);
    *query = {};
}

<*
 Sampler for max_circles and max_segments obstacles, allocated once.
 @return? c3d::CAPACITY_EXCEEDED
*>
fn ObstacleAvoidanceQuery? create_obstacle_avoidance_query(Allocator allocator, uint max_circles, uint max_segments) {
    ObstacleAvoidanceQuery query = { .allocator = allocator };
    defer catch destroy_obstacle_avoidance_query(&query);
    ObstacleCircle[]? circles = alloc::new_array_try(allocator, ObstacleCircle, max_circles);
    if (catch circles) return c3d::CAPACITY_EXCEEDED~;
    query.circles = circles;
    ObstacleSegment[]? segments = alloc::new_array_try(allocator, ObstacleSegment, max_segments);
    if (catch segments) return c3d::CAPACITY_EXCEEDED~;
    query.segments = segments;
    return query;
}

fn float dot_2d(Vec3 first, Vec3 second) @private => first.x * second.x + first.z * second.z;

// Mirrors the head of both samplers: prepare, then the parameters and speed limits.
fn SamplingAgent begin_sampling(
    ObstacleAvoidanceQuery* query,
    Vec3 position,
    float radius,
    float max_velocity,
    Vec3 velocity,
    Vec3 desired_velocity,
    ObstacleAvoidanceParams* params,
) @local {
    prepare_obstacles(query, position, desired_velocity);
    query.params = *params;
    query.inverse_horizon_time = 1.0f / params.horizon_time;
    query.max_velocity = max_velocity;
    query.inverse_max_velocity = max_velocity > 0 ? 1.0f / max_velocity : float::max;
    return { .position = position, .radius = radius, .velocity = velocity, .desired_velocity = desired_velocity };
}

// Mirrors prepare: the side each circle is passed on, and the segments the agent stands on.
fn void prepare_obstacles(ObstacleAvoidanceQuery* query, Vec3 position, Vec3 desired_velocity) @local {
    foreach (&circle : query.circles[:query.circle_count]) {
        circle.direction = (circle.position - position).normalize();
        Vec3 relative_desired = circle.desired_velocity - desired_velocity;
        if (tri_area_2d({ 0, 0, 0 }, circle.direction, relative_desired) < SIDE_AREA_THRESHOLD) {
            circle.normal = { -circle.direction.z, 0, circle.direction.x };
        } else {
            circle.normal = { circle.direction.z, 0, -circle.direction.x };
        }
    }
    foreach (&segment : query.segments[:query.segment_count]) {
        float distance_sqr = distance_pt_seg_sqr_2d(position, segment.start, segment.end).distance_sqr;
        segment.touch = distance_sqr < TOUCH_DISTANCE * TOUCH_DISTANCE;
    }
}

// Mirrors sampleVelocityAdaptive's pattern: a zero sample, then rings aligned to the desired direction.
fn usz sampling_pattern(
    ObstacleAvoidanceParams* params,
    Vec3 desired_velocity,
    float[<2>][PATTERN_CAPACITY]* pattern,
) @local {
    int divisions = math::clamp((int)params.adaptive_divisions, 1, (int)MAX_PATTERN_DIVISIONS);
    int rings = math::clamp((int)params.adaptive_rings, 1, (int)MAX_PATTERN_RINGS);
    float step = (float)math::PI * 2 / divisions;
    float cos_step = math::cos(step);
    float sin_step = math::sin(step);
    Vec3 direction = normalize_2d(desired_velocity);
    // Odd rings start half a step round, so the rings interleave.
    Vec3[2] ring_starts = { direction, rotate_2d(direction, step * 0.5f) };

    usz count = 1;
    for (int ring = 0; ring < rings; ring++) {
        float scale = (float)(rings - ring) / (float)rings;
        Vec3 start = ring_starts[ring % 2];
        (*pattern)[count] = { start.x * scale, start.z * scale };
        usz clockwise = count;
        usz counter_clockwise = count;
        count++;
        for (int division = 1; division < divisions - 1; division += 2) {
            float[<2>] right = (*pattern)[clockwise];
            float[<2>] left = (*pattern)[counter_clockwise];
            (*pattern)[count] = { right[0] * cos_step + right[1] * sin_step, -right[0] * sin_step + right[1] * cos_step };
            (*pattern)[count + 1] = { left[0] * cos_step - left[1] * sin_step, left[0] * sin_step + left[1] * cos_step };
            clockwise = count;
            counter_clockwise = count + 1;
            count += 2;
        }
        if ((divisions & 1) == 0) {
            // Upstream writes this sample one slot past the one it counts.
            float[<2>] left = (*pattern)[counter_clockwise];
            (*pattern)[count] = { left[0] * cos_step - left[1] * sin_step, left[0] * sin_step + left[1] * cos_step };
            count++;
        }
    }
    return count;
}

// Mirrors processSample: the penalty of a candidate velocity, or min_penalty once it cannot win.
fn float process_sample(
    ObstacleAvoidanceQuery* query,
    Vec3 candidate,
    float sample_size,
    SamplingAgent* agent,
    float min_penalty,
    SampleRecorder* recorder,
) @local {
    ObstacleAvoidanceParams* params = &query.params;
    float desired_penalty = params.weight_desired_velocity
        * (math::sqrt(distance_sqr_2d(candidate, agent.desired_velocity)) * query.inverse_max_velocity);
    float current_penalty = params.weight_current_velocity
        * (math::sqrt(distance_sqr_2d(candidate, agent.velocity)) * query.inverse_max_velocity);

    // An impact sooner than this makes the time penalty alone exceed min_penalty.
    float threshold_time = (params.weight_time_of_impact / (min_penalty - desired_penalty - current_penalty)
        - MIN_IMPACT_TIME) * params.horizon_time;
    if (threshold_time - params.horizon_time > -(float)math::FLOAT_EPSILON) return min_penalty;

    float impact_time = params.horizon_time;
    float side = 0;
    uint side_count;
    foreach (&circle : query.circles[:query.circle_count]) {
        // Reciprocal avoidance: each agent takes half the correction.
        Vec3 relative = candidate * 2 - agent.velocity - circle.velocity;
        float toward = dot_2d(circle.direction, relative) * 0.5f + 0.5f;
        side += math::clamp(math::min(toward, dot_2d(circle.normal, relative) * 2), 0.0f, 1.0f);
        side_count++;

        float[<2>]? sweep = sweep_circle_circle(
            center:       agent.position,
            radius:       agent.radius,
            velocity:     relative,
            other_center: circle.position,
            other_radius: circle.radius,
        );
        if (catch sweep) continue;
        float enter = sweep[0];
        // Overlapping circles are avoided more.
        if (enter < 0 && sweep[1] > 0) enter = -enter * 0.5f;
        if (enter >= 0 && enter < impact_time) {
            impact_time = enter;
            if (impact_time < threshold_time) return min_penalty;
        }
    }

    foreach (&segment : query.segments[:query.segment_count]) {
        float hit_time;
        if (segment.touch) {
            Vec3 along = segment.end - segment.start;
            Vec3 normal = { -along.z, 0, along.x };
            // Moving away from a touched segment is no collision.
            if (dot_2d(normal, candidate) < 0) continue;
            hit_time = 0;
        } else {
            float? hit = intersect_ray_segment(agent.position, candidate, segment.start, segment.end);
            if (catch hit) continue;
            hit_time = hit;
        }
        hit_time *= WALL_TIME_SCALE;
        if (hit_time < impact_time) {
            impact_time = hit_time;
            if (impact_time < threshold_time) return min_penalty;
        }
    }

    // Averaged, so the side bias does not dominate among many neighbours.
    if (side_count) side /= side_count;
    float side_penalty = params.weight_side * side;
    float time_penalty = params.weight_time_of_impact * (1.0f / (MIN_IMPACT_TIME + impact_time * query.inverse_horizon_time));
    float penalty = desired_penalty + current_penalty + side_penalty + time_penalty;
    if (recorder.count < recorder.samples.len) {
        recorder.samples[recorder.count++] = {
            .velocity                 = candidate,
            .size                     = sample_size,
            .penalty                  = penalty,
            .desired_velocity_penalty = desired_penalty,
            .current_velocity_penalty = current_penalty,
            .side_penalty             = side_penalty,
            .collision_time_penalty   = time_penalty,
        };
    }
    return penalty;
}

// Entry and exit times of a moving circle against a still one; c3d::INVALID_ARGUMENT when they never meet.
fn float[<2>]? sweep_circle_circle(
    Vec3 center,
    float radius,
    Vec3 velocity,
    Vec3 other_center,
    float other_radius,
) @local {
    Vec3 offset = other_center - center;
    float combined = radius + other_radius;
    float gap = dot_2d(offset, offset) - combined * combined;
    float speed_sqr = dot_2d(velocity, velocity);
    if (speed_sqr < MIN_SWEEP_SPEED_SQR) return c3d::INVALID_ARGUMENT~;
    float closing = dot_2d(velocity, offset);
    float discriminant = closing * closing - speed_sqr * gap;
    if (discriminant < 0) return c3d::INVALID_ARGUMENT~;
    float root = math::sqrt(discriminant);
    return { (closing - root) / speed_sqr, (closing + root) / speed_sqr };
}

// Time along the ray where it crosses the segment; c3d::INVALID_ARGUMENT when it misses.
fn float? intersect_ray_segment(Vec3 origin, Vec3 direction, Vec3 start, Vec3 end) @local {
    Vec3 along = end - start;
    Vec3 offset = origin - start;
    float denominator = perp_2d(direction, along);
    if (math::abs(denominator) < PARALLEL_RAY_EPSILON) return c3d::INVALID_ARGUMENT~;
    float t = perp_2d(along, offset) / denominator;
    if (t < 0 || t > 1) return c3d::INVALID_ARGUMENT~;
    float s = perp_2d(direction, offset) / denominator;
    if (s < 0 || s > 1) return c3d::INVALID_ARGUMENT~;
    return t;
}

// Mirrors dtNormalize2D: Y is kept, X and Z scale to unit length.
fn Vec3 normalize_2d(Vec3 vector) @local {
    float length = math::sqrt(vector.x * vector.x + vector.z * vector.z);
    if (length == 0) return vector;
    return { vector.x / length, vector.y, vector.z / length };
}

// Mirrors dtRorate2D: a rotation in the XZ plane from +X toward +Z.
fn Vec3 rotate_2d(Vec3 vector, float angle) @local {
    float cosine = math::cos(angle);
    float sine = math::sin(angle);
    return { vector.x * cosine - vector.z * sine, vector.y, vector.x * sine + vector.z * cosine };
}
