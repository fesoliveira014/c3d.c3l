module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::core::mem::allocators;
import std::math;

const double INERTIAL_TEST_MATRIX_EPSILON @local = 1e-4;
const double INERTIAL_TEST_RATE_EPSILON @local = 1e-4;
const double INERTIAL_TEST_ORACLE_SERIES_LIMIT @local = 0.01;
const double POSE_TEST_FLOAT_EPSILON @local = 2e-6;
const double POSE_TEST_RATE_EPSILON @local = 1e-10;
const double ONSET_TEST_EPSILON @local = 1e-6;
const double ROOT_FRAME_MOTION_EPSILON @local = 1e-6;
const double ROOT_FRAME_RATE_EPSILON @local = 1e-6;
const double ROOT_FRAME_FIRST_DECAY @local = 0.99144; // H0(0.1), from the independent quintic polynomial.

enum RequestAdditionKind @local {
    SINGLE,
    SPACE_1D,
    SPACE_2D,
}

struct InertialStorageCase @local {
    uint nodes;
    uint morphs;
    uint capacity;
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

struct OnsetCase @local {
    bool generalized;
    uint group;
    uint mode;
    float duration;
    double smooth;
}

struct RequestBlockSnapshot @local {
    void* pointer;
    char[] bytes;
}

struct RequestTargets @local {
    AnimationTargetDesc[4] actions;
    bool[4] membership;
    JointMask mask;
    WeightedJointMask weighted;
    uint[2] members;
    float[2] positions;
    AnimationTransitionSpaceDesc[1] spaces;
    AnimationTransitionDesc description;
}

struct TransitionPrepareSnapshot @local {
    char[] actions;
    uint[] generations;
    uint[] free;
    AnimationActionId[] order;
    char[] linear;
    char[] planar;
    uint action_count;
    uint free_count;
}

fn Matrix3 inertial_oracle_identity() @local {
    return { .m = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } };
}

fn Matrix3 inertial_oracle_skew(double[<3>] value) @local {
    return { .m = { 0, value.z, -value.y, -value.z, 0, value.x, value.y, -value.x, 0 } };
}

fn Matrix3 inertial_oracle_add(Matrix3 left, Matrix3 right) @local => { .m = left.m + right.m };

fn Matrix3 inertial_oracle_scale(Matrix3 value, double amount) @local => { .m = value.m * amount };

fn Matrix3 inertial_oracle_product(Matrix3 left, Matrix3 right) @local {
    Matrix3 result;
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        for (uint inner = 0; inner < 3; inner++) {
            result.m[column * 3 + row] += left.m[inner * 3 + row] * right.m[column * 3 + inner];
        }
    }
    return result;
}

fn Matrix3 inertial_oracle_transpose(Matrix3 value) @local {
    Matrix3 result;
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        result.m[column * 3 + row] = value.m[row * 3 + column];
    }
    return result;
}

fn Matrix3 inertial_oracle_quaternion_matrix(Quaternion value) @local {
    double[<4>] unit = value.v / value.v.length();
    return {
        .m = {
            1 - 2 * (unit.y * unit.y + unit.z * unit.z),
            2 * (unit.x * unit.y + unit.z * unit.w),
            2 * (unit.x * unit.z - unit.y * unit.w),
            2 * (unit.x * unit.y - unit.z * unit.w),
            1 - 2 * (unit.x * unit.x + unit.z * unit.z),
            2 * (unit.y * unit.z + unit.x * unit.w),
            2 * (unit.x * unit.z + unit.y * unit.w),
            2 * (unit.y * unit.z - unit.x * unit.w),
            1 - 2 * (unit.x * unit.x + unit.y * unit.y),
        },
    };
}

fn Matrix3 inertial_oracle_rodrigues(double[<3>] rotation) @local {
    double angle = rotation.length();
    double square = angle * angle;
    double first;
    double second;
    if (angle < INERTIAL_TEST_ORACLE_SERIES_LIMIT) {
        first = 1 - square / 6 + square * square / 120 - square * square * square / 5040;
        second = 0.5 - square / 24 + square * square / 720 - square * square * square / 40320;
    } else {
        first = math::sin(angle) / angle;
        double half_sine = math::sin(angle * 0.5);
        second = 2 * half_sine * half_sine / square;
    }
    Matrix3 skew = inertial_oracle_skew(rotation);
    return inertial_oracle_add(
        left: inertial_oracle_identity(),
        right: inertial_oracle_add(
            left: inertial_oracle_scale(skew, first),
            right: inertial_oracle_scale(inertial_oracle_product(skew, skew), second),
        ),
    );
}

fn Matrix3 inertial_oracle_rodrigues_derivative(double[<3>] rotation, double[<3>] velocity) @local {
    double angle = rotation.length();
    double square = angle * angle;
    double angle_rate = angle == 0 ? 0 : rotation.dot(velocity) / angle;
    double first;
    double second;
    double first_derivative;
    double second_derivative;
    if (angle < INERTIAL_TEST_ORACLE_SERIES_LIMIT) {
        first = 1 - square / 6 + square * square / 120 - square * square * square / 5040;
        second = 0.5 - square / 24 + square * square / 720 - square * square * square / 40320;
        first_derivative = angle * (-1.0 / 3 + square / 30 - square * square / 840);
        second_derivative = angle * (-1.0 / 12 + square / 180 - square * square / 6720);
    } else {
        first = math::sin(angle) / angle;
        double half_sine = math::sin(angle * 0.5);
        second = 2 * half_sine * half_sine / square;
        first_derivative = (angle * math::cos(angle) - math::sin(angle)) / square;
        second_derivative = (angle * math::sin(angle) - 4 * half_sine * half_sine) / (square * angle);
    }
    Matrix3 skew = inertial_oracle_skew(rotation);
    Matrix3 skew_rate = inertial_oracle_skew(velocity);
    Matrix3 product_rate = inertial_oracle_add(
        left: inertial_oracle_product(skew_rate, skew),
        right: inertial_oracle_product(skew, skew_rate),
    );
    return inertial_oracle_add(
        left: inertial_oracle_add(
            left: inertial_oracle_scale(skew, first_derivative * angle_rate),
            right: inertial_oracle_scale(skew_rate, first),
        ),
        right: inertial_oracle_add(
            left: inertial_oracle_scale(
                value: inertial_oracle_product(skew, skew),
                amount: second_derivative * angle_rate,
            ),
            right: inertial_oracle_scale(product_rate, second),
        ),
    );
}

fn double[<3>] inertial_oracle_spatial_rate(
    double[<3>] rotation,
    double[<3>] residual_rate,
    Quaternion target,
    double[<3>] target_rate,
) @local {
    Matrix3 residual_matrix = inertial_oracle_rodrigues(rotation);
    Matrix3 target_matrix = inertial_oracle_quaternion_matrix(target);
    Matrix3 combined = inertial_oracle_product(residual_matrix, target_matrix);
    Matrix3 derivative = inertial_oracle_add(
        left: inertial_oracle_product(
            left: inertial_oracle_rodrigues_derivative(rotation, residual_rate),
            right: target_matrix,
        ),
        right: inertial_oracle_product(
            left: residual_matrix,
            right: inertial_oracle_product(inertial_oracle_skew(target_rate), target_matrix),
        ),
    );
    Matrix3 spatial = inertial_oracle_product(derivative, inertial_oracle_transpose(combined));
    return { (spatial.m21 - spatial.m12) * 0.5, (spatial.m02 - spatial.m20) * 0.5,
        (spatial.m10 - spatial.m01) * 0.5 };
}

fn void inertial_assert_matrix(Quaternion actual, Matrix3 expected) @local {
    Matrix3 observed = inertial_oracle_quaternion_matrix(actual);
    for (uint index = 0; index < 9; index++) {
        assert(math::abs(observed.m[index] - expected.m[index]) <= INERTIAL_TEST_MATRIX_EPSILON);
    }
}

fn void inertial_assert_rate(double[<3>] actual, double[<3>] expected) @local {
    assert((actual - expected).length() <= INERTIAL_TEST_RATE_EPSILON * (1 + expected.length()));
}

fn Quaternion inertial_input_rotation(double[<3>] rotation) @local {
    double angle = rotation.length();
    if (angle == 0) return { .v = { 0, 0, 0, 1 } };
    return quaternion::from_axis_angle{double}(rotation / angle, angle);
}

fn void test_animation_inertial_math_quintic_basis_residuals_and_endpoints_are_literal() @test {
    InertialQuinticBasis middle = anim::inertial_quintic_basis(0.5);
    assert(middle.value == 0.5 && middle.velocity == 0.15625);
    double scalar = anim::inertial_scalar_residual(
        offset: 3,
        velocity: -2,
        duration: 2,
        elapsed: 1,
    );
    assert(scalar == 0.875);
    double[<3>] vector = anim::inertial_vector_residual(
        offset: { 3, -4, 0.5 },
        velocity: { -2, 1.5, 5 },
        duration: 2,
        elapsed: 1,
    );
    assert(vector == (double[<3>]){ 0.875, -1.53125, 1.8125 });
    double[3][3] controls = { { 2, 0, 3 }, { 2, 3, 0 }, { 0, 0, 0 } };
    foreach (control : controls) {
        double value = anim::inertial_scalar_residual(
            offset: 3,
            velocity: -2,
            duration: control[0],
            elapsed: control[1],
        );
        assert(value == control[2]);
    }
}

fn void test_animation_inertial_math_half_turn_ties_and_transported_onset_rate() @test {
    Quaternion[3] half_turns = {
        { .v = { -1, 0, 0, 0 } }, { .v = { 0, -1, 0, 0 } }, { .v = { 0, 0, -1, 0 } },
    };
    foreach (half_turn : half_turns) {
        double[<3>] actual = anim::inertial_rotation_log(half_turn);
        double[<3>] opposite = anim::inertial_rotation_log(-half_turn);
        assert(actual == opposite && actual.x >= 0 && actual.y >= 0 && actual.z >= 0);
        assert(math::abs(actual.length() - math::PI) < 1e-14);
        inertial_assert_matrix(anim::inertial_rotation_exp(actual), inertial_oracle_quaternion_matrix(half_turn));
    }
    Quaternion mixed = { .v = { 2.0 / 3, -1.0 / 3, 2.0 / 3, 0 } };
    double[<3>] mixed_log = anim::inertial_rotation_log(mixed);
    assert(mixed_log.x > 0 && mixed_log.y < 0 && mixed_log.z > 0);
    assert(mixed_log == anim::inertial_rotation_log(-mixed));
    foreach (double scale : { 1e-200, 1e-40, 1e30, 1e200 }) {
        Quaternion scaled_identity = { .v = { 0, 0, 0, scale } };
        assert(anim::inertial_rotation_log(scaled_identity) == (double[<3>]){});
    }
    double[<3>] residual = { 0, 0, math::PI * 0.5 };
    double[<3>] source_rate = { 1, 2, 3 };
    double[<3>] target_rate = { 3, -1, 2 };
    Quaternion identity = { .v = { 0, 0, 0, 1 } };
    double[<3>] transported = anim::inertial_onset_rotation_rate(residual, source_rate, target_rate);
    inertial_assert_rate(
        actual: inertial_oracle_spatial_rate(
            rotation: residual,
            residual_rate: transported,
            target: identity,
            target_rate: target_rate,
        ),
        expected: source_rate,
    );
    double[<3>] naive = inertial_oracle_spatial_rate(
        rotation: residual,
        residual_rate: source_rate - target_rate,
        target: identity,
        target_rate: target_rate,
    );
    assert((naive - source_rate).length() > 0.1);
}

fn void test_animation_inertial_math_fixed_angles_signs_and_series_boundary() @test {
    double[9] angles = {
        0, 1e-9, 1e-4 * 0.9999, 1e-4 * 1.0001,
        math::PI / 6, math::PI * 0.5, math::PI * 179 / 180, math::PI, 0.3,
    };
    double[<3>] axis = { 2.0 / 3, -1.0 / 3, 2.0 / 3 };
    Quaternion target = inertial_input_rotation({ -0.2, 0.7, 0.3 });
    double[<3>] source_rate = { 1.1, -0.4, 0.7 };
    double[<3>] target_rate = { -0.2, 0.9, 0.5 };
    foreach (angle : angles) {
        Quaternion source = inertial_input_rotation(axis * angle).mul(target);
        inertial_assert_matrix(anim::inertial_rotation_exp(axis * angle), inertial_oracle_rodrigues(axis * angle));
        for (uint signs = 0; signs < 4; signs++) {
            Quaternion signed_source = (signs & 1) != 0 ? -source : source;
            Quaternion signed_target = (signs & 2) != 0 ? -target : target;
            double[<3>] initial = anim::inertial_rotation_log(signed_source.mul(signed_target.conjugate()));
            double[<3>] initial_rate = anim::inertial_onset_rotation_rate(initial, source_rate, target_rate);
            Quaternion actual = anim::inertial_correct_rotation(
                initial: initial,
                initial_rate: initial_rate,
                duration: 0.7,
                elapsed: 0,
                target: signed_target,
            );
            inertial_assert_matrix(actual, inertial_oracle_quaternion_matrix(signed_source));
            inertial_assert_rate(
                actual: inertial_oracle_spatial_rate(
                    rotation: initial,
                    residual_rate: initial_rate,
                    target: signed_target,
                    target_rate: target_rate,
                ),
                expected: source_rate,
            );
        }
    }
}

fn void test_animation_inertial_math_zero_completion_and_repeated_corrected_interruptions() @test {
    double[<3>] initial = { 0.4, -0.8, 0.2 };
    Quaternion target = inertial_input_rotation({ 0.2, 0.1, -0.5 });
    double[<3>] initial_rate = anim::inertial_onset_rotation_rate(initial, { -0.4, 0.7, 1.1 }, { 0.2, -0.6, 0.3 });
    foreach (double duration : { 0.0, 1.0 }) {
        foreach (double elapsed : { 1.0, 2.0 }) {
            Quaternion completed = anim::inertial_correct_rotation(
                initial: initial,
                initial_rate: initial_rate,
                duration: duration,
                elapsed: elapsed,
                target: target,
            );
            inertial_assert_matrix(completed, inertial_oracle_quaternion_matrix(target));
        }
    }
    foreach (double elapsed : { 1e-4, 0.5, 1 - 1e-6, 0.25 }) {
        Quaternion current = anim::inertial_correct_rotation(
            initial: initial,
            initial_rate: initial_rate,
            duration: 1,
            elapsed: elapsed,
            target: target,
        );
        Quaternion replacement = inertial_input_rotation({ -0.3, 0.2, 0.7 });
        initial = anim::inertial_rotation_log(current.mul(replacement.conjugate()));
        initial_rate = anim::inertial_onset_rotation_rate(initial, { 0.3, 0.1, -0.2 }, { -0.1, 0.5, -0.4 });
        Quaternion onset = anim::inertial_correct_rotation(
            initial: initial,
            initial_rate: initial_rate,
            duration: 0.8,
            elapsed: 0,
            target: replacement,
        );
        inertial_assert_matrix(onset, inertial_oracle_quaternion_matrix(current));
        target = replacement;
    }
}

fn void check_inertial_region(
    void* block,
    usz bytes,
    void* pointer,
    usz region_bytes,
    usz alignment,
) @local {
    usz start = (usz)pointer;
    assert(start % alignment == 0 && start >= (usz)block);
    assert(start - (usz)block + region_bytes <= bytes);
}

