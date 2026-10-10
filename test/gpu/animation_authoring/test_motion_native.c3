module c3d::render::acceptance;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::camera;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import std::io;
import std::io::file;
import std::math;
import std::os::env;

const uint MOTION_NATIVE_FRAMES @private = 1200;
const float MOTION_NATIVE_DT @private = 1.0f / 60;
const double MOTION_NATIVE_POSITION_EPSILON @private = 1e-5;
const double MOTION_NATIVE_ROTATION_EPSILON @private = 1e-4;
const double MOTION_NATIVE_SCALE_EPSILON @private = 1e-5;
const double MOTION_NATIVE_MORPH_EPSILON @private = 1e-6;
const double MOTION_NATIVE_DRIFT_EPSILON @private = 0.0005;
const double MOTION_NATIVE_SERIES_ANGLE @private = 1e-5;
const float MOTION_NATIVE_TRANSITION_SECONDS @private = 1;

struct MotionNativeRotation @private {
    double[<3>] vector;
    double scalar;
}

struct MotionNativePose @private {
    double[<3>] position;
    MotionNativeRotation rotation;
    double[<3>] scale;
}

struct MotionNativeRate @private {
    double[<3>] position;
    double[<3>] angular;
    double[<3>] scale;
}

struct MotionNativeOracle @private {
    MotionNativePose[] previous;
    MotionNativeRate[] velocity;
    MotionNativeRate[] offset;
    MotionNativeRate[] offset_rate;
    double[] morph_previous;
    double[] morph_velocity;
    double[] morph_offset;
    double[] morph_offset_rate;
    bool[] consumed;
    bool history;
    bool transitioned;
    double elapsed;
    double duration;
    MotionNativePose carrier;
}

struct MotionNativeErrors @private {
    double position;
    double rotation;
    double scale;
    double morph;
    double carrier_drift;
    double carrier_rotation;
    double pivot_drift;
    double radius;
    double carrier_relative;
    uint requests;
    uint checked_nodes;
    uint checked_morphs;
}

fn double[<3>] motion_native_vector(Vec3 value) @private => { value.x, value.y, value.z };

fn MotionNativeRotation motion_native_product(MotionNativeRotation first, MotionNativeRotation second) @private {
    return {
        .vector = first.vector * second.scalar + second.vector * first.scalar + first.vector.cross(second.vector),
        .scalar = first.scalar * second.scalar - first.vector.dot(second.vector),
    };
}

fn MotionNativeRotation motion_native_inverse(MotionNativeRotation rotation) @private {
    return { .vector = -rotation.vector, .scalar = rotation.scalar };
}

fn MotionNativeRotation motion_native_normalize(MotionNativeRotation rotation) @private {
    double length = math::sqrt(rotation.vector.dot(rotation.vector) + rotation.scalar * rotation.scalar);
    return { .vector = rotation.vector / length, .scalar = rotation.scalar / length };
}

fn MotionNativeRotation motion_native_rotation(Quat value) @private {
    return motion_native_normalize({ .vector = { value.i, value.j, value.k }, .scalar = value.l });
}

fn double[<3>] motion_native_rotate(MotionNativeRotation rotation, double[<3>] point) @private {
    double[<3>] cross = 2 * rotation.vector.cross(point);
    return point + rotation.scalar * cross + rotation.vector.cross(cross);
}

fn double[<3>] motion_native_log(MotionNativeRotation rotation) @private {
    rotation = motion_native_normalize(rotation);
    if (rotation.scalar < 0) {
        rotation.vector = -rotation.vector;
        rotation.scalar = -rotation.scalar;
    }
    double length = rotation.vector.length();
    if (length == 0) return {};
    return rotation.vector * (2 * math::atan2(length, rotation.scalar) / length);
}

fn MotionNativeRotation motion_native_exp(double[<3>] rotation) @private {
    double angle = rotation.length();
    double squared = angle * angle;
    double coefficient = angle < MOTION_NATIVE_SERIES_ANGLE
      ? 0.5 - squared / 48 + squared * squared / 3840 : math::sin(angle * 0.5) / angle;
    return { .vector = rotation * coefficient, .scalar = math::cos(angle * 0.5) };
}

fn double[<3>] motion_native_inverse_jacobian(double[<3>] rotation, double[<3>] velocity) @private {
    double angle = rotation.length();
    double squared = angle * angle;
    double coefficient = angle < MOTION_NATIVE_SERIES_ANGLE
      ? 1.0 / 12 + squared / 720 + squared * squared / 30240
      : (1 - angle * 0.5 / math::tan(angle * 0.5)) / squared;
    double[<3>] cross = rotation.cross(velocity);
    return velocity - 0.5 * cross + coefficient * rotation.cross(cross);
}

fn MotionNativePose motion_native_pose(Transform pose) @private {
    return {
        .position = motion_native_vector(pose.position),
        .rotation = motion_native_rotation(pose.rotation),
        .scale = motion_native_vector(pose.scale),
    };
}

fn double motion_native_h0(double time) @private {
    double square = time * time;
    return 1 + square * time * (-10 + time * (15 - 6 * time));
}

fn double motion_native_h1(double time) @private {
    return time + time * time * time * (-6 + time * (8 - 3 * time));
}

