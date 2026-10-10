module c3d::test::inertial_pose;

import c3d;
import c3d::anim @public;
import c3d::maths;
import std::math;

const double POSE_TEST_FLOAT_EPSILON @local = 2e-6;
const double POSE_TEST_RATE_EPSILON @local = 1e-10;

struct PoseTestResidual @local {
    double value;
    double rate;
}

struct PoseTestCase @local {
    InertialStorage* storage;
    Transform[2] source;
    Transform[2] target;
    PoseVelocity[2] velocity;
    float[3] source_morph;
    float[3] target_morph;
    double[3] morph_rate;
    bool[2] consumed;
}

struct PoseTestAllocator (Allocator) @local {
    Allocator backing;
    uint acquisitions;
    uint resizes;
    uint releases;
    uint outstanding;
    bool deny;
}

fn void*? PoseTestAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.acquisitions++;
    if (self.deny) return mem::OUT_OF_MEMORY~;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return pointer;
}

fn void*? PoseTestAllocator.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    self.resizes++;
    if (self.deny) return mem::OUT_OF_MEMORY~;
    return self.backing.resize(pointer, size, alignment);
}

fn void PoseTestAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.releases++;
    self.outstanding--;
}

fn PoseTestCase create_pose_test_case(Allocator allocator = mem) @local {
    return {
        .storage = anim::create_inertial_storage(
            allocator: allocator,
            nodes: 2,
            morphs: 3,
            capacity: 1,
        )!!,
        .source = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY },
        .target = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY },
    };
}

fn void capture_pose_test_case(PoseTestCase* sample) @local {
    anim::capture_inertial_pose_residuals(
        row: &sample.storage.rows[0],
        source_pose: sample.source[..],
        source_morph: sample.source_morph[..],
        target_pose: sample.target[..],
        target_velocity: sample.velocity[..],
        target_morph: sample.target_morph[..],
        target_morph_rate: sample.morph_rate[..],
        consumed_scale: sample.consumed[..],
    );
}

fn void apply_pose_test_case(PoseTestCase* sample, double elapsed, double duration = 1) @local {
    anim::apply_inertial_pose(
        row: &sample.storage.rows[0],
        target_pose: sample.target[..],
        target_velocity: sample.velocity[..],
        target_morph: sample.target_morph[..],
        target_morph_rate: sample.morph_rate[..],
        consumed_scale: sample.consumed[..],
        duration: duration,
        elapsed: elapsed,
    );
}

fn void record_pose_test_case(PoseTestCase* sample, bool source, double dt) @local {
    anim::record_inertial_pose_history(
        row: &sample.storage.rows[0],
        published_pose: source ? sample.source[..] : sample.target[..],
        published_morph: source ? sample.source_morph[..] : sample.target_morph[..],
        dt: dt,
    );
}

fn PoseTestResidual pose_test_horner(
    double offset,
    double initial_rate,
    double duration,
    double elapsed,
) @local {
    if (duration == 0 || elapsed >= duration) return {};
    double first = duration * initial_rate;
    double[6] coefficients = {
        offset, first, 0, -10 * offset - 6 * first, 15 * offset + 8 * first, -6 * offset - 3 * first,
    };
    double time = elapsed / duration;
    PoseTestResidual result;
    for (int power = 5; power >= 0; power--) {
        result.rate = result.rate * time + result.value;
        result.value = result.value * time + coefficients[power];
    }
    result.rate /= duration;
    return result;
}

fn void pose_test_near(double actual, double expected, double epsilon = POSE_TEST_RATE_EPSILON) @local {
    assert(math::is_finite(actual));
    assert(math::abs(actual - expected) <= epsilon * (1 + math::abs(expected)));
}

fn void pose_test_vector(double[<3>] actual, double[<3>] expected) @local {
    for (uint axis = 0; axis < 3; axis++) pose_test_near(actual[axis], expected[axis]);
}