fn void test_animation_inertial_storage_single_block_alignment_and_row_lengths() @test {
    InertialStorageCase[2] cases = {
        { .nodes = 4, .morphs = 2, .capacity = 1 },
        { .nodes = 520, .morphs = 9, .capacity = 16 },
    };
    foreach (sample : cases) {
        MotionTestAllocator allocator = { .backing = mem };
        {
            InertialStorage* storage = anim::create_inertial_storage(
                allocator: &allocator,
                nodes: sample.nodes,
                morphs: sample.morphs,
                capacity: sample.capacity,
            )!!;
            defer anim::destroy_inertial_storage(storage);
            usz bytes = (usz)allocator.bytes;
            assert((void*)storage == allocator.pointer && allocator.acquisitions == 1 && allocator.outstanding == 1);
            assert(allocator.resizes == 0 && allocator.releases == 0 && storage.rows.len == sample.capacity);
            assert(bytes == anim::inertial_storage_bytes(sample.nodes, sample.morphs, sample.capacity));
            foreach (row : storage.rows) {
                assert(row.previous_pose.len == sample.nodes && row.velocity.len == sample.nodes);
                assert(row.offset.len == sample.nodes && row.offset_velocity.len == sample.nodes);
                assert(row.consumed_scale.len == sample.nodes && row.previous_morph.len == sample.morphs);
                assert(row.morph_velocity.len == sample.morphs && row.morph_offset.len == sample.morphs);
                assert(row.morph_offset_velocity.len == sample.morphs);
                check_inertial_region(
                    block: storage,
                    bytes: bytes,
                    pointer: row.previous_pose.ptr,
                    region_bytes: (usz)row.previous_pose.len * Transform::size,
                    alignment: Transform::alignment,
                );
                foreach (values : (PoseVelocity[][3]){ row.velocity, row.offset, row.offset_velocity }) {
                    check_inertial_region(
                        block: storage,
                        bytes: bytes,
                        pointer: values.ptr,
                        region_bytes: (usz)values.len * PoseVelocity::size,
                        alignment: PoseVelocity::alignment,
                    );
                }
                foreach (values : (double[][3]){ row.morph_velocity, row.morph_offset, row.morph_offset_velocity }) {
                    check_inertial_region(
                        block: storage,
                        bytes: bytes,
                        pointer: values.ptr,
                        region_bytes: (usz)values.len * double::size,
                        alignment: double::alignment,
                    );
                }
                check_inertial_region(
                    block: storage,
                    bytes: bytes,
                    pointer: row.consumed_scale.ptr,
                    region_bytes: (usz)row.consumed_scale.len,
                    alignment: 1,
                );
                assert(!row.control.history_valid && !row.control.active && !row.root.target_rate_pending);
            }
        }
        assert(allocator.outstanding == 0 && allocator.releases == 1);
    }
}

fn PoseVelocity inertial_storage_row_velocity(usz index) @local {
    return {
        .translation = { (double)index + 1, -2, 3 },
        .angular = { 4, (double)index + 5, -6 },
        .scale = { 7, 8, (double)index + 9 },
    };
}

fn void test_animation_inertial_storage_reset_clears_one_incarnation_without_touching_other_rows_or_allocating() @test {
    MotionTestAllocator allocator = { .backing = mem };
    InertialStorage* storage = anim::create_inertial_storage(
        allocator: &allocator,
        nodes: 4,
        morphs: 5,
        capacity: 4,
    )!!;
    defer anim::destroy_inertial_storage(storage);
    foreach (usz index, &row : storage.rows) {
        row.previous_pose[..] = maths::TRANSFORM_IDENTITY;
        row.previous_pose[0].position = { (float)index + 1, 2, 3 };
        row.velocity[..] = inertial_storage_row_velocity(index);
        row.offset[..] = inertial_storage_row_velocity(index);
        row.offset_velocity[..] = inertial_storage_row_velocity(index);
        row.previous_morph[..] = (float)index + 1;
        row.morph_velocity[..] = (double)float::max * 2;
        row.morph_offset[..] = -(double)float::max * 2;
        row.morph_offset_velocity[..] = 0x1p-140;
        row.consumed_scale[..] = true;
        row.control = { .history_valid = true, .active = true, .duration = 3, .elapsed = 1 };
        row.root = {
            .published_translation = { 1, 2, 3 },
            .translation_rate = { 4, 5, 6 }, .twist_rate = 0.25,
            .source_translation_rate = { 7, 8, 9 }, .source_twist_rate = 0.125,
            .residual_translation_rate = { -1, -2, -3 }, .residual_twist_rate = -0.5,
            .target_rate_pending = true,
        };
    }
    for (uint reset = 0; reset < 100; reset++) anim::reset_inertial_row(storage, 1);
    InertialRow* cleared = &storage.rows[1];
    assert(!cleared.control.history_valid && !cleared.control.active);
    assert(cleared.control.duration == 0 && cleared.control.elapsed == 0);
    foreach (pose : cleared.previous_pose) {
        assert(pose.position == (Vec3){} && pose.scale == (Vec3){ 1, 1, 1 });
        assert(pose.rotation.l == 1);
    }
    foreach (values : (PoseVelocity[][3]){ cleared.velocity, cleared.offset, cleared.offset_velocity }) {
        foreach (value : values) {
            assert(value.translation == (double[<3>]){} && value.angular == (double[<3>]){});
            assert(value.scale == (double[<3>]){});
        }
    }
    foreach (value : cleared.previous_morph) assert(value == 0);
    foreach (values : (double[][3]){ cleared.morph_velocity, cleared.morph_offset, cleared.morph_offset_velocity }) {
        foreach (value : values) assert(value == 0);
    }
    foreach (value : cleared.consumed_scale) assert(!value);
    RootInertialState empty = { .latest_up = { 0, 1, 0 }, .source_up = { 0, 1, 0 } };
    assert(mem::equals(&cleared.root, &empty, RootInertialState::size));
    foreach (index : (usz[3]){ 0, 2, 3 }) {
        InertialRow* row = &storage.rows[index];
        PoseVelocity expected = inertial_storage_row_velocity(index);
        assert(row.control.history_valid && row.root.target_rate_pending);
        assert(row.previous_pose[0].position == (Vec3){ (float)index + 1, 2, 3 });
        foreach (values : (PoseVelocity[][3]){ row.velocity, row.offset, row.offset_velocity }) {
            foreach (value : values) assert(mem::equals(&value, &expected, PoseVelocity::size));
        }
        foreach (value : row.previous_morph) assert(value == (float)index + 1);
        foreach (value : row.morph_velocity) assert(value == (double)float::max * 2);
        foreach (value : row.morph_offset) assert(value == -(double)float::max * 2);
        foreach (value : row.morph_offset_velocity) assert(value == 0x1p-140);
        foreach (value : row.consumed_scale) assert(value);
    }
    assert(allocator.acquisitions == 1 && allocator.resizes == 0 && allocator.releases == 0);
}