fn void motion_native_track(
    Track* track,
    float time,
    double[] value,
    double[] rate,
    bool reverse_onset = false,
) @private {
    uint width = track.stride();
    uint last = (uint)track.times.len - 1;
    uint key;
    while (key < last && track.times[key + 1] <= time) key++;
    if (reverse_onset && key && track.times[key] == time) key--;
    rate[..] = 0;
    uint stride = track.interpolation == CUBIC_SPLINE ? width * 3 : width;
    uint value_slot = track.interpolation == CUBIC_SPLINE ? width : 0;
    float[] first = track.values[(usz)key * stride + value_slot:width];
    foreach (axis, component : first) value[axis] = component;
    if (track.interpolation != STEP && last && time >= track.times[0] && time <= track.times[last]) {
        if (key == last) key--;
        first = track.values[(usz)key * stride + value_slot:width];
        float[] second = track.values[(usz)(key + 1) * stride + value_slot:width];
        double span = (double)track.times[key + 1] - track.times[key];
        double fraction = ((double)time - track.times[key]) / span;
        if (track.interpolation == CUBIC_SPLINE) {
            double square = fraction * fraction;
            double cube = square * fraction;
            foreach (axis, component : first) {
                double outgoing = track.values[(usz)key * stride + (usz)(2 * width) + (usz)axis];
                double incoming = track.values[(usz)(key + 1) * stride + (usz)axis];
                value[axis] = (2 * cube - 3 * square + 1) * component
                  + (cube - 2 * square + fraction) * span * outgoing
                  + (-2 * cube + 3 * square) * second[axis] + (cube - square) * span * incoming;
                rate[axis] = ((6 * square - 6 * fraction) * component
                  + (-6 * square + 6 * fraction) * second[axis]) / span
                  + (3 * square - 4 * fraction + 1) * outgoing + (3 * square - 2 * fraction) * incoming;
            }
        } else {
            double dot;
            if (track.path == ROTATION) {
                foreach (axis, component : first) dot += (double)component * second[axis];
            }
            double sign = dot < 0 ? -1 : 1;
            dot = math::abs(dot);
            if (track.path == ROTATION && dot < (double)0.95f) {
                double angle = math::acos(math::clamp(dot, -1.0, 1.0));
                double denominator = math::sin(angle);
                foreach (axis, component : first) {
                    value[axis] = (math::sin((1 - fraction) * angle) * component
                      + math::sin(fraction * angle) * second[axis] * sign) / denominator;
                    rate[axis] = angle * (-math::cos((1 - fraction) * angle) * component
                      + math::cos(fraction * angle) * second[axis] * sign) / (denominator * span);
                }
            } else {
                foreach (axis, component : first) {
                    double endpoint = track.path == ROTATION ? (double)second[axis] * sign : second[axis];
                    value[axis] = (1 - fraction) * component + fraction * endpoint;
                    rate[axis] = (endpoint - component) / span;
                }
            }
        }
    }
    if (track.path == ROTATION) {
        double square;
        double projection;
        for (uint axis = 0; axis < width; axis++) {
            square += value[axis] * value[axis];
            projection += value[axis] * rate[axis];
        }
        double length = math::sqrt(square);
        for (uint axis = 0; axis < width; axis++) {
            rate[axis] = (rate[axis] - value[axis] * projection / square) / length;
            value[axis] /= length;
        }
    }
}

fn void motion_native_sample(
    ModelTemplate* template,
    AnimationClip* clip,
    float time,
    float speed,
    MotionNativePose[] poses,
    MotionNativeRate[] rates,
    double[] morph,
    double[] morph_rate,
    bool onset = false,
) @private {
    foreach (index, node : template.nodes) {
        poses[index] = motion_native_pose(node.local);
        rates[index] = {};
    }
    usz offset;
    foreach (mesh : template.meshes) {
        foreach (weight : mesh.default_morph_weights) morph[offset++] = weight;
    }
    morph_rate[..] = 0;
    foreach (&track : clip.tracks) {
        uint node = clip.targets[track.target];
        double[4] value;
        double[4] rate;
        uint width = track.stride();
        assert(width <= value.len);
        motion_native_track(
            track: track,
            time: time,
            value: value[:width],
            rate: rate[:width],
            reverse_onset: onset && speed < 0,
        );
        switch (track.path) {
            case TRANSLATION:
                poses[node].position = { value[0], value[1], value[2] };
                rates[node].position = (double[<3>]){ rate[0], rate[1], rate[2] } * speed;
            case ROTATION:
                poses[node].rotation = { .vector = { value[0], value[1], value[2] }, .scalar = value[3] };
                MotionNativeRotation derivative = { .vector = { rate[0], rate[1], rate[2] }, .scalar = rate[3] };
                rates[node].angular = 2.0 * (double)speed
                  * motion_native_product(derivative, motion_native_inverse(poses[node].rotation)).vector;
            case SCALE:
                poses[node].scale = { value[0], value[1], value[2] };
                rates[node].scale = (double[<3>]){ rate[0], rate[1], rate[2] } * speed;
            case MORPH_WEIGHTS:
                usz begin;
                foreach (mesh : template.meshes) {
                    if (mesh.node == node) break;
                    begin += mesh.default_morph_weights.len;
                }
                for (uint axis = 0; axis < width; axis++) {
                    morph[begin + axis] = value[axis];
                    morph_rate[begin + axis] = rate[axis] * speed;
                }
        }
    }
}

fn MotionNativeOracle motion_native_oracle(Allocator allocator, ModelTemplate* template, uint root) @private {
    uint morphs;
    foreach (mesh : template.meshes) morphs += (uint)mesh.default_morph_weights.len;
    MotionNativeOracle oracle = {
        .previous = alloc::new_array(allocator, MotionNativePose, template.nodes.len),
        .velocity = alloc::new_array(allocator, MotionNativeRate, template.nodes.len),
        .offset = alloc::new_array(allocator, MotionNativeRate, template.nodes.len),
        .offset_rate = alloc::new_array(allocator, MotionNativeRate, template.nodes.len),
        .morph_previous = alloc::new_array(allocator, double, (sz)morphs),
        .morph_velocity = alloc::new_array(allocator, double, (sz)morphs),
        .morph_offset = alloc::new_array(allocator, double, (sz)morphs),
        .morph_offset_rate = alloc::new_array(allocator, double, (sz)morphs),
        .consumed = alloc::new_array(allocator, bool, template.nodes.len),
    };
    for (int node = root == anim::NO_ROOT_NODE ? -1 : (int)root; node >= 0; node = template.nodes[node].parent) {
        oracle.consumed[node] = true;
    }
    return oracle;
}

fn void destroy_motion_native_oracle(Allocator allocator, MotionNativeOracle* oracle) @private {
    alloc::free(allocator, oracle.previous.ptr);
    alloc::free(allocator, oracle.velocity.ptr);
    alloc::free(allocator, oracle.offset.ptr);
    alloc::free(allocator, oracle.offset_rate.ptr);
    alloc::free(allocator, oracle.morph_previous.ptr);
    alloc::free(allocator, oracle.morph_velocity.ptr);
    alloc::free(allocator, oracle.morph_offset.ptr);
    alloc::free(allocator, oracle.morph_offset_rate.ptr);
    alloc::free(allocator, oracle.consumed.ptr);
}