fn Quat pose_test_turn(double angle) @local {
    return { .v = { 0, 0, (float)math::sin(angle / 2), (float)math::cos(angle / 2) } };
}

fn double pose_test_turn_angle(Quat rotation) @local {
    return 2 * math::atan2((double)rotation.v.z, (double)rotation.v.w);
}

fn void test_animation_inertial_pose_source_preflight_finite_and_invalid_channels() @test {
    Transform[1] pose = { maths::TRANSFORM_IDENTITY };
    float[1] morph = { -3 };
    pose[0].scale = { -1, 2, -3 };
    pose[0].rotation = { .v = { 0, 0, 0, float::min } };
    anim::validate_inertial_pose_source(pose[..], morph[..])!!;
    pose[0].rotation.v.w = float::max;
    anim::validate_inertial_pose_source(pose[..], morph[..])!!;
    Transform original = pose[0];
    foreach (float invalid : { float::nan, float::inf, -float::inf }) {
        pose[0] = original;
        pose[0].position.y = invalid;
        assert(@catch(anim::validate_inertial_pose_source(pose[..], morph[..])) == c3d::INVALID_ARGUMENT);
        pose[0] = original;
        pose[0].scale.z = invalid;
        assert(@catch(anim::validate_inertial_pose_source(pose[..], morph[..])) == c3d::INVALID_ARGUMENT);
        pose[0] = original;
        pose[0].rotation.v.x = invalid;
        assert(@catch(anim::validate_inertial_pose_source(pose[..], morph[..])) == c3d::INVALID_ARGUMENT);
        pose[0] = original;
        morph[0] = invalid;
        assert(@catch(anim::validate_inertial_pose_source(pose[..], morph[..])) == c3d::INVALID_ARGUMENT);
        morph[0] = -3;
    }
    pose[0] = original;
    pose[0].rotation = {};
    assert(@catch(anim::validate_inertial_pose_source(pose[..], morph[..])) == c3d::INVALID_ARGUMENT);
}

fn void test_animation_inertial_pose_no_history_display_onset_and_extreme_morph_offsets() @test {
    PoseTestCase sample = create_pose_test_case();
    defer anim::destroy_inertial_storage(sample.storage);
    InertialRow* row = &sample.storage.rows[0];
    row.control = { .generation = 17, .active = true, .duration = 4, .elapsed = 0.5 };
    row.velocity[..] = { .translation = { 999, 999, 999 }, .scale = { 999, 999, 999 } };
    row.morph_velocity[..] = 999;
    sample.source[0].position = { 6, -1, 2 };
    sample.source[0].scale = { 3, 3, 3 };
    sample.source[1].position = { -4, 3, 1 };
    sample.source[1].scale = { -1, 2, -3 };
    sample.target[0].scale = { 1, 2, 3 };
    sample.velocity[0].translation = { 0.25, -0.5, 1 };
    sample.velocity[0].scale = { 0.1, 0.2, 0.3 };
    sample.source_morph = { 0.25f, float::max, -float::max };
    sample.target_morph = { 0.75f, -float::max, float::max };
    sample.morph_rate = { 0.2, 0, 0 };
    sample.consumed = { true, false };
    capture_pose_test_case(&sample);
    assert(row.morph_offset[1] == 2 * (double)float::max);
    assert(row.morph_offset[2] == -2 * (double)float::max);
    pose_test_vector(row.offset_velocity[0].translation, { -0.25, 0.5, -1 });
    pose_test_near(row.offset[0].scale.x, math::ln(1.5));
    pose_test_near(row.offset_velocity[0].scale.x, -0.1);
    apply_pose_test_case(&sample, 0);
    for (uint node = 0; node < 2; node++) for (uint axis = 0; axis < 3; axis++) {
        assert(sample.target[node].position[axis] == sample.source[node].position[axis]);
        assert(sample.target[node].scale[axis] == sample.source[node].scale[axis]);
        pose_test_near(sample.velocity[node].translation[axis], 0);
        pose_test_near(sample.velocity[node].scale[axis], 0);
    }
    for (uint index = 0; index < 3; index++) {
        assert(sample.target_morph[index] == sample.source_morph[index]);
        pose_test_near(sample.morph_rate[index], 0);
    }
    assert(!row.control.history_valid && row.control.generation == 17 && row.control.active);
    assert(row.control.duration == 4 && row.control.elapsed == 0.5 && row.control.previous_dt == 0);
    assert(row.previous_pose[0].position.x == 0 && row.previous_morph[0] == 0);
    sample.target[0].position = { 9, 8, 7 };
    sample.target[0].scale = { 1, 2, 3 };
    sample.target_morph = { 0.75f, -float::max, float::max };
    sample.morph_rate = { 0.2, 0, 0 };
    apply_pose_test_case(&sample, 1);
    assert(sample.target[0].position.x == 9 && sample.target[0].scale.x == 2 && sample.target[0].scale.y == 2);
    assert(sample.target_morph[1] == -float::max && sample.target_morph[2] == float::max);
    assert(sample.morph_rate[0] == 0.2);
}