fn void test_animation_inertial_storage_failed_acquisition_leaves_no_owner() @test {
    MotionTestAllocator failing = { .backing = mem, .failure = 1 };
    assert(@catch(anim::create_inertial_storage(
        allocator: &failing,
        nodes: 57,
        morphs: 9,
        capacity: 16,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(failing.acquisitions == 1 && failing.outstanding == 0 && failing.releases == 0);
}

fn bool inertial_owner_allocation_is_live(TrackingAllocator* tracker, void* pointer) @local {
    @pool() {
        foreach (allocation : tracker.allocations_tlist(tmem)) {
            if (allocation.ptr == pointer) return true;
        }
    };
    return false;
}

fn void test_animation_inertial_owners_animator_opt_in_has_one_private_row_and_removal_frees_it() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        assert(fixture.animator.inertial_storage == null);
        sz disabled_bytes = tracker.allocated();
        fixture.scene.remove_component(fixture.root, Animator);
        sz without_animator = tracker.allocated();
        Animator* disabled = anim::add_animator(&fixture.scene, fixture.root);
        assert(disabled.inertial_storage == null && tracker.allocated() == disabled_bytes);
        fixture.scene.remove_component(fixture.root, Animator);
        assert(tracker.allocated() == without_animator);
        Animator* enabled = anim::add_animator(&fixture.scene, fixture.root, { .inertia_enabled = true });
        InertialStorage* storage = enabled.inertial_storage;
        assert(storage && storage.rows.len == 1);
        assert(storage.rows[0].previous_pose.len == 4 && storage.rows[0].previous_morph.len == 1);
        assert(!storage.rows[0].control.history_valid && !storage.rows[0].control.active);
        assert(storage.rows[0].previous_pose.ptr != enabled.pose_storage.destination.pose.ptr);
        void* block = storage;
        assert(inertial_owner_allocation_is_live(&tracker, block));
        ClipId clip = layer_translation(&fixture, { 1, 2, 3 });
        enabled.play(&fixture.assets, clip, { .additive = true })!!;
        fixture.scene.remove_component(fixture.root, Animator);
        assert(!inertial_owner_allocation_is_live(&tracker, block));
        assert(tracker.allocated() == without_animator);
        enabled = anim::add_animator(&fixture.scene, fixture.root, { .inertia_enabled = true });
        block = enabled.inertial_storage;
        fixture.scene.remove(fixture.root);
        assert(!inertial_owner_allocation_is_live(&tracker, block));
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_inertial_owners_prepared_crowd_reserves_capacity_and_replacement_resets_incarnations() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = fixture.assets.model(fixture.model).data.clips[0];
        CrowdInstance[2] seeds = {
            {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = clip, .speed = 1, .loop = true },
                .color = { 1, 1, 1, 1 },
            },
            {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = clip, .time = 0.25f, .speed = 1, .loop = true },
                .color = { 1, 1, 1, 1 },
            },
        };
        for (uint enabled = 0; enabled < 2; enabled++) {
            Node* owner = fixture.scene.add_node(name: "inertial_crowd")!!;
            model::attach_crowd(
                assets: &fixture.assets,
                scene: &fixture.scene,
                node: owner,
                model: fixture.model,
                capacity: 4,
                pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
                instances: seeds[..],
                actions_per_instance: 4,
                event_capacity: 0,
            )!!;
            AnimatedCrowd* crowd = fixture.scene.get(owner, AnimatedCrowd);
            crowd.inertia_enabled = enabled != 0;
            assert(!crowd.is_prepared());
            model::prepare_crowd(&fixture.assets, &fixture.scene, owner)!!;
            if (!enabled) {
                assert(crowd.playback.inertial_storage == null);
                fixture.scene.remove(owner);
                continue;
            }
            InertialStorage* storage = crowd.playback.inertial_storage;
            assert(storage && storage.rows.len == 4 && crowd.count == 2);
            assert(storage.rows[0].previous_pose.len == 4 && storage.rows[0].previous_morph.len == 1);
            foreach (index, &row : storage.rows) {
                assert(!row.control.history_valid && !row.control.active);
                row.control.history_valid = true;
                row.control.active = true;
                row.root.target_rate_pending = true;
                row.velocity[0].translation = { (double)index + 1, 2, 3 };
                row.morph_offset[0] = (double)index + 5;
            }
            assert(storage.rows[0].previous_pose.ptr != crowd.playback.poses.ptr);
            assert(storage.rows[0].previous_pose.ptr != crowd.playback.pose_storage.destination.pose.ptr);
            CrowdInstanceId stale = crowd.playback.instance_id(0)!!;
            void* block = storage;
            uint[4] generations;
            foreach (index, slot : crowd.playback.slots) generations[index] = slot.generation;
            seeds[0].pose.time = 0.5f;
            model::set_crowd(
                assets: &fixture.assets,
                scene: &fixture.scene,
                node: owner,
                instances: seeds[:1],
            )!!;
            assert(crowd.playback.inertial_storage == storage && storage.rows.len == 4 && crowd.count == 1);
            assert(@catch(crowd.playback.player(stale)) == c3d::INVALID_ID);
            foreach (index, row : storage.rows) {
                assert(crowd.playback.slots[index].generation == generations[index] + 1);
                assert(!row.control.history_valid && !row.control.active && !row.root.target_rate_pending);
                assert(row.velocity[0].translation == (double[<3>]){} && row.morph_offset[0] == 0);
            }
            fixture.scene.remove(owner);
            assert(!inertial_owner_allocation_is_live(&tracker, block));
        }
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_inertial_owners_crowd_creation_failure_at_every_allocation_releases_reserved_rows() @test {
    NodeTemplate[4] nodes;
    foreach (&node : nodes) *node = { .parent = -1, .local = maths::TRANSFORM_IDENTITY };
    float[2] morphs = { 0.25f, 0.75f };
    ModelMesh[1] meshes = { { .node = 3, .default_morph_weights = morphs[..] } };
    ModelTemplate template = { .nodes = nodes[..], .meshes = meshes[..] };
    Transform[4] placements;
    placements[..] = maths::TRANSFORM_IDENTITY;
    MotionTestAllocator probe = { .backing = mem };
    uint attempts;
    {
        CrowdPlaybackState* state = anim::create_crowd_playback(
            allocator: &probe,
            template: &template,
            placements: placements[..],
            actions_per_instance: 4,
            event_capacity: 0,
            inertia_enabled: true,
        )!!;
        defer anim::destroy_crowd_playback(state);
        attempts = probe.attempts;
        assert(state.inertial_storage.rows.len == placements.len);
        assert(state.inertial_storage.rows[0].previous_morph.len == 2);
    }
    assert(probe.outstanding == 0);
    for (uint failure = 1; failure <= attempts; failure++) {
        MotionTestAllocator failing = { .backing = mem, .failure = failure };
        assert(@catch(anim::create_crowd_playback(
            allocator: &failing,
            template: &template,
            placements: placements[..],
            actions_per_instance: 4,
            event_capacity: 0,
            inertia_enabled: true,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(failing.attempts == failure && failing.outstanding == 0);
    }
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
        target_morph: sample.target_morph[..],
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

fn void test_animation_inertial_pose_no_history_display_onset_and_extreme_morph_offsets() @test {
    PoseTestCase sample = create_pose_test_case();
    defer anim::destroy_inertial_storage(sample.storage);
    InertialRow* row = &sample.storage.rows[0];
    row.control = { .active = true, .duration = 4, .elapsed = 0.5 };
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
    }
    for (uint index = 0; index < 3; index++) assert(sample.target_morph[index] == sample.source_morph[index]);
    assert(!row.control.history_valid && row.control.active);
    assert(row.control.duration == 4 && row.control.elapsed == 0.5);
    assert(row.previous_pose[0].position.x == 0 && row.previous_morph[0] == 0);
    sample.target[0].position = { 9, 8, 7 };
    sample.target[0].scale = { 1, 2, 3 };
    sample.target_morph = { 0.75f, -float::max, float::max };
    apply_pose_test_case(&sample, 1);
    assert(sample.target[0].position.x == 9 && sample.target[0].scale == (Vec3){ 1, 2, 3 });
    assert(sample.target_morph[1] == -float::max && sample.target_morph[2] == float::max);
}

fn void test_animation_inertial_pose_moving_target_literal_residuals_and_interruption() @test {
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
    uint cursor;
    anim::sample_track_double(
        track: &translation,
        time: 0.25f,
        cursor: &cursor,
        value: value[..],
    );
    sample.target[0].position = { (float)value[0], (float)value[1], (float)value[2] };
    sample.target[0].scale = { -1.875f, 0.9375f, -0.95f };
    sample.target[0].rotation = pose_test_turn(0.1);
    sample.target_morph[0] = -0.75f;
    double[3] expected_position = { 3.6513671875, -1.662109375, 0.8310546875 };
    double[3] expected_scale = { -1.07080078125, 1.880126953125, -2.7798828005791 };
    apply_pose_test_case(&sample, 0.25);
    for (uint axis = 0; axis < 3; axis++) {
        pose_test_near(sample.target[0].position[axis], expected_position[axis], POSE_TEST_FLOAT_EPSILON);
        pose_test_near(sample.target[0].scale[axis], expected_scale[axis], POSE_TEST_FLOAT_EPSILON);
    }
    pose_test_near(pose_test_turn_angle(sample.target[0].rotation), 0.026171875, POSE_TEST_FLOAT_EPSILON);
    pose_test_near(sample.target_morph[0], -0.486328125, POSE_TEST_FLOAT_EPSILON);
    record_pose_test_case(&sample, false, 0.25);
    for (uint axis = 0; axis < 3; axis++) {
        pose_test_near(
            actual: row.velocity[0].translation[axis],
            expected: ((double)sample.target[0].position[axis] - (double)sample.source[0].position[axis]) / 0.25,
        );
        pose_test_near(
            actual: row.velocity[0].scale[axis],
            expected: ((double)sample.target[0].scale[axis] - (double)sample.source[0].scale[axis]) / 0.25,
        );
    }
    pose_test_near(row.morph_velocity[0], ((double)sample.target_morph[0] - sample.source_morph[0]) / 0.25);
    pose_test_near(
        actual: row.velocity[0].angular.z,
        expected: pose_test_turn_angle(sample.target[0].rotation) / 0.25,
        epsilon: POSE_TEST_FLOAT_EPSILON,
    );
    sample.source = sample.target;
    sample.source_morph = sample.target_morph;
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
    pose_test_near(
        actual: pose_test_turn_angle(sample.target[0].rotation),
        expected: pose_test_turn_angle(sample.source[0].rotation),
        epsilon: POSE_TEST_FLOAT_EPSILON,
    );
    assert(sample.target_morph[0] == sample.source_morph[0]);
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
    double expected_log = math::exp(-1.845703125);
    for (uint axis = 0; axis < 3; axis++) {
        assert(sample.target[0].scale[axis] > 0 && sample.target[1].scale[axis] < 0);
        pose_test_near(sample.target[0].scale[axis], expected_log, POSE_TEST_FLOAT_EPSILON);
        pose_test_near(sample.target[1].scale[axis], -1 - 1.845703125, POSE_TEST_FLOAT_EPSILON);
    }
    sample.source[0].scale = { 2, 2, 2 };
    sample.target = sample.source;
    sample.target[0].scale = { 0.5f, 1, 1.5f };
    sample.velocity = {};
    sample.velocity[0].scale = { 0.1, 0.2, 0.3 };
    capture_pose_test_case(&sample);
    sample.target[0].scale = { 0.525f, 1.05f, 1.575f };
    apply_pose_test_case(&sample, 0.25);
    assert(sample.target[0].scale.x == sample.target[0].scale.y
      && sample.target[0].scale.y == sample.target[0].scale.z);
    for (uint axis = 0; axis < 3; axis++) {
        pose_test_near(sample.target[0].scale[axis], 0.7485780154827066, POSE_TEST_FLOAT_EPSILON);
    }
}

fn void test_animation_inertial_pose_zero_step_and_tiny_dt_use_finite_double_history() @test {
    PoseTestCase sample = create_pose_test_case();
    defer anim::destroy_inertial_storage(sample.storage);
    InertialRow* row = &sample.storage.rows[0];
    row.control = { .active = true, .duration = 2, .elapsed = 0.75 };
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
    assert(row.control.history_valid);
    assert(row.control.active && row.control.duration == 2 && row.control.elapsed == 0.75);
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
    }
    assert(sample.target_morph[0] == float::max);
    sample.target[0].position = { -float::max, -float::max, -float::max };
    sample.target[0].scale = { -float::max, -float::max, -float::max };
    sample.target_morph[0] = -float::max;
    apply_pose_test_case(&sample, 1);
    assert(sample.target[0].position.x == -float::max && sample.target[0].scale.x == -float::max);
    assert(sample.target_morph[0] == -float::max);
}

fn void test_animation_inertial_pose_reserved_rows_do_not_acquire_or_resize() @test {
    MotionTestAllocator allocator = { .backing = mem };
    {
        PoseTestCase sample = create_pose_test_case(&allocator);
        defer anim::destroy_inertial_storage(sample.storage);
        assert(allocator.acquisitions == 1 && allocator.outstanding == 1);
        allocator.failure = allocator.attempts + 1;
        sample.source_morph[0] = 0.3f;
        for (uint iteration = 0; iteration < 32; iteration++) {
            sample.source[0].position.x = (float)iteration / 16;
            sample.target[0] = maths::TRANSFORM_IDENTITY;
            sample.target_morph[0] = 0.6f;
            sample.velocity = {};
            sample.morph_rate = {};
            capture_pose_test_case(&sample);
            apply_pose_test_case(&sample, 0.25);
            record_pose_test_case(&sample, false, 0.25);
        }
        assert(allocator.acquisitions == 1 && allocator.resizes == 0 && allocator.releases == 0);
        assert(allocator.outstanding == 1);
    }
    assert(allocator.releases == 1 && allocator.outstanding == 0);
}

fn void create_onset_owner(LayerFixture* owner, bool evaluate_base = true, Vec3 baseline_child = {}) @local {
    owner.assets = asset::create_asset_store(mem, {
        .max_geometries = 1,
        .max_textures = 8,
        .max_materials = 1,
        .max_samplers = 8,
        .max_models = 1,
        .max_skeletons = 1,
        .max_clips = 8,
    });
    owner.scene = scene::create_scene(mem, { .max_nodes = 8 });
    ModelTemplate template = { .nodes = alloc::new_array(mem, NodeTemplate, 3) };
    foreach (index, &node : template.nodes) {
        *node = { .parent = index == 0 ? -1 : 0, .local = maths::TRANSFORM_IDENTITY };
    }
    template.nodes[1].local.position = baseline_child;
    owner.model = owner.assets.add_model_owned(&template)!!;
    owner.root = model::instantiate(&owner.assets, &owner.scene, owner.model)!!;
    owner.animator = anim::add_animator(&owner.scene, owner.root, { .inertia_enabled = true });
    owner.animator.root_node = 0;
    if (evaluate_base) anim::update(&owner.assets, &owner.scene, 0);
}

fn ClipId onset_clip(
    LayerFixture* owner,
    float first,
    float later,
    bool smooth,
) @local {
    AnimationClip clip = {
        .duration = 1,
        .tracks = alloc::new_array(mem, Track, smooth ? 4 : 2),
        .targets = alloc::new_array(mem, uint, smooth ? 4 : 2),
    };
    foreach (index, &track : clip.tracks) {
        *track = {
            .target = (uint)index,
            .path = index == 3 ? TargetPath.SCALE : TargetPath.TRANSLATION,
            .interpolation = index < 2 ? Interpolation.STEP : Interpolation.LINEAR,
            .times = alloc::new_array(mem, float, 3),
            .values = alloc::new_array(mem, float, 9),
        };
        track.times[..] = ((float[3]){ 0, 0.5f, 1 })[..];
        if (index < 2) {
            track.values[..] = ((float[9]){ first, 0, 0, later, 0, 0, later, 0, 0 })[..];
        } else if (index == 2) {
            track.values[..] = ((float[9]){ 0, 0, 0, 0, 1, 0, 0, 2, 0 })[..];
        } else {
            track.values[..] = ((float[9]){ 1, 1, 1, 1.5f, 1.5f, 1.5f, 2, 2, 2 })[..];
        }
        clip.targets[index] = index == 3 ? 0 : (uint)index;
    }
    ClipId id = owner.assets.add_clip_owned(&clip)!!;
    if (smooth) {
        ClipEvent[1] events = { { .time = 0.5f, .id = 91 } };
        owner.assets.set_clip_events(id, events[..])!!;
    }
    return id;
}

fn PlayDesc onset_play(bool generalized) @local {
    return {
        .root_motion = RootMotion.EXTRACT,
        .extraction = {
            .generalized = generalized,
            .translation_axes = { generalized, false, false },
            .up = generalized ? (Vec3){ 0, 1, 0 } : (Vec3){},
        },
    };
}

fn AnimationTargetDesc onset_step_target(LayerFixture* owner, float speed, bool generalized) @local {
    AnimationTargetDesc target = anim::ANIMATION_TARGET_DEFAULT;
    target.clip = onset_clip(
        owner: owner,
        first: 0,
        later: 10,
        smooth: false,
    );
    target.start_time = 0.5f;
    target.speed = speed;
    target.loop = false;
    target.play = onset_play(generalized);
    return target;
}

fn void onset_assert_zero_motion(LayerFixture* owner) @local {
    RootMotionDelta delta = owner.animator.root_motion;
    assert(delta.translation == (Vec3){});
    assert(delta.rotation.v == (Vec4){ 0, 0, 0, 1 });
}

fn void test_animation_inertial_onset_step_side_survives_zero_updates_and_first_positive_endpoint() @test {
    OnsetCase[4] cases = {
        { .group = 0, .mode = 1, .duration = 0.75f, .smooth = 0.0684799382716 },
        { .generalized = true, .group = 1, .mode = 0, .duration = 0.75f, .smooth = 0.0025077160494 },
        { .group = 2, .mode = 2, .duration = 0, .smooth = 1 },
        { .generalized = true, .group = 0, .mode = 4, .duration = 0, .smooth = 1.25 },
    };
    foreach (sample : cases) {
        LayerFixture owner;
        create_onset_owner(&owner);
        defer destroy_layer_fixture(&owner);
        Transform[] pose = owner.animator.pose_storage.destination.pose;
        uint group = sample.group;
        uint mode = sample.mode;
        float duration = sample.duration;
        bool equal = mode == 4;
        float expected = mode == 0 ? 0 : equal ? 5 : 10;
        ClipId source = onset_clip(
            owner: &owner,
            first: expected,
            later: expected,
            smooth: false,
        );
        PlaybackView playback = owner.animator.playback();
        AnimationActionId source_id = owner.animator.play(&owner.assets, source)!!;
        anim::update(&owner.assets, &owner.scene, 0.125f);
        anim::update(&owner.assets, &owner.scene, 0.125f);
        ClipId target = onset_clip(
            owner: &owner,
            first: equal ? 5 : 0,
            later: equal ? 5 : 10,
            smooth: true,
        );
        AnimationTargetDesc[3] targets;
        targets[..] = anim::ANIMATION_TARGET_DEFAULT;
        uint count = group == 0 ? 1 : group == 1 ? 2 : 3;
        float speed = mode == 0 ? -1 : mode == 3 ? 0 : 1;
        bool playing = mode != 2;
        foreach (&action : targets[:count]) {
            action.clip = target;
            action.start_time = group ? 0 : 0.5f;
            action.speed = speed;
            action.playing = playing;
            action.loop = false;
            action.play = onset_play(sample.generalized);
        }
        uint[3] members = { 0, 1, 2 };
        float[2] positions = { 0, 1 };
        Vec2[3] points = { { 0, 0 }, { 1, 0 }, { 0, 1 } };
        BlendTriangle[1] triangles = { { .indices = { 0, 1, 2 } } };
        AnimationTransitionSpaceDesc[1] spaces = { {
            .phase = 0.5f,
            .space = {
                .actions = members[:count],
                .positions = group == 1 ? positions[..] : (float[]) {},
                .parameter = group == 1 ? 0.25f : 0,
                .weight = 1,
                .speed = speed,
                .playing = playing,
                .kind = group == 1 ? AnimationSpaceKind.ONE_DIMENSIONAL
                  : AnimationSpaceKind.TWO_DIMENSIONAL,
                .points = group == 2 ? points[..] : (Vec2[]) {},
                .triangles = group == 2 ? triangles[..] : (BlendTriangle[]) {},
                .parameter_2d = group == 2 ? (Vec2){ 0.25f, 0.25f } : (Vec2){},
            },
        } };
        AnimationTransitionDesc desc = {
            .duration = duration,
            .actions = targets[:count],
            .spaces = group ? spaces[..] : (AnimationTransitionSpaceDesc[]) {},
        };
        AnimationTransitionResult installed = owner.animator.inertialize(&owner.assets, desc)!!;
        playback = owner.animator.playback();
        assert(installed.count == count && installed.space_count == (group ? 1 : 0));
        assert(!playback.actions.is_live(source_id));
        foreach (index, id : installed.actions[:installed.count]) {
            assert(playback.actions.is_live(id) && c3d::same_id(id, playback.order[index]));
            assert(c3d::same_id(playback.actions.get(id).clip, targets[index].clip));
            if (id.index == source_id.index) assert(id.generation != source_id.generation);
        }
        if (group == 1) {
            AnimationTransitionGroup installed_group = installed.spaces[0];
            assert(installed_group.kind == AnimationSpaceKind.ONE_DIMENSIONAL);
            assert(installed_group.one_dimensional && installed_group.one_dimensional.phase == 0.5);
            foreach (index, member : installed_group.one_dimensional.actions[:count]) {
                assert(c3d::same_id(member, installed.actions[members[index]]));
            }
        } else if (group == 2) {
            AnimationTransitionGroup installed_group = installed.spaces[0];
            assert(installed_group.kind == AnimationSpaceKind.TWO_DIMENSIONAL);
            assert(installed_group.two_dimensional && installed_group.two_dimensional.phase == 0.5);
            foreach (index, member : installed_group.two_dimensional.actions[:count]) {
                assert(c3d::same_id(member, installed.actions[members[index]]));
            }
        }
        double scale_offset = sample.generalized ? math::ln(2.0 / 3) : -0.5;
        double scale_rate = playing ? sample.generalized ? -(double)speed / 1.5 : -(double)speed : 0;
        InertialRow* row = inertial_owner_row(&owner);
        foreach (axis : (uint[3]){ 0, 1, 2 }) {
            assert(math::abs(row.offset[0].scale[axis] - scale_offset) < 1e-12);
            assert(math::abs(row.offset_velocity[0].scale[axis] - scale_rate) < 1e-12);
        }
        assert(pose[0].scale == (duration == 0
          ? (Vec3){ 1.5f, 1.5f, 1.5f } : (Vec3){ 1, 1, 1 }));
        assert(pose[1].position.x == expected);
        assert(pose[2].position.y == (duration == 0 ? 1 : 0));
        assert(row.control.onset_pending);
        foreach (id : playback.order[:count]) {
            Action* action = playback.actions.get(id);
            assert(action.time == 0.5f && action.published_time == 0.5f);
        }
        for (uint frame = 0; frame < 3; frame++) {
            anim::update(&owner.assets, &owner.scene, 0);
            assert(pose[1].position.x == expected);
            assert(pose[2].position.y == (duration == 0 ? 1 : 0));
            assert(row.control.onset_pending);
            assert(row.control.elapsed == 0);
            assert(owner.animator.event_count == 0);
            onset_assert_zero_motion(&owner);
            foreach (id : playback.order[:count]) {
                Action* action = playback.actions.get(id);
                assert(action.time == 0.5f && action.clock_delta == 0);
            }
            assert(owner.assets.clip(target).data.events[0].time == 0.5f);
        }
        anim::update(&owner.assets, &owner.scene, 0.125f);
        onset_assert_zero_motion(&owner);
        assert(!row.control.onset_pending);
        assert(pose[1].position.x == expected);
        double travel = playing ? (double)speed * 0.125 : 0;
        assert(math::abs((double)pose[2].position.y - sample.smooth) < ONSET_TEST_EPSILON);
        foreach (id : playback.order[:count]) {
            assert(playback.actions.get(id).time == (float)(0.5 + travel));
        }
        assert(owner.assets.clip(target).data.events[0].time == 0.5f);
    }
}

fn void test_animation_inertial_onset_direction_reverse_completion_and_cancel_keep_step_sides() @test {
    {
        LayerFixture owner;
        create_onset_owner(&owner);
        defer destroy_layer_fixture(&owner);
        Transform[] pose = owner.animator.pose_storage.destination.pose;
        InertialRow* row = inertial_owner_row(&owner);
        AnimationTargetDesc[1] targets = { onset_step_target(&owner, -1, false) };
        owner.animator.inertialize(&owner.assets, { .duration = 0.75f, .actions = targets[..] })!!;
        anim::update(&owner.assets, &owner.scene, 0);
        assert(pose[1].position.x == 0);
        targets[0].speed = 1;
        owner.animator.inertialize(&owner.assets, { .duration = 0.75f, .actions = targets[..] })!!;
        anim::update(&owner.assets, &owner.scene, 0);
        assert(pose[1].position.x == 0);
        anim::update(&owner.assets, &owner.scene, 0.125f);
        onset_assert_zero_motion(&owner);
        assert(math::abs((double)pose[1].position.x - 0.3549382716049) < ONSET_TEST_EPSILON);
        assert(row.control.active);
    }

    {
        LayerFixture owner;
        create_onset_owner(&owner);
        defer destroy_layer_fixture(&owner);
        Transform[] pose = owner.animator.pose_storage.destination.pose;
        InertialRow* row = inertial_owner_row(&owner);
        AnimationTargetDesc[1] targets = { onset_step_target(&owner, -1, true) };
        owner.animator.inertialize(&owner.assets, { .duration = 0.5f, .actions = targets[..] })!!;
        anim::update(&owner.assets, &owner.scene, 0);
        anim::update(&owner.assets, &owner.scene, 0.75f);
        onset_assert_zero_motion(&owner);
        assert(pose[1].position.x == 0);
        assert(!row.control.active && !row.control.onset_pending);
        PlaybackView playback = owner.animator.playback();
        assert(playback.actions.get(playback.order[0]).time == 0);
        assert(!playback.actions.get(playback.order[0]).playing);
        anim::update(&owner.assets, &owner.scene, 0);
        onset_assert_zero_motion(&owner);
        assert(pose[1].position.x == 0);
    }

    foreach (float speed : { -1.0f, 1.0f }) {
        LayerFixture owner;
        create_onset_owner(&owner);
        defer destroy_layer_fixture(&owner);
        Transform[] pose = owner.animator.pose_storage.destination.pose;
        AnimationTargetDesc[1] targets = { onset_step_target(&owner, speed, speed > 0) };
        AnimationTransitionResult installed = owner.animator.inertialize(
            assets: &owner.assets,
            desc: { .duration = 0.75f, .actions = targets[..] },
        )!!;
        owner.animator.cancel_inertial_transition();
        InertialRow* row = inertial_owner_row(&owner);
        assert(!row.control.active && row.control.onset_pending);
        assert(row.control.duration == 0 && row.control.elapsed == 0);
        Action* action = owner.animator.action(installed.actions[0]);
        float expected = speed < 0 ? 0 : 10;
        for (uint frame = 0; frame < 3; frame++) {
            anim::update(&owner.assets, &owner.scene, 0);
            assert(pose[1].position.x == expected);
            assert(row.control.onset_pending);
            assert(action.time == 0.5f && action.clock_delta == 0);
            assert(owner.animator.event_count == 0);
            onset_assert_zero_motion(&owner);
        }
        anim::update(&owner.assets, &owner.scene, 0.125f);
        assert(pose[1].position.x == expected);
        assert(!row.control.onset_pending && !row.control.active);
        assert(action.time == 0.5f + speed * 0.125f);
        assert(owner.animator.event_count == 0);
        onset_assert_zero_motion(&owner);
    }
}

fn void test_animation_inertial_onset_immediate_request_captures_authored_pose_without_source_history() @test {
    foreach (generalized : (bool[2]){ false, true }) {
        LayerFixture owner;
        create_onset_owner(&owner, false, { 7, 0, 0 });
        defer destroy_layer_fixture(&owner);
        Transform[] pose = owner.animator.pose_storage.destination.pose;
        InertialRow* row = inertial_owner_row(&owner);
        assert(!row.control.history_valid);
        assert(pose[1].position == (Vec3){ 7, 0, 0 });
        assert(pose[1].scale == (Vec3){ 1, 1, 1 });
        assert(pose[1].rotation.v == (Vec4){ 0, 0, 0, 1 });
        AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
        targets[0].clip = onset_clip(
            owner: &owner,
            first: 0,
            later: 10,
            smooth: false,
        );
        targets[0].start_time = 0.5f;
        targets[0].play = onset_play(generalized);
        owner.animator.inertialize(&owner.assets, { .duration = 0.5f, .actions = targets[..] })!!;
        assert(pose[1].position == (Vec3){ 7, 0, 0 });
        assert(!row.control.history_valid);
        assert(row.previous_pose[1].position == (Vec3){ 7, 0, 0 });
        assert(row.offset[1].translation == (double[<3>]){ -3, 0, 0 });
        assert(row.offset_velocity[1].translation == (double[<3>]){});
        foreach (velocity : row.velocity) {
            assert(velocity.translation == (double[<3>]){});
            assert(velocity.angular == (double[<3>]){});
            assert(velocity.scale == (double[<3>]){});
        }
        assert(row.root.source_translation_rate == (double[<3>]){} && row.root.source_twist_rate == 0);
        anim::update(&owner.assets, &owner.scene, 0);
        assert(pose[1].position == (Vec3){ 7, 0, 0 });
        assert(!row.control.history_valid);
        onset_assert_zero_motion(&owner);
    }
}

fn ClipId history_translation_clip(
    LayerFixture* fixture,
    uint node = 3,
    Vec3 first = { 2, 0, 3 },
    Vec3 last = { 4, 0, 3 },
) @local {
    return inertial_owner_translation(
        owner: fixture,
        start: first,
        end: last,
        node: node,
    );
}

fn ModelTemplate copy_history_model(ModelTemplate* source) @local {
    assert(!source.lod_groups.len && !source.lights.len && !source.cameras.len);
    ModelTemplate copy = {
        .nodes = alloc::new_array(mem, NodeTemplate, source.nodes.len),
        .meshes = alloc::new_array(mem, ModelMesh, source.meshes.len),
        .skins = alloc::new_array(mem, ModelSkin, source.skins.len),
        .clips = alloc::new_array(mem, ClipId, source.clips.len),
    };
    copy.nodes[..] = source.nodes[..];
    copy.meshes[..] = source.meshes[..];
    copy.skins[..] = source.skins[..];
    copy.clips[..] = source.clips[..];
    foreach (&node : copy.nodes) node.name = node.name.copy(mem);
    foreach (index, &mesh : copy.meshes) {
        float[] weights = source.meshes[index].default_morph_weights;
        mesh.default_morph_weights = alloc::new_array(mem, float, weights.len);
        mesh.default_morph_weights[..] = weights[..];
    }
    foreach (index, &skin : copy.skins) {
        uint[] joints = source.skins[index].joint_nodes;
        skin.joint_nodes = alloc::new_array(mem, uint, joints.len);
        skin.joint_nodes[..] = joints[..];
    }
    return copy;
}

fn void test_animation_inertial_history_invalidates_on_revisions_and_removed_nodes() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId clip = history_translation_clip(&fixture);
    fixture.animator.play(&fixture.assets, clip)!!;
    InertialRow* row = inertial_owner_row(&fixture);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    assert(row.velocity[3].translation.x == 2);

    ClipEvent[1] events = { { .time = 0.5f, .id = 123 } };
    fixture.assets.set_clip_events(clip, events[..])!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    assert(row.velocity[3].translation.x == 0);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    assert(row.velocity[3].translation.x == 2);

    ModelTemplate replacement = copy_history_model(&fixture.assets.model(fixture.model).data);
    fixture.assets.replace_model_owned(fixture.model, &replacement)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    assert(row.velocity[3].translation.x == 0);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    assert(row.velocity[3].translation.x == 2);

    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    fixture.scene.remove(instance.present_node(1));
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    assert(row.velocity[3].translation.x == 0);
}

fn void test_animation_inertial_crowd_reset_keeps_the_other_slot_history() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    Transform[2] placements = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    CrowdPlaybackState* state = anim::create_crowd_playback(
        allocator: mem,
        template: &fixture.assets.model(fixture.model).data,
        placements: placements[..],
        actions_per_instance: 4,
        event_capacity: 0,
        inertia_enabled: true,
    )!!;
    defer anim::destroy_crowd_playback(state);
    state.model = fixture.model;
    state.count = 2;
    ClipId first_clip = history_translation_clip(&fixture);
    ClipId second_clip = history_translation_clip(
        fixture: &fixture,
        node: 3,
        first: { 8, 0, 3 },
        last: { 12, 0, 3 },
    );
    ClipId target = layer_translation(&fixture, { 6, 0, 3 });
    CrowdPlayer first = state.player(state.instance_id(0)!!)!!;
    CrowdPlayer second = state.player(state.instance_id(1)!!)!!;
    first.play(&fixture.assets, first_clip)!!;
    second.play(&fixture.assets, second_clip)!!;
    state.update(&fixture.assets, 0.125f);
    state.update(&fixture.assets, 0.125f);

    AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
    targets[0].clip = target;
    first.inertialize(&fixture.assets, { .duration = 0.5f, .actions = targets[..] })!!;
    second.inertialize(&fixture.assets, { .duration = 0.75f, .actions = targets[..] })!!;
    InertialRow* first_row = &state.inertial_storage.rows[0];
    InertialRow* second_row = &state.inertial_storage.rows[1];
    assert(first_row.offset_velocity[3].translation.x == 2 && second_row.offset_velocity[3].translation.x == 4);

    anim::reset_crowd_playback_slot(state, 0);
    assert(!first_row.control.history_valid && !first_row.control.active);
    assert(first_row.offset_velocity[3].translation.x == 0);
    assert(second_row.control.history_valid && second_row.control.active);
    assert(second_row.velocity[3].translation.x == 4 && second_row.offset_velocity[3].translation.x == 4);
}

fn void test_animation_inertial_history_paused_seek_invalidates_once_and_later_request_captures_velocity() @test {
    foreach (zero_speed : (bool[2]){ false, true }) {
        LayerFixture fixture;
        create_inertial_owner(&fixture);
        defer destroy_layer_fixture(&fixture);
        ClipId paused_clip = layer_translation(&fixture, { 6, 0, 3 });
        ClipId moving_clip = history_translation_clip(&fixture);
        ClipId target_clip = layer_translation(&fixture, { 0, 0, 3 });
        AnimationActionId paused = fixture.animator.play(&fixture.assets, paused_clip)!!;
        fixture.animator.play(&fixture.assets, moving_clip)!!;
        PlaybackView playback = fixture.animator.playback();
        Action* action = playback.actions.get(paused);
        action.playing = zero_speed;
        action.speed = zero_speed ? 0 : 1;
        for (uint frame = 0; frame < 2; frame++) anim::update(&fixture.assets, &fixture.scene, 0.125f);
        assert(playback.inertial.velocity[3].translation.x == 1);
        action.time = 0.75f;
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        assert(action.time == 0.75f);
        assert(playback.inertial.velocity[3].translation.x == 0);
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        assert(action.time == 0.75f);
        assert(playback.inertial.control.history_valid && playback.inertial.velocity[3].translation.x == 1);
        AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
        targets[0].clip = target_clip;
        fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = targets[..] })!!;
        assert(playback.inertial.control.active && playback.inertial.offset_velocity[3].translation.x == 1);
    }
}