fn void motion_native_capture_request(
    MotionNativeOracle* oracle,
    MotionNativePose[] incoming,
    MotionNativeRate[] rates,
    double[] morph,
    double[] morph_rate,
) @private {
    foreach (index, target : incoming) {
        MotionNativePose source = oracle.previous[index];
        oracle.offset[index].position = source.position - target.position;
        oracle.offset_rate[index].position = oracle.velocity[index].position - rates[index].position;
        oracle.offset[index].angular = motion_native_log(
            motion_native_product(source.rotation, motion_native_inverse(target.rotation)));
        double[<3>] rate = oracle.velocity[index].angular
          - motion_native_rotate(motion_native_exp(oracle.offset[index].angular), rates[index].angular);
        oracle.offset_rate[index].angular = motion_native_inverse_jacobian(oracle.offset[index].angular, rate);
        if (oracle.consumed[index]) {
            double source_scale = (source.scale.x + source.scale.y + source.scale.z) / 3;
            double target_scale = (target.scale.x + target.scale.y + target.scale.z) / 3;
            double source_rate = (oracle.velocity[index].scale.x + oracle.velocity[index].scale.y
              + oracle.velocity[index].scale.z) / 3;
            double target_rate = (rates[index].scale.x + rates[index].scale.y + rates[index].scale.z) / 3;
            double offset = math::ln(source_scale / target_scale);
            double offset_rate = source_rate / source_scale - target_rate / target_scale;
            oracle.offset[index].scale = { offset, offset, offset };
            oracle.offset_rate[index].scale = { offset_rate, offset_rate, offset_rate };
        } else {
            oracle.offset[index].scale = source.scale - target.scale;
            oracle.offset_rate[index].scale = oracle.velocity[index].scale - rates[index].scale;
        }
    }
    foreach (index, target : morph) {
        oracle.morph_offset[index] = oracle.morph_previous[index] - target;
        oracle.morph_offset_rate[index] = oracle.morph_velocity[index] - morph_rate[index];
    }
    oracle.duration = MOTION_NATIVE_TRANSITION_SECONDS;
    oracle.elapsed = 0;
    oracle.transitioned = true;
}

fn void motion_native_check_and_record(
    ModelTemplate* template,
    ModelInstance* instance,
    Scene* scene,
    MotionNativeOracle* oracle,
    MotionNativePose[] expected,
    double[] morph,
    MotionNativeErrors* errors,
    bool independent,
    double dt,
) @private {
    oracle.elapsed = math::min(oracle.duration, oracle.elapsed + dt);
    double normalized = oracle.duration == 0 ? 1 : oracle.elapsed / oracle.duration;
    double h0 = motion_native_h0(normalized);
    double h1 = motion_native_h1(normalized) * oracle.duration;
    bool active = oracle.transitioned && oracle.elapsed < oracle.duration;
    foreach (index, node : template.nodes) {
        MotionNativePose actual = motion_native_pose(instance.present_node((usz)index).local);
        MotionNativePose target = expected[index];
        if (active) {
            target.position += oracle.offset[index].position * h0 + oracle.offset_rate[index].position * h1;
            double[<3>] residual = oracle.offset[index].angular * h0 + oracle.offset_rate[index].angular * h1;
            target.rotation = motion_native_product(motion_native_exp(residual), target.rotation);
        }
        if (oracle.consumed[index]) {
            double scale = (target.scale.x + target.scale.y + target.scale.z) / 3;
            if (active) scale *= math::exp(oracle.offset[index].scale.x * h0 + oracle.offset_rate[index].scale.x * h1);
            target.scale = { scale, scale, scale };
        } else if (active) {
            target.scale += oracle.offset[index].scale * h0 + oracle.offset_rate[index].scale * h1;
        }
        if (independent && node.parent >= 0) {
            errors.position = math::max(errors.position, (actual.position - target.position).length());
            errors.rotation = math::max(errors.rotation, motion_native_log(
                motion_native_product(actual.rotation, motion_native_inverse(target.rotation))).length());
            for (uint axis = 0; axis < 3; axis++) {
                errors.scale = math::max(errors.scale, math::abs(actual.scale[axis] - target.scale[axis]));
            }
            errors.checked_nodes++;
        }
        if (oracle.history && dt > 0) {
            oracle.velocity[index] = {
                .position = (actual.position - oracle.previous[index].position) / dt,
                .angular = motion_native_log(motion_native_product(
                    actual.rotation, motion_native_inverse(oracle.previous[index].rotation))) / dt,
                .scale = (actual.scale - oracle.previous[index].scale) / dt,
            };
        }
        oracle.previous[index] = actual;
    }
    usz component;
    foreach (mesh : template.meshes) {
        float[] weights = scene.get(instance.present_node(mesh.node), Mesh).morph_weights;
        foreach (weight : weights) {
            double expected_weight = morph[component];
            if (active) expected_weight += oracle.morph_offset[component] * h0 + oracle.morph_offset_rate[component] * h1;
            if (independent) {
                errors.morph = math::max(errors.morph, math::abs((double)weight - expected_weight));
                errors.checked_morphs++;
            }
            if (oracle.history && dt > 0) {
                oracle.morph_velocity[component] = ((double)weight - oracle.morph_previous[component]) / dt;
            }
            oracle.morph_previous[component++] = weight;
        }
    }
    if (dt > 0) oracle.history = true;
}

fn void configure_motion_native_pair(Fixture* fixture, CrowdNativePair* pair, bool morph) @private {
    AnimatedCrowd* original = pair.scene.get(pair.crowd, AnimatedCrowd);
    CrowdInstance[CROWD_NATIVE_INSTANCES] instances;
    foreach (index, &instance : instances) {
        *instance = {
            .placement = original.placements[index],
            .pose = original.seeds[index],
            .color = original.colors[index],
        };
    }
    foreach (part : original.parts) pair.scene.remove(pair.scene.node(part.batch));
    pair.scene.remove_component(pair.crowd, AnimatedCrowd);
    model::attach_crowd(
        assets: &fixture.assets,
        scene: &pair.scene,
        node: pair.crowd,
        model: pair.model,
        capacity: CROWD_NATIVE_INSTANCES,
        pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
        instances: instances[..],
        actions_per_instance: anim::MAX_ACTIONS,
        event_capacity: 0,
    )!!;
    pair.scene.get(pair.crowd, AnimatedCrowd).inertia_enabled = true;
    model::prepare_crowd(&fixture.assets, &pair.scene, pair.crowd)!!;
    ModelTemplate* template = &fixture.assets.model(pair.model).data;
    uint root = morph ? anim::NO_ROOT_NODE : authoring_native_node(template, "root");
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        pair.scene.remove_component(pair.ordinary[source], Animator);
        Animator* animator = anim::add_animator(&pair.scene, pair.ordinary[source], { .inertia_enabled = true });
        animator.root_node = root;
        CrowdPlayer player = crowd_native_player(pair, source)!!;
        player.stop(player.state.slots[source].base_action)!!;
        player.state.slots[source].root_node = root;
    }
}

fn void save_motion_native_image(CrowdNativeImages* images, bool morph, uint frame, bool expected) @private {
    @pool() {
        String directory = env::tget_var("C3D_ANIMATION_CAPTURE_DIR") ?? "";
        if (!directory.len) return;
        String filename = string::tformat(
            "%s/motion-%s-frame-%04d-%s.rgba32f.bin",
            directory,
            morph ? "morph-cube" : "quaternius",
            frame,
            expected ? "expected" : "actual",
        );
        file::save(filename, ((char*)images.color.ptr)[:images.color.len * Vec4::size])!!;
        io::printfn("native motion capture=%s width=%s height=%s", filename, CROWD_NATIVE_WIDTH, CROWD_NATIVE_HEIGHT);
    };
}