fn void test_animation_inertial_pose_moving_target_independent_oracle_and_interruption() @test {
    PoseTestCase sample = create_pose_test_case();
    defer anim::destroy_inertial_storage(sample.storage);
    InertialRow* row = &sample.storage.rows[0];
    sample.source[0].position = { 4, -2, 1 };
    sample.source[0].scale = { -1, 2, -3 };
    sample.source_morph[0] = -0.5f;
    record_pose_test_case(&sample, true, 0.25);
    sample.target[0].scale = { -2, 1, -1 };
    sample.velocity[0] = {
        .translation = { 1, 2, -1 },
        .angular = { 0, 0, 0.4 },
        .scale = { 0.5, -0.25, 0.2 },
    };
    sample.target_morph[0] = -1;
    sample.morph_rate[0] = 1;
    capture_pose_test_case(&sample);
    float[2] times = { 0, 2 };
    float[6] translations = { 0, 0, 0, 2, 4, -2 };
    Track translation = {
        .path = TargetPath.TRANSLATION,
        .interpolation = Interpolation.LINEAR,
        .times = times[..],
        .values = translations[..],
    };
    double[3] value;
    double[3] rate;
    uint cursor;
    anim::sample_track_analytic(
        track: &translation,
        time: 0.25f,
        cursor: &cursor,
        value: value[..],
        rate: rate[..],
    );
    sample.target[0].position = { (float)value[0], (float)value[1], (float)value[2] };
    sample.velocity[0].translation = { rate[0], rate[1], rate[2] };
    sample.target[0].scale = { -1.875f, 0.9375f, -0.95f };
    sample.target[0].rotation = pose_test_turn(0.1);
    sample.target_morph[0] = -0.75f;
    Transform current_target = sample.target[0];
    double[3] onset_position = { 4, -2, 1 };
    double[3] onset_scale = { 1, 1, -2 };
    double[3] scale_rate = { 0.5, -0.25, 0.2 };
    apply_pose_test_case(&sample, 0.25);
    for (uint axis = 0; axis < 3; axis++) {
        PoseTestResidual position = pose_test_horner(
            offset: onset_position[axis],
            initial_rate: -rate[axis],
            duration: 1,
            elapsed: 0.25,
        );
        pose_test_near(sample.target[0].position[axis],
            (double)current_target.position[axis] + position.value, POSE_TEST_FLOAT_EPSILON);
        pose_test_near(sample.velocity[0].translation[axis], rate[axis] + position.rate);
        PoseTestResidual scale = pose_test_horner(
            offset: onset_scale[axis],
            initial_rate: -scale_rate[axis],
            duration: 1,
            elapsed: 0.25,
        );
        pose_test_near(sample.target[0].scale[axis],
            (double)current_target.scale[axis] + scale.value, POSE_TEST_FLOAT_EPSILON);
        pose_test_near(sample.velocity[0].scale[axis], scale_rate[axis] + scale.rate);
    }
    PoseTestResidual turn = pose_test_horner(offset: 0, initial_rate: -0.4, duration: 1, elapsed: 0.25);
    pose_test_near(
        actual: pose_test_turn_angle(sample.target[0].rotation),
        expected: pose_test_turn_angle(current_target.rotation) + turn.value,
        epsilon: POSE_TEST_FLOAT_EPSILON,
    );
    pose_test_near(sample.velocity[0].angular.z, 0.4 + turn.rate);
    PoseTestResidual morph = pose_test_horner(offset: 0.5, initial_rate: -1, duration: 1, elapsed: 0.25);
    pose_test_near(sample.target_morph[0], -0.75 + morph.value, POSE_TEST_FLOAT_EPSILON);
    pose_test_near(sample.morph_rate[0], 1 + morph.rate);
    record_pose_test_case(&sample, false, 0.25);
    for (uint axis = 0; axis < 3; axis++) {
        pose_test_near(row.velocity[0].translation[axis],
            ((double)sample.target[0].position[axis] - (double)sample.source[0].position[axis]) / 0.25);
        pose_test_near(row.velocity[0].scale[axis],
            ((double)sample.target[0].scale[axis] - (double)sample.source[0].scale[axis]) / 0.25);
    }
    pose_test_near(row.morph_velocity[0], ((double)sample.target_morph[0] - sample.source_morph[0]) / 0.25);
    pose_test_near(
        actual: row.velocity[0].angular.z,
        expected: pose_test_turn_angle(sample.target[0].rotation) / 0.25,
        epsilon: POSE_TEST_FLOAT_EPSILON,
    );
    sample.source = sample.target;
    sample.source_morph = sample.target_morph;
    PoseVelocity source_rate = row.velocity[0];
    double source_morph_rate = row.morph_velocity[0];
    sample.target[0] = {
        .position = { -5, 1, 2 },
        .rotation = pose_test_turn(0.7),
        .scale = { 2, -3, 4 },
    };
    sample.velocity[0] = {
        .translation = { 0.1, -0.4, 0.3 },
        .angular = { 0, 0, -0.2 },
        .scale = { -1, 0.5, -0.4 },
    };
    sample.target_morph[0] = 0.2f;
    sample.morph_rate[0] = 0.25;
    capture_pose_test_case(&sample);
    apply_pose_test_case(&sample, 0, 0.7);
    for (uint axis = 0; axis < 3; axis++) {
        assert(sample.target[0].position[axis] == sample.source[0].position[axis]);
        assert(sample.target[0].scale[axis] == sample.source[0].scale[axis]);
    }
    pose_test_vector(sample.velocity[0].translation, source_rate.translation);
    pose_test_vector(sample.velocity[0].scale, source_rate.scale);
    pose_test_vector(sample.velocity[0].angular, source_rate.angular);
    pose_test_near(
        actual: pose_test_turn_angle(sample.target[0].rotation),
        expected: pose_test_turn_angle(sample.source[0].rotation),
        epsilon: POSE_TEST_FLOAT_EPSILON,
    );
    assert(sample.target_morph[0] == sample.source_morph[0]);
    pose_test_near(sample.morph_rate[0], source_morph_rate);
}