fn ClipId request_translation_clip(
    LayerFixture* fixture,
    Vec3 start,
    Vec3 end,
    ClipEvent[] events = {},
) @local {
    ClipId clip = inertial_owner_translation(fixture, start, end);
    fixture.assets.set_clip_events(clip, events)!!;
    return clip;
}

fn RequestBlockSnapshot[] request_snapshot_blocks(TrackingAllocator* tracker) @local {
    Allocation[] allocations = tracker.allocations_tlist(tmem);
    RequestBlockSnapshot[] snapshot = alloc::new_array(tmem, RequestBlockSnapshot, allocations.len);
    foreach (index, allocation : allocations) {
        snapshot[index].pointer = allocation.ptr;
        snapshot[index].bytes = alloc::new_array(tmem, char, allocation.size);
        mem::copy(snapshot[index].bytes.ptr, allocation.ptr, (usz)allocation.size);
    }
    return snapshot;
}

fn void request_assert_blocks_unchanged(TrackingAllocator* tracker, RequestBlockSnapshot[] snapshot) @local {
    Allocation[] current = tracker.allocations_tlist(tmem);
    assert(current.len == snapshot.len);
    foreach (saved : snapshot) {
        bool present;
        foreach (allocation : current) {
            if (allocation.ptr != saved.pointer) continue;
            assert(allocation.size == saved.bytes.len);
            present = true;
        }
        assert(present);
        assert(mem::equals((char*)saved.pointer, saved.bytes.ptr, (usz)saved.bytes.len));
    }
}

fn void request_fill_sources(LayerFixture* fixture, ClipId clip) @local {
    PlaybackView playback = fixture.animator.playback();
    for (uint index = 0; index < playback.actions.items.len; index++) fixture.animator.play(&fixture.assets, clip)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert(*playback.action_count == playback.actions.items.len && playback.actions.free_count == 0);
}

fn void create_request_targets(LayerFixture* fixture, RequestTargets* targets) @local {
    ClipId translation = request_translation_clip(
        fixture: fixture,
        start: { 8, 0, 0 },
        end: { 8, 0, 0 },
    );
    float[2] times = { 0, 1 };
    float[6] scales = { 2, 2, 2, 2, 2, 2 };
    ClipId scale = inertial_owner_clip(
        owner: fixture,
        path: TargetPath.SCALE,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: scales[..],
        node: 3,
    );
    String[4] names;
    float[4] weights = { 1, 1, 1, 1 };
    foreach (index, node : fixture.assets.model(fixture.model).data.nodes) names[index] = node.name;
    targets.weighted = anim::create_weighted_joint_mask(
        allocator: mem,
        assets: &fixture.assets,
        model: fixture.model,
        names: names[..],
        weights: weights[..],
    )!!;
    targets.membership[..] = true;
    targets.mask = { .nodes = targets.membership[..] };
    foreach (&target : targets.actions) {
        *target = anim::ANIMATION_TARGET_DEFAULT;
        target.clip = translation;
    }
    targets.actions[0].play.mask = &targets.mask;
    targets.actions[1].play.mask = &targets.mask;
    targets.actions[2].play = { .additive = true, .weighted_mask = &targets.weighted };
    targets.actions[3].clip = scale;
    targets.actions[3].play = {
        .additive = true,
        .additive_scale = AdditiveScaleMode.MULTIPLICATIVE,
        .weighted_mask = &targets.weighted,
    };
    targets.members = { 0, 1 };
    targets.positions = { 0, 1 };
    targets.spaces[0] = {
        .space = {
            .actions = targets.members[..],
            .positions = targets.positions[..],
            .parameter = 0.25f,
            .weight = 1,
            .speed = 0.5f,
            .playing = true,
        },
    };
    targets.description = { .duration = 0.5f, .actions = targets.actions[..], .spaces = targets.spaces[..] };
}