fn void motion_native_accumulate_carrier(
    MotionNativeOracle* oracle,
    Transform actual,
    RootMotionDelta delta,
    Vec3 pivot,
    MotionNativeErrors* errors,
) @private {
    oracle.carrier.position += motion_native_rotate(oracle.carrier.rotation,
        oracle.carrier.scale * motion_native_vector(delta.translation));
    oracle.carrier.rotation = motion_native_normalize(motion_native_product(
        oracle.carrier.rotation, motion_native_rotation(delta.rotation)));
    MotionNativePose published = motion_native_pose(actual);
    errors.carrier_drift = math::max(errors.carrier_drift,
        (published.position - oracle.carrier.position).length());
    errors.carrier_rotation = math::max(errors.carrier_rotation, motion_native_log(
        motion_native_product(published.rotation, motion_native_inverse(oracle.carrier.rotation))).length());
    double[<3>] expected_pivot = oracle.carrier.position + motion_native_rotate(oracle.carrier.rotation,
        oracle.carrier.scale * motion_native_vector(pivot));
    Vec3 actual_pivot = maths::transform_point(actual.to_mat4(), pivot);
    errors.pivot_drift = math::max(errors.pivot_drift,
        (motion_native_vector(actual_pivot) - expected_pivot).length());
    errors.radius = math::max(errors.radius, published.position.length());
}

fn void check_motion_native_pair(CrowdNativePair* pair, MotionNativeErrors* errors) @private {
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    CrowdPlaybackState* playback = crowd.playback;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        ModelInstance* instance = pair.scene.get(pair.ordinary[source], ModelInstance);
        Mat4 carrier_inverse = maths::inverse_affine(pair.ordinary[source].world);
        Transform[] locals = playback.poses[(usz)source * playback.base_pose.len:playback.base_pose.len];
        foreach (index, local : locals) {
            Transform reference = instance.present_node((usz)index).local;
            assert(local.position.distance(reference.position) <= MOTION_NATIVE_POSITION_EPSILON);
            assert(local.scale.distance(reference.scale) <= MOTION_NATIVE_SCALE_EPSILON);
            assert(motion_native_log(motion_native_product(
                motion_native_rotation(local.rotation),
                motion_native_inverse(motion_native_rotation(reference.rotation)))).length()
              <= MOTION_NATIVE_ROTATION_EPSILON);
            Mat4 actual_relative = local.to_mat4();
            for (int parent = playback.parents[index]; parent >= 0; parent = playback.parents[parent]) {
                actual_relative = locals[parent].to_mat4().mul(actual_relative);
            }
            Mat4 expected_relative = carrier_inverse.mul(instance.present_node((usz)index).world);
            Vec3 actual_position = maths::transform_point(actual_relative, {});
            Vec3 expected_position = maths::transform_point(expected_relative, {});
            errors.carrier_relative = math::max(errors.carrier_relative,
                (double)actual_position.distance(expected_position));
        }
        foreach (usz mesh, node : playback.mesh_nodes) {
            float[] actual = playback.logical_weights[(usz)source * playback.mesh_nodes.len + mesh];
            float[] expected = pair.scene.get(instance.present_node(node), Mesh).morph_weights;
            assert(actual.len == expected.len);
            foreach (index, weight : actual) assert(math::abs(weight - expected[index]) <= MOTION_NATIVE_MORPH_EPSILON);
        }
    }
    assert(errors.carrier_relative <= MOTION_NATIVE_DRIFT_EPSILON);
}

fn void diagnose_motion_native_pixels(
    Vec4[] actual,
    Vec4[] expected,
    String pass,
    uint frame,
    bool morph,
    float tolerance,
) @private {
    float maximum;
    uint failed;
    int worst_x;
    int worst_y;
    for (int y = 1; y + 1 < (int)CROWD_NATIVE_HEIGHT; y++) {
        for (int x = 1; x + 1 < (int)CROWD_NATIVE_WIDTH; x++) {
            Vec4 pixel = actual[y * (int)CROWD_NATIVE_WIDTH + x];
            float closest = float::max;
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    Vec4 difference = math::abs(pixel - expected[(y + dy) * (int)CROWD_NATIVE_WIDTH + x + dx]);
                    float error = math::max(math::max(difference.x, difference.y),
                        math::max(difference.z, difference.w));
                    closest = math::min(closest, error);
                }
            }
            if (closest > tolerance) failed++;
            if (closest > maximum) {
                maximum = closest;
                worst_x = x;
                worst_y = y;
            }
        }
    }
    io::printfn("motion raster model=%s frame=%s pass=%s failing_pixels=%s max_nearest=%s worst_x=%s worst_y=%s bound=%s",
        morph ? "AnimatedMorphCube" : "Quaternius", frame, pass, failed, maximum, worst_x, worst_y, tolerance);
}