fn void test_animation_inertial_pose_consumed_log_scale_and_unrelated_linear_scale() @test {
    PoseTestCase sample = create_pose_test_case();
    defer anim::destroy_inertial_storage(sample.storage);
    InertialRow* row = &sample.storage.rows[0];
    sample.source[0].scale = { 2.25f, 2.25f, 2.25f };
    sample.source[1].scale = { 0.25f, 0.25f, 0.25f };
    record_pose_test_case(&sample, true, 0.125);
    sample.source[0].scale = { 1, 1, 1 };
    sample.source[1].scale = { -1, -1, -1 };
    record_pose_test_case(&sample, true, 0.125);
    pose_test_vector(row.velocity[0].scale, { -10, -10, -10 });
    pose_test_vector(row.velocity[1].scale, { -10, -10, -10 });
    sample.target = sample.source;
    sample.consumed = { true, false };
    capture_pose_test_case(&sample);
    apply_pose_test_case(&sample, 0.25);
    PoseTestResidual residual = pose_test_horner(offset: 0, initial_rate: -10, duration: 1, elapsed: 0.25);
    assert(residual.value == -1.845703125 && residual.rate == -3.1640625);
    double expected_log = math::exp(residual.value);
    for (uint axis = 0; axis < 3; axis++) {
        assert(sample.target[0].scale[axis] > 0 && sample.target[1].scale[axis] < 0);
        pose_test_near(sample.target[0].scale[axis], expected_log, POSE_TEST_FLOAT_EPSILON);
        pose_test_near(sample.velocity[0].scale[axis], expected_log * residual.rate);
        pose_test_near(sample.target[1].scale[axis], -1 + residual.value, POSE_TEST_FLOAT_EPSILON);
        pose_test_near(sample.velocity[1].scale[axis], residual.rate);
    }
    sample.source[0].scale = { 2, 2, 2 };
    sample.target = sample.source;
    sample.target[0].scale = { 0.5f, 1, 1.5f };
    sample.velocity = {};
    sample.velocity[0].scale = { 0.1, 0.2, 0.3 };
    capture_pose_test_case(&sample);
    sample.target[0].scale = { 0.525f, 1.05f, 1.575f };
    double sampled_mean = ((double)sample.target[0].scale.x + sample.target[0].scale.y + sample.target[0].scale.z) / 3;
    residual = pose_test_horner(
        offset: math::ln(2.0),
        initial_rate: -5.2,
        duration: 1,
        elapsed: 0.25,
    );
    expected_log = sampled_mean * math::exp(residual.value);
    double expected_rate = math::exp(residual.value) * (0.2 + sampled_mean * residual.rate);
    apply_pose_test_case(&sample, 0.25);
    assert(sample.target[0].scale.x == sample.target[0].scale.y
      && sample.target[0].scale.y == sample.target[0].scale.z);
    for (uint axis = 0; axis < 3; axis++) {
        pose_test_near(sample.target[0].scale[axis], expected_log, POSE_TEST_FLOAT_EPSILON);
        pose_test_near(sample.velocity[0].scale[axis], expected_rate);
    }
}