fn uint measure_request_allocations() @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    uint attempts;
    {
        MotionTestAllocator allocator = { .backing = &tracker };
        LayerFixture fixture;
        create_inertial_owner(&fixture, &allocator);
        defer destroy_layer_fixture(&fixture);
        ClipId source = request_translation_clip(&fixture, { 1, 0, 0 }, { 1, 0, 0 });
        request_fill_sources(&fixture, source);
        RequestTargets targets;
        create_request_targets(&fixture, &targets);
        defer anim::destroy_weighted_joint_mask(&targets.weighted);
        allocator.attempts = 0;
        fixture.animator.inertialize(&fixture.assets, targets.description)!!;
        attempts = allocator.attempts;
        assert(attempts > 0);
    }
    assert(!tracker.has_leaks());
    return attempts;
}

fn PlayDesc request_generalized_desc() @local {
    return {
        .root_motion = RootMotion.EXTRACT,
        .extraction = { .generalized = true, .translation_axes = { true, true, true }, .up = { 0, 1, 0 } },
    };
}

fn void? request_try_addition(
    LayerFixture* fixture,
    ClipId[] clips,
    PlayDesc desc,
    RequestAdditionKind kind,
) @local {
    switch (kind) {
        case SINGLE:
            fixture.animator.play(&fixture.assets, clips[0], desc)!;
        case SPACE_1D:
            float[3] positions = { 0, 1, 2 };
            fixture.animator.add_blend_space(
                assets: &fixture.assets,
                clips: clips,
                positions: positions[:clips.len],
                desc: desc,
            )!;
        case SPACE_2D:
            Vec2[3] coordinates = { { 0, 0 }, { 1, 0 }, { 0, 1 } };
            BlendTriangle[1] triangles = { { .indices = { 0, 1, 2 } } };
            fixture.animator.add_blend_space_2d(
                assets: &fixture.assets,
                clips: clips,
                coordinates: coordinates[..],
                triangles: triangles[..],
                desc: desc,
            )!;
    }
}

fn ClipId request_cubic_scale_clip(LayerFixture* fixture) @local {
    float[2] times = { 0, 1 };
    float[18] values = { 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0 };
    return inertial_owner_clip(
        owner: fixture,
        path: TargetPath.SCALE,
        interpolation: Interpolation.CUBIC_SPLINE,
        times: times[..],
        values: values[..],
        node: 2,
    );
}

fn void test_animation_inertial_request_full_capacity_copies_targets_and_hands_off_events() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipEvent[1] source_events = { { .time = 0.125f, .id = 111 } };
    ClipEvent[1] target_events = { { .time = 0.375f, .id = 222 } };
    ClipId source = request_translation_clip(
        fixture: &fixture,
        start: { 1, 0, 0 },
        end: { 1, 0, 0 },
        events: source_events[..],
    );
    ClipId destination = request_translation_clip(
        fixture: &fixture,
        start: { 8, 0, 0 },
        end: { 8, 0, 0 },
        events: target_events[..],
    );
    request_fill_sources(&fixture, source);
    PlaybackView playback = fixture.animator.playback();
    uint count = *playback.action_count;
    AnimationActionId[16] previous;
    previous[:count] = playback.order[:count];
    assert(fixture.animator.event_count == count);
    assert(fixture.animator.events[0].id == 111);
    AnimationTargetDesc[16] targets;
    bool[4] membership = { true, true, true, true };
    JointMask mask = { .nodes = membership[..] };
    foreach (&target : targets[:count]) {
        *target = anim::ANIMATION_TARGET_DEFAULT;
        target.clip = destination;
        target.play.mask = &mask;
    }
    fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = targets[:count] })!!;
    playback = fixture.animator.playback();
    assert(*playback.action_count == count && playback.actions.free_count == 0);
    foreach (id : previous[:count]) assert(!playback.actions.is_live(id));
    assert(fixture.animator.event_count == 0 && inertial_owner_pose(&fixture).position == (Vec3){ 1, 0, 0 });
    targets[..] = (AnimationTargetDesc){};
    membership[..] = false;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert(inertial_owner_pose(&fixture).position == (Vec3){ 4.5f, 0, 0 });
    assert(fixture.animator.event_count == 0);
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert(inertial_owner_pose(&fixture).position == (Vec3){ 8, 0, 0 });
    assert(fixture.animator.event_count == count);
    for (uint index = 0; index < count; index++) {
        FiredEvent event = fixture.animator.events[index];
        assert(event.id == 222 && c3d::same_id(event.clip, destination));
        assert(playback.actions.is_live(event.action));
    }
}

fn void test_animation_inertial_request_every_real_temporary_failure_preserves_all_owner_blocks() @test {
    uint attempts = measure_request_allocations();
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        MotionTestAllocator allocator = { .backing = &tracker };
        LayerFixture fixture;
        create_inertial_owner(&fixture, &allocator);
        defer destroy_layer_fixture(&fixture);
        ClipEvent[1] events = { { .time = 0.125f, .id = 111 } };
        ClipId source = request_translation_clip(
            fixture: &fixture,
            start: { 1, 0, 0 },
            end: { 1, 0, 0 },
            events: events[..],
        );
        request_fill_sources(&fixture, source);
        RequestTargets targets;
        create_request_targets(&fixture, &targets);
        defer anim::destroy_weighted_joint_mask(&targets.weighted);
        for (uint failure = 1; failure <= attempts; failure++) @pool() {
            RequestBlockSnapshot[] snapshot = request_snapshot_blocks(&tracker);
            sz retained = tracker.allocated();
            sz outstanding = allocator.outstanding;
            allocator.attempts = 0;
            allocator.failure = failure;
            bool caught;
            if (catch excuse = fixture.animator.inertialize(&fixture.assets, targets.description)) {
                assert(excuse == c3d::CAPACITY_EXCEEDED);
                caught = true;
            }
            assert(caught && allocator.attempts == failure);
            assert(allocator.outstanding == outstanding && tracker.allocated() == retained);
            request_assert_blocks_unchanged(&tracker, snapshot);
            assert(fixture.animator.event_count == anim::MAX_ACTIONS);
        };
        allocator.failure = 0;
        fixture.animator.inertialize(&fixture.assets, targets.description)!!;
        targets.members[..] = uint::max;
        targets.positions[..] = -100;
        targets.membership[..] = false;
        targets.weighted.nodes[..] = 0;
        targets.actions[..] = (AnimationTargetDesc){};
        PlaybackView playback = fixture.animator.playback();
        assert(playback.blend_spaces[0].positions[0] == 0 && playback.blend_spaces[0].positions[1] == 1);
        assert(playback.blend_spaces[0].parameter == 0.25f && *playback.action_count == 4);
        anim::update(&fixture.assets, &fixture.scene, 0.5f);
        assert(inertial_owner_pose(&fixture).position == (Vec3){ 8, 0, 0 });
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_inertial_request_onset_zero_step_interruption_and_cancel_have_literal_output() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId source = request_translation_clip(
        fixture: &fixture,
        start: { 0, 0, 0 },
        end: { 1, 0, 0 },
    );
    ClipId target = request_translation_clip(
        fixture: &fixture,
        start: { 10, 0, 0 },
        end: { 10, 0, 0 },
    );
    ClipId interrupted = request_translation_clip(
        fixture: &fixture,
        start: { -4, 0, 0 },
        end: { -4, 0, 0 },
    );
    fixture.animator.play(&fixture.assets, source)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    assert(inertial_owner_pose(&fixture).position.x == 0.25f);
    assert(inertial_owner_row(&fixture).velocity[3].translation.x == 1);
    AnimationTargetDesc[1] description = { anim::ANIMATION_TARGET_DEFAULT };
    description[0].clip = target;
    fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = description[..] })!!;
    assert(inertial_owner_pose(&fixture).position.x == 0.25f);
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert(inertial_owner_pose(&fixture).position.x == 0.25f && inertial_owner_row(&fixture).control.elapsed == 0);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    assert(inertial_owner_pose(&fixture).position.x == 1.3515625f);
    assert(inertial_owner_row(&fixture).velocity[3].translation.x == 8.8125);
    description[0].clip = interrupted;
    fixture.animator.inertialize(&fixture.assets, { .duration = 0.25f, .actions = description[..] })!!;
    assert(inertial_owner_pose(&fixture).position.x == 1.3515625f);
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert(inertial_owner_pose(&fixture).position.x == 1.3515625f && inertial_owner_row(&fixture).control.elapsed == 0);
    PlaybackView playback = fixture.animator.playback();
    AnimationActionId installed = playback.order[0];
    fixture.animator.cancel_inertial_transition();
    assert(!inertial_owner_row(&fixture).control.active && playback.actions.is_live(installed));
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert(inertial_owner_pose(&fixture).position.x == -4 && *playback.action_count == 1);
}

fn void test_animation_inertial_request_survives_unrelated_play_and_stop() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId source = request_translation_clip(&fixture, { 0, 0, 0 }, { 1, 0, 0 });
    ClipId target = request_translation_clip(&fixture, { 10, 0, 0 }, { 10, 0, 0 });
    ClipId overlay = layer_translation(&fixture, { 0, 1, 0 }, 1);
    fixture.animator.play(&fixture.assets, source)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    AnimationTargetDesc[1] description = { anim::ANIMATION_TARGET_DEFAULT };
    description[0].clip = target;
    fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = description[..] })!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);

    AnimationActionId played = fixture.animator.play(&fixture.assets, overlay, { .layer = 1 })!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    AnimationInertialStatus status = fixture.animator.inertial_status();
    assert(status.active && status.elapsed == 0.25);

    fixture.animator.stop(played)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    status = fixture.animator.inertial_status();
    assert(status.active && status.elapsed == 0.375);
}

fn void test_animation_inertial_instant_play_and_stop_invalidate_history() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId idle = request_translation_clip(&fixture, { 0, 0, 0 }, { 0, 0, 0 });
    ClipId lifted = request_translation_clip(&fixture, { 0, 0, 0.5f }, { 0, 0, 0.5f });
    fixture.animator.play(&fixture.assets, idle)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);

    AnimationActionId lift = fixture.animator.play(&fixture.assets, lifted, { .layer = 1 })!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    assert(inertial_owner_pose(&fixture).position.z == 0.5f);
    assert(inertial_owner_row(&fixture).velocity[3].translation.z == 0);

    fixture.animator.stop(lift)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    assert(inertial_owner_pose(&fixture).position.z == 0);
    assert(inertial_owner_row(&fixture).velocity[3].translation.z == 0);
}

fn void test_animation_inertial_owner_accepts_degenerate_rotations_without_faulting() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId source = request_translation_clip(&fixture, { 0, 0, 0 }, { 1, 0, 0 });
    ClipId target = request_translation_clip(&fixture, { 10, 0, 0 }, { 10, 0, 0 });
    float[2] times = { 0, 1 };
    float[8] rotations;
    ClipId degenerate = inertial_owner_clip(
        owner: &fixture,
        path: TargetPath.ROTATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: rotations[..],
        node: 3,
    );
    fixture.animator.play(&fixture.assets, source)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    AnimationTargetDesc[1] description = { anim::ANIMATION_TARGET_DEFAULT };
    description[0].clip = target;
    fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = description[..] })!!;

    AnimationTargetDesc[2] degenerate_targets = { description[0], description[0] };
    degenerate_targets[1].clip = degenerate;
    degenerate_targets[1].play.layer = 1;
    fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = degenerate_targets[..] })!!;
    assert(inertial_owner_row(&fixture).offset[3].angular == (double[<3>]){});

    fixture.animator.play(&fixture.assets, degenerate, { .layer = 1 })!!;
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    assert(fixture.animator.inertial_status().active);
    assert(inertial_owner_row(&fixture).velocity[3].angular == (double[<3>]){});
}

fn void test_animation_inertial_scale_residual_survives_a_chain_becoming_consumed() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    float[2] times = { 0, 1 };
    float[6] doubled = { 2, 2, 2, 2, 2, 2 };
    float[6] unit = { 1, 1, 1, 1, 1, 1 };
    ClipId large = inertial_owner_clip(
        owner: &fixture,
        path: TargetPath.SCALE,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: doubled[..],
        node: 2,
    );
    ClipId small = inertial_owner_clip(
        owner: &fixture,
        path: TargetPath.SCALE,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: unit[..],
        node: 2,
    );
    ClipId walk = inertial_owner_translation(
        owner: &fixture,
        start: { 0, 0, 0 },
        end: { 0, 0, 2 },
        node: 2,
    );
    fixture.animator.play(&fixture.assets, large)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.0625f);
    AnimationTargetDesc[1] description = { anim::ANIMATION_TARGET_DEFAULT };
    description[0].clip = small;
    fixture.animator.inertialize(&fixture.assets, { .duration = 1, .actions = description[..] })!!;
    anim::update(&fixture.assets, &fixture.scene, 0.0625f);

    PlayDesc fade = request_generalized_desc();
    fade.fade_in = 1;
    fixture.animator.play(&fixture.assets, walk, fade)!!;
    float previous = inertial_owner_pose(&fixture, 2).scale.x;
    for (uint frame = 0; frame < 8; frame++) {
        anim::update(&fixture.assets, &fixture.scene, 0.0625f);
        float scale = inertial_owner_pose(&fixture, 2).scale.x;
        assert(scale < previous && previous - scale < 0.2f);
        previous = scale;
    }
}

fn void test_animation_inertial_request_rotation_uses_shortest_twenty_degree_transition() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    float[2] times = { 0, 1 };
    Quat positive = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)(math::PI * 170 / 180));
    Quat negative = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)(-math::PI * 170 / 180));
    float[8] source_values = { positive.v.x, positive.v.y, positive.v.z, positive.v.w,
        positive.v.x, positive.v.y, positive.v.z, positive.v.w };
    float[8] target_values = { negative.v.x, negative.v.y, negative.v.z, negative.v.w,
        negative.v.x, negative.v.y, negative.v.z, negative.v.w };
    ClipId source = inertial_owner_clip(
        owner: &fixture,
        path: TargetPath.ROTATION,
        interpolation: Interpolation.STEP,
        times: times[..],
        values: source_values[..],
        node: 3,
    );
    ClipId target = inertial_owner_clip(
        owner: &fixture,
        path: TargetPath.ROTATION,
        interpolation: Interpolation.STEP,
        times: times[..],
        values: target_values[..],
        node: 3,
    );
    fixture.animator.play(&fixture.assets, source)!!;
    anim::update(&fixture.assets, &fixture.scene, 0);
    AnimationTargetDesc[1] description = { anim::ANIMATION_TARGET_DEFAULT };
    description[0].clip = target;
    fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = description[..] })!!;
    Quat onset = inertial_owner_pose(&fixture).rotation;
    assert(math::abs(onset.v.dot(positive.v)) > 1 - 1e-6f);
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    Quat middle = inertial_owner_pose(&fixture).rotation;
    assert(math::abs(middle.v.y) > 1 - 1e-6f && math::abs(middle.v.w) < 1e-6f);
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert(math::abs(inertial_owner_pose(&fixture).rotation.v.dot(negative.v)) > 1 - 1e-6f);
}