fn void run_motion_native_window(bool morph) @private {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model_id = load_crowd_native_cc0(
        fixture: &fixture,
        filename: morph ? CROWD_NATIVE_MORPH_CUBE : CROWD_NATIVE_QUATERNIUS,
        expected_hash: morph ? CROWD_NATIVE_MORPH_CUBE_SHA : CROWD_NATIVE_QUATERNIUS_SHA,
    )!!;
    crowd_native_flat_source_materials(&fixture, model_id);
    ModelTemplate* template = &fixture.assets.model(model_id).data;
    ClipId initial = morph ? template.clips[0] : crowd_native_clip_named(&fixture, model_id, "Walk_Loop")!!;
    Transform[CROWD_NATIVE_INSTANCES] placements;
    foreach (index, &placement : placements) {
        *placement = maths::TRANSFORM_IDENTITY;
        placement.position.x = ((float)index - 1) * 3;
        placement.scale = { 0.6f, 0.6f, 0.6f };
    }
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: &tracker,
        fixture: &fixture,
        pair: &pair,
        model: model_id,
        clip: initial,
        bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
        placements: placements[..],
        tinted: false,
    )!!;
    defer scene::destroy_scene(&pair.scene);
    configure_motion_native_pair(&fixture, &pair, morph);
    uint root = morph ? anim::NO_ROOT_NODE : authoring_native_node(template, "root");
    PlayDesc config;
    if (!morph) {
        config = {
            .root_motion = EXTRACT,
            .extraction = {
                .generalized = true,
                .translation_axes = { true, true, true },
                .up = { 0, 1, 0 },
                .twist = true,
            },
        };
    }
    MotionNativeOracle[CROWD_NATIVE_INSTANCES] oracles;
    foreach (index, &oracle : oracles) {
        *oracle = motion_native_oracle(mem, template, root);
        oracle.carrier = motion_native_pose(placements[index]);
        Animator* animator = pair.scene.get(pair.ordinary[index], Animator);
        CrowdPlayer player = crowd_native_player(&pair, (uint)index)!!;
        AnimationActionId ordinary = animator.play(&fixture.assets, initial, config)!!;
        AnimationActionId crowded = player.play(&fixture.assets, initial, config)!!;
        float speed = index == 1 ? -0.75f : 1;
        float time = speed < 0 ? fixture.assets.clip(initial).data.duration : 0;
        foreach (action : (Action*[2]){ animator.action(ordinary), player.action(crowded) }) {
            action.speed = speed;
            action.time = time;
        }
    }
    defer {
        foreach (&oracle : oracles) destroy_motion_native_oracle(mem, oracle);
    }
    MotionNativePose[] expected = alloc::new_array(mem, MotionNativePose, template.nodes.len);
    defer alloc::free(mem, expected.ptr);
    MotionNativeRate[] rates = alloc::new_array(mem, MotionNativeRate, template.nodes.len);
    defer alloc::free(mem, rates.ptr);
    double[] morph_expected = alloc::new_array(mem, double, oracles[0].morph_previous.len);
    defer alloc::free(mem, morph_expected.ptr);
    double[] morph_rate = alloc::new_array(mem, double, oracles[0].morph_previous.len);
    defer alloc::free(mem, morph_rate.ptr);
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    ViewDesc view_desc = render::texture_view_desc(output.target);
    view_desc.depth_prepass = true;
    view_desc.post.motion_blur = true;
    render::configure_view(&fixture.renderer, output.view, view_desc)!!;
    MotionNativeErrors errors;
    crowd_native_update(&fixture, &pair, 0);
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        Action* action = animator.action(animator.order[0]);
        motion_native_sample(
            template: template,
            clip: &fixture.assets.clip(action.clip).data,
            time: action.time,
            speed: action.speed,
            poses: expected,
            rates: rates,
            morph: morph_expected,
            morph_rate: morph_rate,
        );
        motion_native_check_and_record(
            template: template,
            instance: pair.scene.get(pair.ordinary[source], ModelInstance),
            scene: &pair.scene,
            oracle: &oracles[source],
            expected: expected,
            morph: morph_expected,
            errors: &errors,
            independent: true,
            dt: 0,
        );
    }
    uint native_captures;
    double simulated;
    uint request_ordinal;
    float[4] steps = { 1.0f / 120, 1.0f / 120, 1.0f / 120, 1.0f / 24 };
    for (uint frame = 0; frame < MOTION_NATIVE_FRAMES; frame++) {
        float dt = steps[frame % (uint)steps.len];
        bool request = frame == 120 || frame == 150 || frame == 300 || frame == 420 || frame == 450
          || frame == 600 || frame == 780 || frame == 900 || frame == 930 || frame == 1050;
        if (request) {
            request_ordinal++;
            String[4] names = { "Jog_Fwd_Loop", "Turn90_L", "Turn90_R", "Walk_Loop" };
            ClipId clip = morph ? template.clips[0]
              : crowd_native_clip_named(&fixture, model_id, names[(request_ordinal - 1) % (uint)names.len])!!;
            for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
                Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
                CrowdPlayer player = crowd_native_player(&pair, source)!!;
                AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
                targets[0].clip = clip;
                targets[0].play = config;
                targets[0].speed = source == 1 ? -0.75f : (request_ordinal % 2 == 0 ? 1.25f : 1.0f);
                targets[0].start_time = targets[0].speed < 0 ? fixture.assets.clip(clip).data.duration
                  : (morph ? (request_ordinal % 2 == 0 ? 0.75f : 0.125f) : 0);
                targets[0].loop = morph || source == 2 || (request_ordinal - 1) % 4 == 0;
                motion_native_sample(
                    template: template,
                    clip: &fixture.assets.clip(clip).data,
                    time: targets[0].start_time,
                    speed: targets[0].speed,
                    poses: expected,
                    rates: rates,
                    morph: morph_expected,
                    morph_rate: morph_rate,
                    onset: true,
                );
                motion_native_capture_request(
                    oracle: &oracles[source],
                    incoming: expected,
                    rates: rates,
                    morph: morph_expected,
                    morph_rate: morph_rate,
                );
                animator.inertialize(&fixture.assets, {
                    .duration = MOTION_NATIVE_TRANSITION_SECONDS,
                    .actions = targets[..],
                })!!;
                player.inertialize(&fixture.assets, {
                    .duration = MOTION_NATIVE_TRANSITION_SECONDS,
                    .actions = targets[..],
                })!!;
                errors.requests++;
            }
        }
        bool playing = !(frame >= 360 && frame < 390) && !(frame >= 720 && frame < 750);
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
            CrowdPlayer player = crowd_native_player(&pair, source)!!;
            animator.action(animator.order[0]).playing = playing;
            player.action(player.state.slots[source].order[0]).playing = playing;
        }
        sz acquisitions = tracker.total_allocation_count();
        crowd_native_update(&fixture, &pair, dt);
        assert(tracker.total_allocation_count() == acquisitions, "Inertial/generalized update allocated owner storage");
        AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
            Action* action = animator.action(animator.order[0]);
            AnimationClip* clip = &fixture.assets.clip(action.clip).data;
            float speed = action.playing && (action.loop || action.time < clip.duration) ? action.speed : 0;
            motion_native_sample(
                template: template,
                clip: clip,
                time: action.time,
                speed: speed,
                poses: expected,
                rates: rates,
                morph: morph_expected,
                morph_rate: morph_rate,
            );
            motion_native_check_and_record(
                template: template,
                instance: pair.scene.get(pair.ordinary[source], ModelInstance),
                scene: &pair.scene,
                oracle: &oracles[source],
                expected: expected,
                morph: morph_expected,
                errors: &errors,
                independent: true,
                dt: (double)dt,
            );
            anim::apply_root_motion(pair.ordinary[source], animator.root_motion);
            motion_native_accumulate_carrier(
                oracle: &oracles[source],
                actual: pair.ordinary[source].local,
                delta: animator.root_motion,
                pivot: root == anim::NO_ROOT_NODE ? (Vec3){} : template.nodes[root].local.position,
                errors: &errors,
            );
        }
        pair.scene.apply_crowd_root_motion(crowd);
        pair.scene.update_world();
        check_motion_native_pair(&pair, &errors);
        assert(errors.position <= MOTION_NATIVE_POSITION_EPSILON);
        assert(errors.rotation <= MOTION_NATIVE_ROTATION_EPSILON);
        assert(errors.scale <= MOTION_NATIVE_SCALE_EPSILON);
        assert(errors.morph <= MOTION_NATIVE_MORPH_EPSILON);
        assert(errors.carrier_drift <= MOTION_NATIVE_DRIFT_EPSILON && errors.pivot_drift <= MOTION_NATIVE_DRIFT_EPSILON);
        assert(errors.carrier_rotation <= MOTION_NATIVE_ROTATION_EPSILON);
        pair.crowd.visible = true;
        pair.references.visible = false;
        Vec3 center;
        foreach (placement : crowd.placements[:crowd.count]) center += placement.position / (float)crowd.count;
        *pair.scene.get(pair.camera, Camera) = camera::orthographic((float)(6 + errors.radius), 0.1f, 100);
        pair.camera.local.position = center + (Vec3){ 0, morph ? 0.0f : 1.0f, 15 };
        pair.scene.update_world();
        fixture.renderer.begin_frame({ .time = simulated, .delta = dt })!!;
        fixture.renderer.render_view(&pair.scene, pair.camera, output.view)!!;
        fixture.renderer.finish_view(output.view)!!;
        fixture.renderer.end_frame()!!;
        simulated += dt;
        if (frame == 0 || frame == 150 || frame == 450 || frame + 1 == MOTION_NATIVE_FRAMES) {
            capture_crowd_native(
                fixture: &fixture,
                pair: &pair,
                probe: &output.probe,
                output: output.target,
                view: output.view,
                crowd_visible: true,
                images: &output.actual,
            )!!;
            capture_crowd_native(
                fixture: &fixture,
                pair: &pair,
                probe: &output.probe,
                output: output.target,
                view: output.view,
                crowd_visible: false,
                images: &output.expected,
            )!!;
            save_motion_native_image(
                images: &output.actual,
                morph: morph,
                frame: frame,
                expected: false,
            );
            save_motion_native_image(
                images: &output.expected,
                morph: morph,
                frame: frame,
                expected: true,
            );
            io::printfn("motion raster counters frame=%s parts=%s crowd_draws=%s ordinary_draws=%s tested=%s visible=%s instances=%s",
                frame, crowd.parts.len, output.actual.stats.draws, output.expected.stats.draws,
                output.actual.stats.instances_tested, output.actual.stats.instances_visible, output.actual.stats.instances);
            diagnose_motion_native_pixels(
                actual: output.actual.color,
                expected: output.expected.color,
                pass: "crowd-to-ordinary color",
                frame: frame,
                morph: morph,
                tolerance: CROWD_NATIVE_COLOR_TOLERANCE,
            );
            diagnose_motion_native_pixels(
                actual: output.expected.color,
                expected: output.actual.color,
                pass: "ordinary-to-crowd color",
                frame: frame,
                morph: morph,
                tolerance: CROWD_NATIVE_COLOR_TOLERANCE,
            );
            diagnose_motion_native_pixels(
                actual: output.actual.depth,
                expected: output.expected.depth,
                pass: "crowd-to-ordinary depth",
                frame: frame,
                morph: morph,
                tolerance: CROWD_NATIVE_DEPTH_TOLERANCE,
            );
            diagnose_motion_native_pixels(
                actual: output.expected.depth,
                expected: output.actual.depth,
                pass: "ordinary-to-crowd depth",
                frame: frame,
                morph: morph,
                tolerance: CROWD_NATIVE_DEPTH_TOLERANCE,
            );
            check_crowd_native_parity(&output.actual, &output.expected, false);
            native_captures++;
        }
    }
    assert(simulated >= 20 && errors.requests == 30 && errors.checked_nodes > 0);
    if (morph) assert(errors.checked_morphs == (MOTION_NATIVE_FRAMES + 1) * CROWD_NATIVE_INSTANCES * 2);
    io::printfn("motion native morph=%s frames=%s seconds=%s requests=%s captures=%s", morph,
        MOTION_NATIVE_FRAMES, simulated, errors.requests, native_captures);
    io::printfn("independent non-top-level local position=%s rotation=%s scale=%s full_morph=%s checked_nodes=%s",
        errors.position, errors.rotation, errors.scale, errors.morph, errors.checked_nodes);
    io::printfn("carrier_relative=%s published-delta accumulation drift=%s pivot=%s rotation=%s radius=%s bytes=%s",
        errors.carrier_relative, errors.carrier_drift, errors.pivot_drift, errors.carrier_rotation,
        errors.radius, tracker.allocated());
    check_crowd_native_validation(&fixture.renderer);
}