fn void test_animation_inertial_pose_zero_step_and_tiny_dt_use_finite_double_history() @test {
    PoseTestCase sample = create_pose_test_case();
    defer anim::destroy_inertial_storage(sample.storage);
    InertialRow* row = &sample.storage.rows[0];
    row.control = { .generation = 31, .active = true, .duration = 2, .elapsed = 0.75 };
    sample.source[0].position = { -float::max, -float::max, -float::max };
    sample.source[0].scale = { -float::max, -float::max, -float::max };
    sample.source_morph[0] = -float::max;
    record_pose_test_case(&sample, true, 0.5);
    pose_test_vector(row.velocity[0].translation, {});
    pose_test_vector(row.velocity[0].scale, {});
    assert(row.morph_velocity[0] == 0);
    sample.source[0].position = { float::max, float::max, float::max };
    sample.source[0].scale = { float::max, float::max, float::max };
    sample.source_morph[0] = float::max;
    float tiny_dt = 0x1p-140f;
    record_pose_test_case(&sample, true, (double)tiny_dt);
    double expected_rate = (2 * (double)float::max) / (double)tiny_dt;
    assert(expected_rate > (double)float::max && math::is_finite(expected_rate));
    pose_test_vector(row.velocity[0].translation, { expected_rate, expected_rate, expected_rate });
    pose_test_vector(row.velocity[0].scale, { expected_rate, expected_rate, expected_rate });
    pose_test_near(row.morph_velocity[0], expected_rate);
    Transform previous = row.previous_pose[0];
    PoseVelocity previous_velocity = row.velocity[0];
    InertialControl previous_control = row.control;
    double previous_morph_rate = row.morph_velocity[0];
    sample.target[0].position = { 9, 8, 7 };
    record_pose_test_case(&sample, false, 0);
    for (uint axis = 0; axis < 3; axis++) {
        assert(row.previous_pose[0].position[axis] == previous.position[axis]);
        assert(row.previous_pose[0].scale[axis] == previous.scale[axis]);
    }
    pose_test_vector(row.velocity[0].translation, previous_velocity.translation);
    pose_test_vector(row.velocity[0].scale, previous_velocity.scale);
    pose_test_vector(row.velocity[0].angular, previous_velocity.angular);
    assert(row.previous_morph[0] == float::max && row.morph_velocity[0] == previous_morph_rate);
    assert(row.control.previous_dt == previous_control.previous_dt && row.control.history_valid);
    assert(row.control.generation == 31 && row.control.active
      && row.control.duration == 2 && row.control.elapsed == 0.75);
    sample.target[0].position = { -float::max, -float::max, -float::max };
    sample.target[0].scale = { -float::max, -float::max, -float::max };
    sample.target_morph[0] = -float::max;
    capture_pose_test_case(&sample);
    for (uint axis = 0; axis < 3; axis++) {
        assert(row.offset[0].translation[axis] == 2 * (double)float::max);
        assert(row.offset[0].scale[axis] == 2 * (double)float::max);
    }
    assert(row.morph_offset[0] == 2 * (double)float::max);
    apply_pose_test_case(&sample, 0);
    for (uint axis = 0; axis < 3; axis++) {
        assert(sample.target[0].position[axis] == float::max && sample.target[0].scale[axis] == float::max);
        pose_test_near(sample.velocity[0].translation[axis], expected_rate);
        pose_test_near(sample.velocity[0].scale[axis], expected_rate);
    }
    assert(sample.target_morph[0] == float::max && math::is_finite(sample.morph_rate[0]));
    pose_test_near(sample.morph_rate[0], expected_rate);
    sample.target[0].position = { -float::max, -float::max, -float::max };
    sample.target[0].scale = { -float::max, -float::max, -float::max };
    sample.target_morph[0] = -float::max;
    sample.velocity = {};
    sample.morph_rate = {};
    apply_pose_test_case(&sample, 1);
    assert(sample.target[0].position.x == -float::max && sample.target[0].scale.x == -float::max);
    assert(sample.target_morph[0] == -float::max && sample.morph_rate[0] == 0);
    pose_test_vector(sample.velocity[0].translation, {});
}

fn void test_animation_inertial_pose_reserved_rows_do_not_acquire_or_resize() @test {
    PoseTestAllocator allocator = { .backing = mem };
    {
        PoseTestCase sample = create_pose_test_case(&allocator);
        defer anim::destroy_inertial_storage(sample.storage);
        assert(allocator.acquisitions == 1 && allocator.outstanding == 1);
        allocator.deny = true;
        sample.source_morph[0] = 0.3f;
        for (uint iteration = 0; iteration < 32; iteration++) {
            sample.source[0].position.x = (float)iteration / 16;
            sample.target[0] = maths::TRANSFORM_IDENTITY;
            sample.target_morph[0] = 0.6f;
            sample.velocity = {};
            sample.morph_rate = {};
            anim::validate_inertial_pose_source(sample.source[..], sample.source_morph[..])!!;
            capture_pose_test_case(&sample);
            apply_pose_test_case(&sample, 0.25);
            record_pose_test_case(&sample, false, 0.25);
        }
        assert(allocator.acquisitions == 1 && allocator.resizes == 0 && allocator.releases == 0);
        assert(allocator.outstanding == 1);
    }
    assert(allocator.releases == 1 && allocator.outstanding == 0);
}