fn void test_animation_inertial_request_consumed_scale_follows_geometric_midpoint() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    float[2] times = { 0, 1 };
    float[6] source_values = { 4, 4, 4, 4, 4, 4 };
    float[6] target_values = { 1, 1, 1, 1, 1, 1 };
    ClipId source = inertial_owner_clip(
        owner: &fixture,
        path: TargetPath.SCALE,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: source_values[..],
        node: 2,
    );
    ClipId target = inertial_owner_clip(
        owner: &fixture,
        path: TargetPath.SCALE,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: target_values[..],
        node: 2,
    );
    PlayDesc generalized = request_generalized_desc();
    fixture.animator.play(&fixture.assets, source, generalized)!!;
    anim::update(&fixture.assets, &fixture.scene, 0);
    AnimationTargetDesc[1] description = { anim::ANIMATION_TARGET_DEFAULT };
    description[0].clip = target;
    description[0].play = generalized;
    fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = description[..] })!!;
    assert(inertial_owner_pose(&fixture, 2).scale == (Vec3){ 4, 4, 4 });
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert((inertial_owner_pose(&fixture, 2).scale - (Vec3){ 2, 2, 2 }).length() < 1e-5f);
    assert(inertial_owner_pose(&fixture, 0).scale == (Vec3){ 1, 1, 1 });
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert(inertial_owner_pose(&fixture, 2).scale == (Vec3){ 1, 1, 1 });
}

fn void test_animation_inertial_request_consumed_scale_residual_clamps_to_float_range() @test {
    foreach (double sign : { -1.0, 1.0 }) {
        LayerFixture fixture;
        create_inertial_owner(&fixture);
        defer destroy_layer_fixture(&fixture);
        float scale = 0x1p-100f;
        float step = 0x1p-11f;
        float[2] source_times = { 0, step };
        float first = sign < 0 ? 0x1.8p-100f : 0x1p-101f;
        float[6] source_values = { first, first, first, scale, scale, scale };
        float[2] target_times = { 0, 1 };
        float[6] target_values = { scale, scale, scale, scale, scale, scale };
        ClipId source = inertial_owner_clip(
            owner: &fixture,
            path: TargetPath.SCALE,
            interpolation: Interpolation.LINEAR,
            times: source_times[..],
            values: source_values[..],
            node: 2,
        );
        ClipId target = inertial_owner_clip(
            owner: &fixture,
            path: TargetPath.SCALE,
            interpolation: Interpolation.LINEAR,
            times: target_times[..],
            values: target_values[..],
            node: 2,
        );
        ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
        instance.base_pose[2].scale = { scale, scale, scale };
        PlayDesc generalized = request_generalized_desc();
        AnimationActionId id = fixture.animator.play(&fixture.assets, source, generalized)!!;
        Action* action = fixture.animator.action(id);
        action.loop = false;
        action.playing = false;
        anim::update(&fixture.assets, &fixture.scene, step);
        action.playing = true;
        anim::update(&fixture.assets, &fixture.scene, step);
        assert(inertial_owner_row(&fixture).velocity[2].scale.x == sign * 0x1p-90);

        AnimationTargetDesc[1] description = { anim::ANIMATION_TARGET_DEFAULT };
        description[0].clip = target;
        description[0].play = generalized;
        instance.base_pose[2].scale = {};
        assert(@catch(fixture.animator.inertialize(
            assets: &fixture.assets,
            desc: { .duration = 1, .actions = description[..] },
        )) == c3d::INVALID_ARGUMENT);
        assert(c3d::same_id(fixture.animator.try_action(id)!!.clip, source));
        instance.base_pose[2].scale = { scale, scale, scale };

        fixture.animator.inertialize(&fixture.assets, { .duration = 1, .actions = description[..] })!!;
        anim::update(&fixture.assets, &fixture.scene, 0.25f);
        Vec3 actual = inertial_owner_pose(&fixture, 2).scale;
        assert(actual.x == (sign < 0 ? 0x1p-126f : float::max));
        assert(actual.x == actual.y && actual.y == actual.z);
    }
}

fn void test_animation_inertial_request_invalid_scale_precedes_cubic_unsupported_without_allocating() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        MotionTestAllocator allocator = { .backing = &tracker };
        LayerFixture fixture;
        create_inertial_owner(&fixture, &allocator);
        defer destroy_layer_fixture(&fixture);
        float[2] times = { 0, 1 };
        float[6] ordinary = { 1, 1, 1, 1, 1, 1 };
        ClipId source = inertial_owner_clip(
            owner: &fixture,
            path: TargetPath.SCALE,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: ordinary[..],
            node: 2,
        );
        ClipId cubic = request_cubic_scale_clip(&fixture);
        float[6] invalid_values = { 1, 2, 1, 1, 2, 1 };
        ClipId invalid = inertial_owner_clip(
            owner: &fixture,
            path: TargetPath.SCALE,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: invalid_values[..],
            node: 2,
        );
        PlayDesc generalized = request_generalized_desc();
        fixture.animator.play(&fixture.assets, source, generalized)!!;
        PlaybackView playback = fixture.animator.playback();
        assert(playback.root_node == 2);
        ModelTemplate* template = &fixture.assets.model(fixture.model).data;
        assert(template.nodes[0].parent == -1 && template.nodes[2].parent == -1);
        anim::update(&fixture.assets, &fixture.scene, 0.25f);
        AnimationTargetDesc[2] targets = { anim::ANIMATION_TARGET_DEFAULT, anim::ANIMATION_TARGET_DEFAULT };
        targets[0].clip = cubic;
        targets[1].clip = invalid;
        targets[0].play = targets[1].play = generalized;
        for (uint count = 2; count > 0; count--) @pool() {
            RequestBlockSnapshot[] snapshot = request_snapshot_blocks(&tracker);
            uint calls = allocator.attempts;
            fault expected = count == 2 ? c3d::INVALID_ARGUMENT : c3d::UNSUPPORTED;
            assert(@catch(fixture.animator.inertialize(
                assets: &fixture.assets,
                desc: { .duration = 0.5f, .actions = targets[:count] },
            )) == expected);
            assert(allocator.attempts == calls);
            request_assert_blocks_unchanged(&tracker, snapshot);
        };
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_generalized_play_and_groups_reject_atomically_before_acquiring_storage() @test {
    foreach (kind : RequestAdditionKind::values) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            MotionTestAllocator allocator = { .backing = &tracker };
            LayerFixture fixture;
            create_inertial_owner(&fixture, &allocator);
            defer destroy_layer_fixture(&fixture);
            ClipId source = request_translation_clip(&fixture, { 1, 0, 0 }, { 1, 0, 0 });
            PlayDesc desc = request_generalized_desc();
            fixture.animator.play(&fixture.assets, source, desc)!!;
            anim::update(&fixture.assets, &fixture.scene, 0.25f);

            float[2] times = { 0, 1 };
            float[6] scales = { 1, 2, 1, 1, 2, 1 };
            float[8] rotations;
            ClipId rejected;
            fault expected = c3d::INVALID_ARGUMENT;
            switch (kind) {
                case SINGLE:
                    rejected = inertial_owner_clip(
                        owner: &fixture,
                        path: TargetPath.SCALE,
                        interpolation: Interpolation.LINEAR,
                        times: times[..],
                        values: scales[..],
                        node: 2,
                    );
                case SPACE_1D:
                    rejected = inertial_owner_clip(
                        owner: &fixture,
                        path: TargetPath.ROTATION,
                        interpolation: Interpolation.LINEAR,
                        times: times[..],
                        values: rotations[..],
                        node: 2,
                    );
                case SPACE_2D:
                    rejected = request_cubic_scale_clip(&fixture);
                    expected = c3d::UNSUPPORTED;
            }
            ClipId[3] clips = { rejected, rejected, rejected };
            @pool() {
                RequestBlockSnapshot[] snapshot = request_snapshot_blocks(&tracker);
                uint attempts = allocator.attempts;
                assert(@catch(request_try_addition(
                    fixture: &fixture,
                    clips: clips[..],
                    desc: desc,
                    kind: kind,
                )) == expected);
                assert(allocator.attempts == attempts);
                request_assert_blocks_unchanged(&tracker, snapshot);
            };
        }
        assert(!tracker.has_leaks());
    }
}

fn void test_animation_generalized_and_planar_extract_play_and_groups_reject_both_orders_atomically() @test {
    foreach (generalized_source : (bool[2]){ false, true }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            MotionTestAllocator allocator = { .backing = &tracker };
            LayerFixture fixture;
            create_inertial_owner(&fixture, &allocator);
            defer destroy_layer_fixture(&fixture);
            PlayDesc generalized = request_generalized_desc();
            PlayDesc planar = { .root_motion = RootMotion.EXTRACT };
            ClipId source = request_translation_clip(&fixture, { 1, 0, 0 }, { 1, 0, 0 });
            fixture.animator.play(&fixture.assets, source, generalized_source ? generalized : planar)!!;
            anim::update(&fixture.assets, &fixture.scene, 0.25f);
            ClipId incoming = generalized_source ? source : request_cubic_scale_clip(&fixture);
            ClipId[3] clips = { incoming, incoming, incoming };
            @pool() {
                RequestBlockSnapshot[] snapshot = request_snapshot_blocks(&tracker);
                uint attempts = allocator.attempts;
                assert(@catch(request_try_addition(
                    fixture: &fixture,
                    clips: clips[..],
                    desc: generalized_source ? planar : generalized,
                    kind: generalized_source ? RequestAdditionKind.SPACE_2D : RequestAdditionKind.SINGLE,
                )) == c3d::INVALID_ARGUMENT);
                assert(allocator.attempts == attempts);
                request_assert_blocks_unchanged(&tracker, snapshot);
            };
        }
        assert(!tracker.has_leaks());
    }
}

fn void test_animation_play_invalid_configuration_precedes_multiplicative_unsupported() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId cubic = request_cubic_scale_clip(&fixture);
    PlayDesc desc = { .additive = true, .additive_scale = AdditiveScaleMode.MULTIPLICATIVE };
    assert(@catch(fixture.animator.play(&fixture.assets, cubic, desc)) == c3d::UNSUPPORTED);
    desc.root_motion = RootMotion.EXTRACT;
    assert(@catch(fixture.animator.play(&fixture.assets, cubic, desc)) == c3d::INVALID_ARGUMENT);
    assert(fixture.animator.action_count == 0);
}

fn void test_animation_inertial_request_stale_crowd_player_preserves_all_owner_blocks() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        MotionTestAllocator allocator = { .backing = &tracker };
        LayerFixture fixture;
        create_inertial_owner(&fixture, &allocator);
        defer destroy_layer_fixture(&fixture);
        Transform[1] placements = { maths::TRANSFORM_IDENTITY };
        CrowdPlaybackState* crowd = anim::create_crowd_playback(
            allocator: &allocator,
            template: &fixture.assets.model(fixture.model).data,
            placements: placements[..],
            actions_per_instance: 4,
            event_capacity: 64,
            inertia_enabled: true,
        )!!;
        defer anim::destroy_crowd_playback(crowd);
        crowd.model = fixture.model;
        crowd.count = 1;
        CrowdPlayer player = crowd.player(crowd.instance_id(0)!!)!!;
        ClipId clip = request_translation_clip(&fixture, { 1, 0, 0 }, { 1, 0, 0 });
        player.play(&fixture.assets, clip)!!;
        crowd.update(&fixture.assets, 0.25f);
        anim::reset_crowd_playback_slot(crowd, 0);
        AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
        targets[0].clip = clip;
        @pool() {
            RequestBlockSnapshot[] snapshot = request_snapshot_blocks(&tracker);
            uint attempts = allocator.attempts;
            assert(@catch(player.inertialize(
                assets: &fixture.assets,
                desc: { .duration = 0.5f, .actions = targets[..] },
            )) == c3d::INVALID_ID);
            assert(allocator.attempts == attempts);
            request_assert_blocks_unchanged(&tracker, snapshot);
        };
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_inertial_request_generalized_source_to_in_place_target_uses_linear_scale_residual() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    float[2] times = { 0, 1 };
    float[6] positive = { 1, 1, 1, 1, 1, 1 };
    float[6] negative = { -1, -1, -1, -1, -1, -1 };
    ClipId source = inertial_owner_clip(
        owner: &fixture,
        path: TargetPath.SCALE,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: positive[..],
        node: 2,
    );
    ClipId target = inertial_owner_clip(
        owner: &fixture,
        path: TargetPath.SCALE,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: negative[..],
        node: 2,
    );
    fixture.animator.play(&fixture.assets, source, request_generalized_desc())!!;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
    targets[0].clip = target;
    fixture.animator.inertialize(&fixture.assets, { .duration = 1, .actions = targets[..] })!!;
    assert(inertial_owner_row(&fixture).offset[2].scale == (double[<3>]){ 2, 2, 2 });
    assert(inertial_owner_pose(&fixture, 2).scale == (Vec3){ 1, 1, 1 });
    anim::update(&fixture.assets, &fixture.scene, 0.5f);
    assert(inertial_owner_pose(&fixture, 2).scale == (Vec3){ 0, 0, 0 });
    anim::update(&fixture.assets, &fixture.scene, 0.5f);
    assert(inertial_owner_pose(&fixture, 2).scale == (Vec3){ -1, -1, -1 });
}

fn void test_animation_planar_extract_yaw_and_translation_actions_remain_composable() @test {
    foreach (first_yaw : (bool[2]){ false, true }) {
        LayerFixture fixture;
        create_inertial_owner(&fixture, mem, false);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = inertial_owner_translation(
            owner: &fixture,
            start: {},
            end: { 1, 0, 0 },
            node: 2,
        );
        fixture.animator.play(&fixture.assets, clip, { .root_motion = EXTRACT, .root_yaw = first_yaw })!!;
        fixture.animator.play(&fixture.assets, clip, { .root_motion = EXTRACT, .root_yaw = !first_yaw })!!;
        anim::update(&fixture.assets, &fixture.scene, 0.25f);
        PlaybackView playback = fixture.animator.playback();
        assert(*playback.action_count == 2);
        assert(playback.actions.get(playback.order[0]).root_yaw == first_yaw);
        assert(playback.actions.get(playback.order[1]).root_yaw != first_yaw);
        RootMotionDelta delta = fixture.animator.root_motion;
        assert(delta.translation == (Vec3){ 0.25f, 0, 0 });
        assert(delta.rotation.v == quaternion::IDENTITY{float}.v);
    }
}