fn void test_animation_authoring_motion_native_quaternius_turns_reverse_loops_and_interrupted_requests() @test {
    run_motion_native_window(false);
}

fn void test_animation_authoring_motion_native_morph_cube_full_logical_weights_and_interrupted_requests() @test {
    run_motion_native_window(true);
}

fn void configure_layered_inertial_reference(
    Fixture* fixture,
    CrowdNativePair* pair,
    AuthoringNativeControls* controls,
    WeightedJointMask* mask,
    ClipId scale_clip,
    AdditiveScaleMode scale_mode,
) @private {
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        CrowdPlayer player = crowd_native_player(pair, source)!!;
        foreach (&space : animator.blend_spaces_2d) {
            if (space.count) animator.stop_blend_space_2d(space)!!;
        }
        foreach (&space : player.state.slots[source].spaces_2d) {
            if (space.count) player.stop_blend_space_2d(space)!!;
        }
    }
    crowd_native_stop_all(pair)!!;
    ClipId[9] clips;
    foreach (index, name : AUTHORING_NATIVE_CLIPS) {
        clips[index] = crowd_native_clip_named(fixture, pair.model, name)!!;
    }
    ClipId upper_clip = crowd_native_clip_named(fixture, pair.model, "Pistol_Idle_Loop")!!;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        CrowdPlayer player = crowd_native_player(pair, source)!!;
        controls.ordinary[source] = animator.add_blend_space_2d(
            assets: &fixture.assets,
            clips: clips[..],
            coordinates: AUTHORING_NATIVE_POINTS[..],
            triangles: AUTHORING_NATIVE_TRIANGLES[..],
        )!!;
        controls.crowd[source] = player.add_blend_space_2d(
            assets: &fixture.assets,
            clips: clips[..],
            coordinates: AUTHORING_NATIVE_POINTS[..],
            triangles: AUTHORING_NATIVE_TRIANGLES[..],
        )!!;
        PlayDesc upper = { .layer = 1, .weighted_mask = mask };
        controls.ordinary_overlay[source] = animator.action(animator.play(&fixture.assets, upper_clip, upper)!!);
        controls.crowd_overlay[source] = player.action(player.play(&fixture.assets, upper_clip, upper)!!);
        PlayDesc scale = { .layer = 2, .additive = true, .additive_scale = scale_mode };
        controls.ordinary_scale[source] = animator.action(animator.play(&fixture.assets, scale_clip, scale)!!);
        controls.crowd_scale[source] = player.action(player.play(&fixture.assets, scale_clip, scale)!!);
        foreach (action : (Action*[2]){ controls.ordinary_overlay[source], controls.crowd_overlay[source] }) {
            action.speed = -0.75f;
            action.weight = 0.6f;
        }
        foreach (action : (Action*[2]){ controls.ordinary_scale[source], controls.crowd_scale[source] }) action.weight = 0.5f;
    }
}

fn void request_layered_inertial_native(
    Fixture* fixture,
    CrowdNativePair* pair,
    AuthoringNativeControls* controls,
    WeightedJointMask* mask,
    ClipId scale_clip,
    AdditiveScaleMode scale_mode,
) @private {
    ClipId[9] clips;
    foreach (index, name : AUTHORING_NATIVE_CLIPS) {
        clips[index] = crowd_native_clip_named(fixture, pair.model, name)!!;
    }
    ClipId upper_clip = crowd_native_clip_named(fixture, pair.model, "Pistol_Idle_Loop")!!;
    AnimationTargetDesc[11] targets;
    for (uint index = 0; index < clips.len; index++) {
        targets[index] = anim::ANIMATION_TARGET_DEFAULT;
        targets[index].clip = clips[index];
    }
    targets[9] = anim::ANIMATION_TARGET_DEFAULT;
    targets[9].clip = upper_clip;
    targets[9].play = { .layer = 1, .weighted_mask = mask };
    targets[9].speed = -0.75f;
    targets[9].weight = 0.6f;
    targets[10] = anim::ANIMATION_TARGET_DEFAULT;
    targets[10].clip = scale_clip;
    targets[10].play = { .layer = 2, .additive = true, .additive_scale = scale_mode };
    targets[10].weight = 0.5f;
    CrowdSpaceAuthoring[1] spaces = { {
        .actions = { 0, 1, 2, 3, 4, 5, 6, 7, 8 },
        .weight = 1,
        .speed = 1,
        .playing = true,
        .kind = TWO_DIMENSIONAL,
        .points = AUTHORING_NATIVE_POINTS[..],
        .triangles = AUTHORING_NATIVE_TRIANGLES[..],
    } };
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        CrowdPlayer player = crowd_native_player(pair, source)!!;
        AnimationActionId old_ordinary = animator.order[0];
        AnimationActionId old_crowded = player.state.slots[source].order[0];
        animator.inertialize(&fixture.assets, { .duration = 0.6f, .actions = targets[..], .spaces = spaces[..] })!!;
        player.inertialize(&fixture.assets, { .duration = 0.6f, .actions = targets[..], .spaces = spaces[..] })!!;
        assert(@catch(animator.try_action(old_ordinary)) == c3d::INVALID_ID);
        assert(@catch(player.try_action(old_crowded)) == c3d::INVALID_ID);
        assert(animator.event_count == 0);
        CrowdPlaybackSlot* slot = &player.state.slots[source];
        assert(animator.action_count == 11 && slot.action_count == 11);
        controls.ordinary[source] = &animator.blend_spaces_2d[0];
        controls.crowd[source] = &slot.spaces_2d[0];
        controls.ordinary_overlay[source] = animator.action(animator.order[9]);
        controls.crowd_overlay[source] = slot.actions.get(slot.order[9]);
        controls.ordinary_scale[source] = animator.action(animator.order[10]);
        controls.crowd_scale[source] = slot.actions.get(slot.order[10]);
        assert(controls.ordinary_overlay[source].weighted_mask == mask.nodes);
        assert(controls.crowd_overlay[source].weighted_mask == mask.nodes);
        assert(controls.ordinary_overlay[source].weighted_mask.ptr != mask.nodes.ptr);
        assert(controls.crowd_overlay[source].weighted_mask.ptr != mask.nodes.ptr);
    }
}

fn void drive_layered_inertial_native(AuthoringNativeControls* controls, uint frame) @private {
    uint interval = frame / 120;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        Vec2 parameter = AUTHORING_NATIVE_PARAMETERS[(interval + source) % (uint)AUTHORING_NATIVE_PARAMETERS.len];
        float speed = source == 1 ? -0.75f : (interval >= 5 ? -1.25f : 1.0f);
        bool playing = interval != 2 && interval != 7;
        float weight = interval == 3 ? 0 : (interval == 4 ? 0.25f : 1);
        foreach (space : (BlendSpace2D*[2]){ controls.ordinary[source], controls.crowd[source] }) {
            space.parameter = parameter;
            space.speed = speed;
            space.playing = playing;
            space.weight = weight;
        }
        foreach (action : (Action*[2]){ controls.ordinary_overlay[source], controls.crowd_overlay[source] }) {
            action.playing = playing;
        }
        foreach (action : (Action*[2]){ controls.ordinary_scale[source], controls.crowd_scale[source] }) {
            action.playing = playing;
        }
    }
}

fn void compare_layered_inertial_reference(
    CrowdNativePair* actual,
    CrowdNativePair* reference,
    MotionNativeErrors* errors,
) @private {
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        ModelInstance* first = actual.scene.get(actual.ordinary[source], ModelInstance);
        ModelInstance* second = reference.scene.get(reference.ordinary[source], ModelInstance);
        foreach (usz index, baseline : first.base_pose) {
            Transform observed = first.present_node(index).local;
            Transform expected = second.present_node(index).local;
            errors.position = math::max(errors.position, (double)observed.position.distance(expected.position));
            errors.scale = math::max(errors.scale, (double)observed.scale.distance(expected.scale));
            errors.rotation = math::max(errors.rotation, motion_native_log(motion_native_product(
                motion_native_rotation(observed.rotation),
                motion_native_inverse(motion_native_rotation(expected.rotation)))).length());
        }
        foreach (node : first.mesh_nodes) {
            float[] observed = actual.scene.get(first.present_node(node), Mesh).morph_weights;
            float[] expected = reference.scene.get(second.present_node(node), Mesh).morph_weights;
            foreach (index, value : observed) {
                errors.morph = math::max(errors.morph, math::abs((double)value - expected[index]));
            }
        }
    }
    assert(errors.position <= MOTION_NATIVE_POSITION_EPSILON);
    assert(errors.rotation <= MOTION_NATIVE_ROTATION_EPSILON);
    assert(errors.scale <= MOTION_NATIVE_SCALE_EPSILON);
    assert(errors.morph <= MOTION_NATIVE_MORPH_EPSILON);
}