fn void test_animation_inertial_root_source_final_rate_zero_step_and_discrete_decay() @test {
    InertialRow row = {
        .control = { .active = true, .duration = 1 },
        .root = {
            .source_translation_rate = { 4, 2, -1 },
            .source_twist_rate = 2,
            .target_rate_pending = true,
        },
    };
    RootMotionDelta target = { .translation = { 0.1f, 0, 0 }, .rotation = quaternion::IDENTITY };
    RootMotionDelta zero = anim::publish_inertial_root_motion(
        row: &row,
        target: {},
        translation: {},
        twist: 0,
        up: { 0, 1, 0 },
        dt: 0,
    );
    assert(zero.translation == (Vec3){} && row.root.target_rate_pending);
    row.control.elapsed = 0.5;
    RootMotionDelta actual = anim::publish_inertial_root_motion(
        row: &row,
        target: target,
        translation: { target.translation.x, 0, 0 },
        twist: 0.05,
        up: { 0, 1, 0 },
        dt: 0.1,
    );
    double expected_x = (double)target.translation.x + (4 - (double)target.translation.x / 0.1) * 0.05;
    assert(math::abs((double)actual.translation.x - expected_x) < 3e-8);
    assert(math::abs(actual.translation.y - 0.1f) < 1e-8);
    assert(math::abs(actual.translation.z + 0.05f) < 1e-8);
    assert(math::abs(row.root.twist_rate - 1.25) < 1e-15);
    assert(row.root.translation_rate.x == (double)actual.translation.x / 0.1);
    assert(!row.root.target_rate_pending);
    row.control.active = false;
    RootMotionDelta finished = anim::publish_inertial_root_motion(
        row: &row,
        target: target,
        translation: { target.translation.x, 0, 0 },
        twist: 0.05,
        up: { 0, 1, 0 },
        dt: 0.1,
    );
    assert(finished.translation == target.translation && finished.rotation.v == target.rotation.v);
}

fn ClipId root_frame_source_clip(LayerFixture* fixture) @local {
    float[2] times = { 0, 1 };
    float[6] positions = { 0, 0, 0, 1, 2, 3 };
    Quat endpoint = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 1.0f);
    float[8] rotations = { 0, 0, 0, 1, endpoint.v.x, endpoint.v.y, endpoint.v.z, endpoint.v.w };
    Track[2] tracks = {
        make_track(
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: positions[..],
        ),
        make_track(
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: rotations[..],
        ),
    };
    uint[1] targets = { 2 };
    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn void root_frame_play_source(LayerFixture* fixture, ClipId clip) @local {
    PlayDesc extraction = {
        .root_motion = RootMotion.EXTRACT,
        .extraction = {
            .generalized = true,
            .translation_axes = { true, true, true },
            .up = { 0, 0, 1 },
            .twist = true,
        },
    };
    fixture.animator.play(&fixture.assets, clip, extraction)!!;
}

fn void assert_root_frame_decay(
    RootMotionDelta actual,
    RootMotionDelta source,
    double source_twist_rate,
    double step,
) @local {
    double[<3>] published = { actual.translation.x, actual.translation.y, actual.translation.z };
    double[<3>] saved = { source.translation.x, source.translation.y, source.translation.z };
    assert((published - saved * ROOT_FRAME_FIRST_DECAY).length() < ROOT_FRAME_MOTION_EPSILON);
    assert(actual.translation.z != 0);
    assert(actual.rotation.v.x == 0 && actual.rotation.v.y == 0 && actual.rotation.v.z != 0);
    double angle = 2 * math::atan2((double)actual.rotation.v.z, (double)actual.rotation.v.w);
    double expected = source_twist_rate * step * ROOT_FRAME_FIRST_DECAY;
    assert(math::abs(angle - expected) < ROOT_FRAME_MOTION_EPSILON);
}

fn void test_animation_inertial_root_frame_generalized_z_source_survives_keep_and_keep_interruption() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId source_clip = root_frame_source_clip(&fixture);
    ClipId first_keep = layer_translation(&fixture, { 8, 0, 0 });
    ClipId second_keep = layer_translation(&fixture, { -4, 0, 0 });
    root_frame_play_source(&fixture, source_clip);
    anim::update(&fixture.assets, &fixture.scene, 0.1f);
    anim::update(&fixture.assets, &fixture.scene, 0.1f);
    RootMotionDelta source = fixture.animator.root_motion;
    InertialRow* row = inertial_owner_row(&fixture);
    double step = (double)0.1f;
    double[<3>] source_rate = row.root.translation_rate;
    double source_twist_rate = row.root.twist_rate;
    assert(source.translation.z > 0 && row.control.history_valid);
    assert(math::abs(source_twist_rate - 1) < ROOT_FRAME_RATE_EPSILON);
    AnimationTargetDesc[1] target = { anim::ANIMATION_TARGET_DEFAULT };
    target[0].clip = first_keep;
    fixture.animator.inertialize(&fixture.assets, { .duration = 1, .actions = target[..] })!!;
    Transform displayed = inertial_owner_pose(&fixture, 2);
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert(row.control.elapsed == 0 && row.control.active);
    assert(row.root.translation_rate == source_rate && row.root.twist_rate == source_twist_rate);
    Transform zero_pose = inertial_owner_pose(&fixture, 2);
    assert(zero_pose.position == displayed.position && zero_pose.rotation.v == displayed.rotation.v);
    RootMotionDelta zero = fixture.animator.root_motion;
    assert(zero.translation == (Vec3){} && zero.rotation.v == quaternion::IDENTITY{float}.v);
    anim::update(&fixture.assets, &fixture.scene, 0.1f);
    RootMotionDelta first = fixture.animator.root_motion;
    assert_root_frame_decay(
        actual: first,
        source: source,
        source_twist_rate: source_twist_rate,
        step: step,
    );
    assert((row.root.translation_rate - source_rate * ROOT_FRAME_FIRST_DECAY).length() < ROOT_FRAME_RATE_EPSILON);
    assert(math::abs(row.root.twist_rate - source_twist_rate * ROOT_FRAME_FIRST_DECAY) < ROOT_FRAME_RATE_EPSILON);
    assert(math::abs(2 * math::atan2((double)first.rotation.v.z, (double)first.rotation.v.w) - 0.099144)
      < ROOT_FRAME_MOTION_EPSILON);
    double[<3>] first_rate = row.root.translation_rate;
    double first_twist_rate = row.root.twist_rate;
    target[0].clip = second_keep;
    fixture.animator.inertialize(&fixture.assets, { .duration = 1, .actions = target[..] })!!;
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert(row.control.elapsed == 0);
    assert(row.root.translation_rate == first_rate && row.root.twist_rate == first_twist_rate);
    anim::update(&fixture.assets, &fixture.scene, 0.1f);
    RootMotionDelta interrupted = fixture.animator.root_motion;
    assert_root_frame_decay(
        actual: interrupted,
        source: first,
        source_twist_rate: first_twist_rate,
        step: step,
    );
    assert((row.root.translation_rate - first_rate * ROOT_FRAME_FIRST_DECAY).length() < ROOT_FRAME_RATE_EPSILON);
    assert(math::abs(row.root.twist_rate - first_twist_rate * ROOT_FRAME_FIRST_DECAY) < ROOT_FRAME_RATE_EPSILON);
}

fn void test_animation_inertial_root_frame_differing_target_extract_up_is_rejected_without_source_mutation() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId source_clip = root_frame_source_clip(&fixture);
    root_frame_play_source(&fixture, source_clip);
    anim::update(&fixture.assets, &fixture.scene, 0.1f);
    anim::update(&fixture.assets, &fixture.scene, 0.1f);
    InertialRow* row = inertial_owner_row(&fixture);
    InertialControl control_before = row.control;
    RootInertialState root_before = row.root;
    RootMotionDelta motion_before = fixture.animator.root_motion;
    PlaybackView playback = fixture.animator.playback();
    AnimationActionId id = playback.order[0];
    Action* action = playback.actions.get(id);
    char[Action::size] action_before;
    mem::copy(&action_before, action, Action::size);
    AnimationTargetDesc[1] target = { anim::ANIMATION_TARGET_DEFAULT };
    target[0].clip = source_clip;
    target[0].play = {
        .root_motion = RootMotion.EXTRACT,
        .extraction = {
            .generalized = true,
            .translation_axes = { true, true, true },
            .up = { 0, 1, 0 },
            .twist = true,
        },
    };
    bool caught;
    if (catch excuse = fixture.animator.inertialize(&fixture.assets, { .duration = 1, .actions = target[..] })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
        caught = true;
    }
    assert(caught && playback.actions.is_live(id) && *playback.action_count == 1);
    assert(mem::equals((char*)&control_before, (char*)&row.control, InertialControl::size));
    assert(mem::equals((char*)&root_before, (char*)&row.root, RootInertialState::size));
    assert(mem::equals((char*)&action_before, (char*)action, Action::size));
    RootMotionDelta after = fixture.animator.root_motion;
    assert(after.translation == motion_before.translation && after.rotation.v == motion_before.rotation.v);
}

fn ClipId root_frame_target_rate_clip(LayerFixture* fixture) @local {
    float[2] times = { 0, 1 };
    float[6] positions = { 0, 0, 0, 4, -2, 1 };
    Quat endpoint = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 1.5f);
    float[8] rotations = { 0, 0, 0, 1, endpoint.v.x, endpoint.v.y, endpoint.v.z, endpoint.v.w };
    Track[2] tracks = {
        make_track(
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: positions[..],
        ),
        make_track(
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: rotations[..],
        ),
    };
    uint[1] targets = { 2 };
    ClipId clip = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    ClipEvent[2] events = { { .time = 0.5f, .id = 101 }, { .time = 0.75f, .id = 102 } };
    fixture.assets.set_clip_events(clip, events[..])!!;
    return clip;
}

fn void root_frame_request_rate_target(LayerFixture* fixture, ClipId clip) @local {
    AnimationTargetDesc[1] target = { anim::ANIMATION_TARGET_DEFAULT };
    target[0].clip = clip;
    target[0].loop = false;
    target[0].play = {
        .root_motion = RootMotion.EXTRACT,
        .extraction = {
            .generalized = true,
            .translation_axes = { true, true, true },
            .up = { 0, 0, 1 },
            .twist = true,
        },
    };
    fixture.animator.inertialize(&fixture.assets, { .duration = 1, .actions = target[..] })!!;
}

fn double root_frame_reference_target_turn(LayerFixture* fixture, ClipId clip) @local {
    Track* track = &fixture.assets.clip(clip).data.tracks[1];
    return 2 * math::atan2((double)track.values[6], (double)track.values[7]);
}

fn double[<3>] root_frame_reference_target_delta(double begin, double end, double turn) @local {
    double travel = end - begin;
    double sine = math::sin(turn * begin);
    double cosine = math::cos(turn * begin);
    return { (4 * cosine - 2 * sine) * travel, (-4 * sine - 2 * cosine) * travel, travel };
}

fn void test_animation_inertial_root_frame_first_target_mean_rate_converges_to_source_at_small_steps() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId source = root_frame_source_clip(&fixture);
    ClipId target = root_frame_target_rate_clip(&fixture);
    root_frame_play_source(&fixture, source);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    InertialRow* row = inertial_owner_row(&fixture);
    double[<3>] source_rate = row.root.translation_rate;
    double source_turn_rate = row.root.twist_rate;
    root_frame_request_rate_target(&fixture, target);
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert(row.root.target_rate_pending);
    float step = 1e-4f;
    double dt = step;
    anim::update(&fixture.assets, &fixture.scene, step);
    RootMotionDelta actual = fixture.animator.root_motion;
    double[<3>] observed = { actual.translation.x, actual.translation.y, actual.translation.z };
    double observed_turn = 2 * math::atan2((double)actual.rotation.v.z, (double)actual.rotation.v.w);
    assert((observed / dt - source_rate).length() < ROOT_FRAME_RATE_EPSILON);
    assert(math::abs(observed_turn / dt - source_turn_rate) < ROOT_FRAME_RATE_EPSILON);
    assert(row.control.elapsed == dt && !row.root.target_rate_pending);
}

fn void test_animation_inertial_root_frame_extra_displacement_sums_discrete_residual_rates_through_completion() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId source = root_frame_source_clip(&fixture);
    ClipId target = root_frame_target_rate_clip(&fixture);
    root_frame_play_source(&fixture, source);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    anim::update(&fixture.assets, &fixture.scene, 0.125f);
    InertialRow* row = inertial_owner_row(&fixture);
    double[<3>] source_rate = row.root.translation_rate;
    double source_turn_rate = row.root.twist_rate;
    root_frame_request_rate_target(&fixture, target);
    double target_turn = root_frame_reference_target_turn(&fixture, target);
    double[<3>] residual_rate = source_rate - (double[<3>]){ 4, -2, 1 };
    double residual_turn_rate = source_turn_rate - target_turn;
    float[7] steps = { 0.0625f, 0.09375f, 0.125f, 0.21875f, 0.25f, 0.1875f, 0.125f };
    double[7] decays = {
        0.9977817535400391, 0.9702349305152893, 0.860823929309845, 0.5, 0.103515625, 0.0022182464599609375, 0,
    };
    double clock;
    double[<3>] observed_extra;
    double[<3>] expected_extra;
    double observed_extra_turn;
    double expected_extra_turn;
    uint crossed_events;
    foreach (index, step : steps) {
        double dt = step;
        double next_clock = math::min(1.0, clock + dt);
        double[<3>] raw = root_frame_reference_target_delta(clock, next_clock, target_turn);
        double raw_turn = target_turn * (next_clock - clock);
        double decay = decays[index];
        double[<3>] extra = residual_rate * (decay * dt);
        double extra_turn = residual_turn_rate * decay * dt;
        anim::update(&fixture.assets, &fixture.scene, step);
        RootMotionDelta actual = fixture.animator.root_motion;
        double[<3>] observed = { actual.translation.x, actual.translation.y, actual.translation.z };
        double observed_turn = 2 * math::atan2((double)actual.rotation.v.z, (double)actual.rotation.v.w);
        assert((observed - raw - extra).length() < ROOT_FRAME_MOTION_EPSILON);
        assert(math::abs(observed_turn - raw_turn - extra_turn) < ROOT_FRAME_MOTION_EPSILON);
        observed_extra += observed - raw;
        expected_extra += extra;
        observed_extra_turn += observed_turn - raw_turn;
        expected_extra_turn += extra_turn;
        foreach (event : fixture.animator.events[:fixture.animator.event_count]) {
            assert(c3d::same_id(event.clip, target));
            assert(event.id == (crossed_events == 0 ? 101 : 102));
            assert(event.time == (crossed_events == 0 ? 0.5f : 0.75f));
            crossed_events++;
        }
        clock = next_clock;
    }
    assert((observed_extra - expected_extra).length() < ROOT_FRAME_MOTION_EPSILON);
    assert(math::abs(observed_extra_turn - expected_extra_turn) < ROOT_FRAME_MOTION_EPSILON);
    assert(crossed_events == 2 && row.control.elapsed == 1 && !row.control.active);
    anim::update(&fixture.assets, &fixture.scene, 0);
    RootMotionDelta after = fixture.animator.root_motion;
    assert(after.translation == (Vec3){} && after.rotation.v == quaternion::IDENTITY{float}.v);
}