fn void test_animation_authoring_motion_native_layered_planar_masks_scale_and_repeated_full_requests() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model_id = load_crowd_native_cc0(
        fixture: &fixture,
        filename: CROWD_NATIVE_QUATERNIUS,
        expected_hash: CROWD_NATIVE_QUATERNIUS_SHA,
    )!!;
    crowd_native_flat_source_materials(&fixture, model_id);
    ModelTemplate* template = &fixture.assets.model(model_id).data;
    ClipId first = crowd_native_clip_named(&fixture, model_id, "Idle_Loop")!!;
    ClipId scale = authoring_native_scale_clip(&fixture, model_id)!!;
    WeightedJointMask mask = anim::create_feathered_joint_mask(
        allocator: mem,
        assets: &fixture.assets,
        model: model_id,
        names: { "DEF-spine.001" },
        weights: { 0.8f },
        depths: { 2 },
    )!!;
    defer anim::destroy_weighted_joint_mask(&mask);
    foreach (index, name : AUTHORING_NATIVE_CLIPS) {
        ClipId clip = crowd_native_clip_named(&fixture, model_id, name)!!;
        fixture.assets.set_clip_events(clip, {
            { .time = 0, .id = (uint)index },
            { .time = fixture.assets.clip(clip).data.duration * 0.5f, .id = 100 + (uint)index },
        })!!;
    }
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    CrowdNativePair enabled;
    create_crowd_native_pair(
        allocator: &tracker,
        fixture: &fixture,
        pair: &enabled,
        model: model_id,
        clip: first,
        bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
        placements: placements[..],
        tinted: false,
    )!!;
    defer scene::destroy_scene(&enabled.scene);
    configure_motion_native_pair(&fixture, &enabled, false);
    CrowdNativePair reference;
    create_crowd_native_pair(
        allocator: &tracker,
        fixture: &fixture,
        pair: &reference,
        model: model_id,
        clip: first,
        bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
        placements: placements[..],
        tinted: false,
    )!!;
    defer scene::destroy_scene(&reference.scene);
    AuthoringNativeControls actual_controls;
    AuthoringNativeControls reference_controls;
    configure_layered_inertial_reference(
        fixture: &fixture,
        pair: &enabled,
        controls: &actual_controls,
        mask: &mask,
        scale_clip: scale,
        scale_mode: MULTIPLICATIVE,
    );
    configure_layered_inertial_reference(
        fixture: &fixture,
        pair: &reference,
        controls: &reference_controls,
        mask: &mask,
        scale_clip: scale,
        scale_mode: MULTIPLICATIVE,
    );
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    ViewDesc desc = render::texture_view_desc(output.target);
    desc.depth_prepass = true;
    desc.post.motion_blur = true;
    render::configure_view(&fixture.renderer, output.view, desc)!!;
    *enabled.scene.get(enabled.camera, Camera) = camera::orthographic(6, 0.1f, 100);
    enabled.camera.local.position = { 0, 1, 12 };
    MotionNativeErrors parity;
    MotionNativeErrors settled;
    uint requests;
    uint target_events;
    uint captures;
    uint settled_frames;
    uint since_request = 1200;
    for (uint frame = 0; frame < AUTHORING_NATIVE_FRAMES; frame++) {
        bool request = frame == 120 || frame == 150 || frame == 300 || frame == 420 || frame == 450
          || frame == 600 || frame == 780 || frame == 900 || frame == 930 || frame == 1050;
        if (request) {
            AdditiveScaleMode mode = requests % 2 == 0 ? DIFFERENCE : MULTIPLICATIVE;
            request_layered_inertial_native(
                fixture: &fixture,
                pair: &enabled,
                controls: &actual_controls,
                mask: &mask,
                scale_clip: scale,
                scale_mode: mode,
            );
            configure_layered_inertial_reference(
                fixture: &fixture,
                pair: &reference,
                controls: &reference_controls,
                mask: &mask,
                scale_clip: scale,
                scale_mode: mode,
            );
            requests++;
            since_request = 0;
        }
        drive_layered_inertial_native(&actual_controls, frame);
        drive_layered_inertial_native(&reference_controls, frame);
        sz acquisitions = tracker.total_allocation_count();
        crowd_native_update(&fixture, &enabled, AUTHORING_NATIVE_DT);
        crowd_native_update(&fixture, &reference, AUTHORING_NATIVE_DT);
        assert(tracker.total_allocation_count() == acquisitions);
        check_motion_native_pair(&enabled, &parity);
        since_request++;
        if (since_request > 40) {
            compare_layered_inertial_reference(&enabled, &reference, &settled);
            settled_frames++;
        }
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Animator* animator = enabled.scene.get(enabled.ordinary[source], Animator);
            assert(animator.root_motion.translation == (Vec3){});
            assert(animator.root_motion.rotation.v == quaternion::IDENTITY{float}.v);
            foreach (event : animator.events[:animator.event_count]) {
                Action* target = animator.try_action(event.action)!!;
                assert(c3d::same_id(target.clip, event.clip));
                assert(target.root_motion == KEEP);
                target_events++;
            }
            RootMotionDelta crowded = enabled.scene.get(enabled.crowd, AnimatedCrowd).playback.slots[source].root_motion;
            assert(crowded.translation == (Vec3){} && crowded.rotation.v == quaternion::IDENTITY{float}.v);
        }
        enabled.crowd.visible = true;
        enabled.references.visible = false;
        enabled.scene.update_world();
        fixture.renderer.begin_frame({ .time = (double)frame * AUTHORING_NATIVE_DT, .delta = AUTHORING_NATIVE_DT })!!;
        fixture.renderer.render_view(&enabled.scene, enabled.camera, output.view)!!;
        fixture.renderer.finish_view(output.view)!!;
        fixture.renderer.end_frame()!!;
        if (frame == 0 || frame == 150 || frame == 450 || frame + 1 == AUTHORING_NATIVE_FRAMES) {
            capture_crowd_native(
                fixture: &fixture,
                pair: &enabled,
                probe: &output.probe,
                output: output.target,
                view: output.view,
                crowd_visible: true,
                images: &output.actual,
            )!!;
            capture_crowd_native(
                fixture: &fixture,
                pair: &enabled,
                probe: &output.probe,
                output: output.target,
                view: output.view,
                crowd_visible: false,
                images: &output.expected,
            )!!;
            save_motion_native_image(
                images: &output.actual,
                morph: false,
                frame: frame + AUTHORING_NATIVE_FRAMES,
                expected: false,
            );
            save_motion_native_image(
                images: &output.expected,
                morph: false,
                frame: frame + AUTHORING_NATIVE_FRAMES,
                expected: true,
            );
            check_crowd_native_parity(&output.actual, &output.expected, false);
            captures++;
        }
    }
    assert(requests == 10 && target_events > 0 && settled_frames > 0);
    io::printfn("layered inertial frames=%s seconds=20 requests=%s targets=11 group=9 captures=%s settled_frames=%s target_events=%s",
        AUTHORING_NATIVE_FRAMES, requests * CROWD_NATIVE_INSTANCES, captures, settled_frames, target_events);
    io::printfn("disabled-inertia KEEP settled reference position=%s rotation=%s scale=%s morph=%s active_pair_relative=%s root_delta_export=none",
        settled.position, settled.rotation, settled.scale, settled.morph, parity.carrier_relative);
    check_crowd_native_validation(&fixture.renderer);
}