fn TransitionPrepareSnapshot snapshot_transition_owner(PlaybackView* playback) @local {
    char[] actions = ((char*)playback.actions.items.ptr)[:playback.actions.items.len * Action::size];
    char[] linear = ((char*)playback.blend_spaces.ptr)[:playback.blend_spaces.len * BlendSpace1D::size];
    char[] planar = ((char*)playback.blend_spaces_2d.ptr)[:playback.blend_spaces_2d.len * BlendSpace2D::size];
    TransitionPrepareSnapshot snapshot = {
        .actions = alloc::clone_slice(mem, actions),
        .generations = alloc::clone_slice(mem, playback.actions.generations),
        .free = alloc::clone_slice(mem, playback.actions.free),
        .order = alloc::clone_slice(mem, playback.order),
        .linear = alloc::clone_slice(mem, linear),
        .planar = alloc::clone_slice(mem, planar),
        .action_count = *playback.action_count,
        .free_count = playback.actions.free_count,
    };
    return snapshot;
}

fn void destroy_transition_snapshot(TransitionPrepareSnapshot* snapshot) @local {
    alloc::free(mem, snapshot.actions.ptr);
    alloc::free(mem, snapshot.generations.ptr);
    alloc::free(mem, snapshot.free.ptr);
    alloc::free(mem, snapshot.order.ptr);
    alloc::free(mem, snapshot.linear.ptr);
    alloc::free(mem, snapshot.planar.ptr);
}

fn void assert_transition_owner_unchanged(PlaybackView* playback, TransitionPrepareSnapshot* snapshot) @local {
    assert(*playback.action_count == snapshot.action_count && playback.actions.free_count == snapshot.free_count);
    assert(mem::equals((char*)playback.actions.items.ptr, snapshot.actions.ptr, snapshot.actions.len));
    assert(playback.actions.generations == snapshot.generations && playback.actions.free == snapshot.free);
    assert(mem::equals(playback.order, snapshot.order));
    assert(mem::equals((char*)playback.blend_spaces.ptr, snapshot.linear.ptr, snapshot.linear.len));
    assert(mem::equals((char*)playback.blend_spaces_2d.ptr, snapshot.planar.ptr, snapshot.planar.len));
}

fn void test_animation_transition_prepare_full_animator_copies_inputs_and_boolean_source_aliases() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = layer_translation(&fixture, { 1, 2, 3 });
        bool[4] source_membership = { false, true, false, true };
        JointMask source_mask = { .nodes = source_membership[..] };
        for (uint index = 0; index < anim::MAX_ACTIONS; index++) {
            fixture.animator.play(&fixture.assets, clip, { .mask = &source_mask })!!;
        }
        PlaybackView playback = fixture.animator.playback();
        assert(playback.actions.free_count == 0);
        TransitionPrepareSnapshot snapshot = snapshot_transition_owner(&playback);
        defer destroy_transition_snapshot(&snapshot);
        JointMask alias_mask = { .nodes = fixture.animator.action(fixture.animator.order[0]).mask };
        AnimationTargetDesc[16] targets;
        foreach (index, &target : targets) {
            *target = anim::ANIMATION_TARGET_DEFAULT;
            target.clip = clip;
            target.start_time = (float)index / 32;
            target.speed = index ? -0.5f : 1.5f;
            target.weight = 0.25f;
            target.play.mask = &alias_mask;
        }
        uint[3] members = { 0, 1, 2 };
        Vec2[3] points = { { 0, 0 }, { 1, 0 }, { 0, 1 } };
        BlendTriangle[1] triangles = { { .indices = { 2, 1, 0 } } };
        AnimationTransitionSpaceDesc[1] spaces = {
            { .space = {
                .actions = members[..], .kind = TWO_DIMENSIONAL, .points = points[..],
                .triangles = triangles[..], .parameter_2d = { 0.25f, 0.5f },
                .weight = 0.75f, .speed = -0.25f, .playing = true,
            } },
        };
        PreparedTransition prepared = anim::prepare_animation_transition(
            playback: &playback,
            assets: &fixture.assets,
            desc: { .duration = 0.5f, .actions = targets[..], .spaces = spaces[..] },
            destination: fixture.animator.pose_storage.destination,
            motion_basis: anim::animator_motion_basis(fixture.animator),
        )!!;
        defer anim::release_prepared_transition(&prepared);
        assert_transition_owner_unchanged(&playback, &snapshot);
        assert(prepared.action_count == 16 && prepared.space_count == 1 && prepared.duration == 0.5f);
        assert(prepared.spaces[0].count == 3);
        foreach (index, action : prepared.actions[:prepared.action_count]) {
            assert(action.time == (float)index / 32 && action.clock_time == (double)action.time);
            assert(action.previous_time == action.clock_time && action.published_time == action.time);
            assert(action.speed == (index ? -0.5f : 1.5f) && action.weight == 0.25f);
            assert(prepared.has_boolean_mask[index] && prepared.boolean_masks[index].ptr != alias_mask.nodes.ptr);
            assert(prepared.boolean_masks[index] == source_membership[..]);
        }
        points[0] = { 7, 8 };
        members[0] = 9;
        triangles[0].indices[0] = 99;
        targets[0].start_time = 0.9f;
        assert(prepared.spaces[0].points[0] == (Vec2){} && prepared.spaces[0].members[0] == 0);
        assert(prepared.spaces[0].triangles[0].indices[0] == 2);
        playback.mask_storage[..] = false;
        foreach (row : prepared.boolean_masks[:prepared.action_count]) assert(row == source_membership[..]);
        sz acquisitions = tracker.total_allocation_count();
        AnimationTransitionResult installed = anim::install_animation_transition(
            playback: &playback,
            assets: &fixture.assets,
            prepared: &prepared,
        );
        assert(tracker.total_allocation_count() == acquisitions);
        assert(installed.count == 16 && *playback.action_count == 16 && playback.actions.free_count == 0);
        foreach (old : snapshot.order[:snapshot.action_count]) assert(!playback.actions.is_live(old));
        foreach (index, id : installed.actions[:installed.count]) {
            assert(c3d::same_id(id, playback.order[index]));
            Action* action = playback.action(id);
            assert(action.mask == source_membership[..] && action.speed == (index ? -0.5f : 1.5f));
            if (index >= 3) assert(action.time == (float)index / 32 && action.weight == 0.25f);
        }
        BlendSpace2D* installed_space = &playback.blend_spaces_2d[0];
        assert(installed_space.count == 3);
        assert(installed_space.points[0] == (Vec2){} && installed_space.parameter == (Vec2){ 0.25f, 0.5f });
        assert(installed_space.triangles[0].indices[0] == 2 && installed_space.triangles[0].indices[1] == 1);
        assert(installed_space.triangles[0].indices[2] == 0);
        assert(playback.action(installed.actions[0]).weight == 0.1875f);
        assert(playback.action(installed.actions[1]).weight == 0.1875f);
        assert(playback.action(installed.actions[2]).weight == 0.375f);
        assert(playback.action(installed.actions[0]).time == 0 && installed_space.phase == 0);
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_transition_prepare_invalid_targets_and_groups_fail_before_resources() @test {
    MotionTestAllocator probe = { .backing = mem };
    LayerFixture fixture;
    create_layer_fixture(&fixture, &probe);
    defer destroy_layer_fixture(&fixture);
    ClipId clip = layer_translation(&fixture, { 1, 2, 3 });
    PlaybackView playback = fixture.animator.playback();
    TransitionPrepareSnapshot snapshot = snapshot_transition_owner(&playback);
    defer destroy_transition_snapshot(&snapshot);
    AnimationTargetDesc[3] targets;
    Vec2[3] points = { { 0, 0 }, { 1, 0 }, { 0, 1 } };
    BlendTriangle[1] triangles = { { .indices = { 0, 1, 2 } } };
    uint[3] members;
    AnimationTransitionSpaceDesc[1] spaces;
    for (uint invalid = 0; invalid < 9; invalid++) {
        targets[..] = anim::ANIMATION_TARGET_DEFAULT;
        foreach (&target : targets) target.clip = clip;
        members[0] = 0;
        members[1] = 1;
        members[2] = 2;
        triangles[0].indices = { 0, 1, 2 };
        spaces[0] = { .space = {
            .actions = members[..], .kind = TWO_DIMENSIONAL, .points = points[..],
            .triangles = triangles[..], .weight = 1, .speed = 1, .playing = true,
        } };
        AnimationTransitionDesc desc = { .duration = 1, .actions = targets[..], .spaces = spaces[..] };
        fault expected = c3d::INVALID_ARGUMENT;
        switch (invalid) {
            case 0: desc.duration = float::nan;
            case 1: targets[2].speed = float::inf;
            case 2: targets[2].weight = -1;
            case 3: targets[2].start_time = float::nan;
            case 4:
                targets[2].clip = { .index = uint::max, .generation = 1 };
                expected = c3d::INVALID_ID;
            case 5: members[1] = 0;
            case 6: triangles[0].indices[2] = 99;
            case 7: spaces[0].space.parameter_2d.x = float::nan;
            case 8: members[2] = 3;
        }
        uint attempts = probe.attempts;
        assert(@catch(anim::prepare_animation_transition(
            playback: &playback,
            assets: &fixture.assets,
            desc: desc,
            destination: fixture.animator.pose_storage.destination,
            motion_basis: anim::animator_motion_basis(fixture.animator),
        )) == expected);
        assert(probe.attempts == attempts);
        assert_transition_owner_unchanged(&playback, &snapshot);
    }
}

fn RootExtractionDesc transition_admission_extraction() @local {
    return { .generalized = true, .translation_axes = { true, true, true }, .up = { 0, 1, 0 }, .twist = true };
}

fn ClipId transition_admission_translation(LayerFixture* fixture, Vec3 start) @local {
    float[2] times = { 0, 1 };
    float[6] values = { start.x, start.y, start.z, start.x + 1, start.y + 2, start.z + 3 };
    Track[1] tracks = { make_track(
        path: TRANSLATION,
        interpolation: LINEAR,
        times: times[..],
        values: values[..],
    ) };
    uint[1] targets = { 2 };
    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn ClipId transition_admission_scale(LayerFixture* fixture, Vec3 start, Vec3 end) @local {
    float[2] times = { 0, 1 };
    float[6] values = { start.x, start.y, start.z, end.x, end.y, end.z };
    Track[1] tracks = { make_track(
        path: SCALE,
        interpolation: LINEAR,
        times: times[..],
        values: values[..],
    ) };
    uint[1] targets = { 2 };
    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn AnimationActionId initialize_transition_admission_source(LayerFixture* fixture, TrackingAllocator* tracker) @local {
    create_layer_fixture(fixture, tracker);
    ClipId clip = transition_admission_translation(fixture, {});
    AnimationActionId action = fixture.animator.play(&fixture.assets, clip, {
        .root_motion = EXTRACT,
        .extraction = transition_admission_extraction(),
    })!!;
    anim::update(&fixture.assets, &fixture.scene, 0);
    return action;
}

fn void test_animation_transition_admission_reference_offsets_and_animated_basis_are_allowed() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    LayerFixture fixture;
    initialize_transition_admission_source(&fixture, &tracker);
    defer destroy_layer_fixture(&fixture);
    ClipId target_clip = transition_admission_translation(&fixture, { 5, 7, -3 });
    AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
    targets[0].clip = target_clip;
    targets[0].play = { .root_motion = EXTRACT, .extraction = transition_admission_extraction() };
    PlaybackView playback = fixture.animator.playback();
    MotionBasis basis = anim::animator_motion_basis(fixture.animator);
    basis.basis.m03 += 9;
    sz acquisitions = tracker.total_allocation_count();
    anim::validate_animation_transition(
        playback: &playback,
        assets: &fixture.assets,
        desc: { .duration = 0.5f, .actions = targets[..] },
        destination: fixture.animator.pose_storage.destination,
        motion_basis: basis,
    )!!;
    assert(tracker.total_allocation_count() == acquisitions);
}

fn void test_animation_transition_admission_extraction_mismatches_are_atomic() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    LayerFixture fixture;
    AnimationActionId id = initialize_transition_admission_source(&fixture, &tracker);
    defer destroy_layer_fixture(&fixture);
    ClipId target_clip = transition_admission_translation(&fixture, { 5, 7, -3 });
    Action* source = fixture.animator.action(id);
    AnimationTargetDesc[1] targets;
    for (uint mismatch = 0; mismatch < 3; mismatch++) {
        targets[0] = anim::ANIMATION_TARGET_DEFAULT;
        targets[0].clip = target_clip;
        targets[0].play = { .root_motion = EXTRACT, .extraction = transition_admission_extraction() };
        PlaybackView playback = fixture.animator.playback();
        MotionBasis basis = anim::animator_motion_basis(fixture.animator);
        switch (mismatch) {
            case 0: targets[0].play.extraction.up = { 1, 0, 0 };
            case 1: targets[0].play.extraction.translation_axes[1] = false;
            case 2: targets[0].play.extraction.twist = false;
        }
        Action unchanged = *source;
        uint count = fixture.animator.action_count;
        uint generation = fixture.animator.actions.generations[id.index];
        sz acquisitions = tracker.total_allocation_count();
        assert(@catch(anim::validate_animation_transition(
            playback: &playback,
            assets: &fixture.assets,
            desc: { .duration = 0.5f, .actions = targets[..] },
            destination: fixture.animator.pose_storage.destination,
            motion_basis: basis,
        )) == c3d::INVALID_ARGUMENT);
        assert(tracker.total_allocation_count() == acquisitions);
        assert(fixture.animator.action_count == count && fixture.animator.actions.generations[id.index] == generation);
        assert(mem::equals(&unchanged, source, Action::size));
    }
}

fn void test_animation_transition_admission_additive_scale_neutrality_ignores_zero_contribution() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    LayerFixture fixture;
    AnimationActionId source_id = initialize_transition_admission_source(&fixture, &tracker);
    defer destroy_layer_fixture(&fixture);
    ClipId nonneutral = transition_admission_scale(&fixture, { 1, 1, 1 }, { 2, 2, 2 });
    ClipId neutral = transition_admission_scale(&fixture, { 2, 4, 8 }, { 2, 4, 8 });
    bool[4] excluded;
    JointMask mask = { .nodes = excluded[..] };
    PlaybackView playback = fixture.animator.playback();
    foreach (mode : (AdditiveScaleMode[2]){ DIFFERENCE, MULTIPLICATIVE }) {
        AnimationTargetDesc[2] targets = { anim::ANIMATION_TARGET_DEFAULT, anim::ANIMATION_TARGET_DEFAULT };
        targets[0].clip = fixture.animator.action(source_id).clip;
        targets[0].play = { .root_motion = EXTRACT, .extraction = transition_admission_extraction() };
        targets[1].clip = nonneutral;
        targets[1].weight = 0;
        targets[1].play = { .additive = true, .mask = &mask, .additive_scale = mode };
        sz acquisitions = tracker.total_allocation_count();
        assert(@catch(anim::validate_animation_transition(
            playback: &playback,
            assets: &fixture.assets,
            desc: { .duration = 0.5f, .actions = targets[..] },
            destination: fixture.animator.pose_storage.destination,
            motion_basis: anim::animator_motion_basis(fixture.animator),
        )) == c3d::INVALID_ARGUMENT);
        targets[1].clip = neutral;
        anim::validate_animation_transition(
            playback: &playback,
            assets: &fixture.assets,
            desc: { .duration = 0.5f, .actions = targets[..] },
            destination: fixture.animator.pose_storage.destination,
            motion_basis: anim::animator_motion_basis(fixture.animator),
        )!!;
        assert(tracker.total_allocation_count() == acquisitions);
    }
}
