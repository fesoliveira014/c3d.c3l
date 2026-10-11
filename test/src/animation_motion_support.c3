module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;

struct MotionTestAllocator (Allocator) @private {
    Allocator backing;
    void* pointer;
    sz bytes;
    sz alignment;
    uint attempts;
    uint acquisitions;
    uint resizes;
    uint releases;
    uint outstanding;
    uint failure;
}

struct MotionTestMatrix @private {
    double[4][4] cells;
}

fn void*? MotionTestAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.acquisitions++;
    self.bytes = size;
    self.alignment = alignment;
    if (++self.attempts == self.failure) return mem::OUT_OF_MEMORY~;

    self.pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return self.pointer;
}

fn void*? MotionTestAllocator.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    self.resizes++;
    if (++self.attempts == self.failure) return mem::OUT_OF_MEMORY~;

    return self.backing.resize(pointer, size, alignment);
}

fn void MotionTestAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.releases++;
    self.outstanding--;
}

fn void create_inertial_owner(LayerFixture* owner, Allocator allocator = mem, bool inertia_enabled = true) @private {
    create_layer_fixture(owner, allocator);
    owner.scene.remove_component(owner.root, Animator);
    owner.animator = anim::add_animator(&owner.scene, owner.root, { .inertia_enabled = inertia_enabled });
}

fn Transform inertial_owner_pose(LayerFixture* owner, uint node = 3) @private {
    ModelInstance* instance = owner.scene.get(owner.root, ModelInstance);
    return instance.present_node(node).local;
}

fn InertialRow* inertial_owner_row(LayerFixture* owner) @private {
    return &owner.animator.inertial_storage.rows[0];
}

fn ClipId inertial_owner_clip(
    LayerFixture* owner,
    TargetPath path,
    Interpolation interpolation,
    float[] times,
    float[] values,
    uint node,
) @private {
    Track[1] tracks = { make_track(
        path: path,
        interpolation: interpolation,
        times: times,
        values: values,
    ) };
    uint[1] targets = { node };
    return add_clip(
        assets: &owner.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: times[times.len - 1],
    );
}

fn ClipId inertial_owner_translation(
    LayerFixture* owner,
    Vec3 start,
    Vec3 end,
    uint node = 3,
) @private {
    float[2] times = { 0, 1 };
    float[6] values = { start.x, start.y, start.z, end.x, end.y, end.z };
    return inertial_owner_clip(
        owner: owner,
        path: TargetPath.TRANSLATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: values[..],
        node: node,
    );
}

fn MotionTestMatrix motion_test_identity() @private {
    MotionTestMatrix result;
    for (uint axis = 0; axis < 4; axis++) result.cells[axis][axis] = 1;
    return result;
}

fn MotionTestMatrix motion_test_product(MotionTestMatrix left, MotionTestMatrix right) @private {
    MotionTestMatrix result;
    for (uint row = 0; row < 4; row++) for (uint column = 0; column < 4; column++) {
        for (uint axis = 0; axis < 4; axis++) {
            result.cells[row][column] += left.cells[row][axis] * right.cells[axis][column];
        }
    }
    return result;
}

fn double[<3>] motion_test_point(MotionTestMatrix matrix, double[<3>] point) @private {
    double[<3>] result;
    for (uint row = 0; row < 3; row++) {
        result[row] = matrix.cells[row][3];
        for (uint axis = 0; axis < 3; axis++) result[row] += matrix.cells[row][axis] * point[axis];
    }
    return result;
}

fn MotionTestMatrix motion_test_rigid_inverse(MotionTestMatrix matrix) @private {
    MotionTestMatrix result = motion_test_identity();
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        result.cells[row][column] = matrix.cells[column][row];
        result.cells[row][3] -= matrix.cells[column][row] * matrix.cells[column][3];
    }
    return result;
}

fn MotionTestMatrix motion_test_rodrigues(double[<3>] axis, double angle) @private {
    MotionTestMatrix result = motion_test_identity();
    double[3][3] skew = {
        { 0, -axis.z, axis.y },
        { axis.z, 0, -axis.x },
        { -axis.y, axis.x, 0 },
    };
    double cosine = math::cos(angle);
    double sine = math::sin(angle);
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        result.cells[row][column] = (row == column ? cosine : 0)
          + (1 - cosine) * axis[row] * axis[column] + sine * skew[row][column];
    }
    return result;
}

fn MotionTestMatrix motion_test_local(Transform local) @private {
    double[<4>] rotation = { local.rotation.v.x, local.rotation.v.y, local.rotation.v.z, local.rotation.v.w };
    rotation /= rotation.length();
    double x = rotation.x;
    double y = rotation.y;
    double z = rotation.z;
    double w = rotation.w;
    MotionTestMatrix result = { .cells = {
        { 1 - 2*y*y - 2*z*z, 2*x*y - 2*z*w, 2*x*z + 2*y*w, local.position.x },
        { 2*x*y + 2*z*w, 1 - 2*x*x - 2*z*z, 2*y*z - 2*x*w, local.position.y },
        { 2*x*z - 2*y*w, 2*y*z + 2*x*w, 1 - 2*x*x - 2*y*y, local.position.z },
        { 0, 0, 0, 1 },
    } };
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        result.cells[row][column] *= local.scale[column];
    }
    return result;
}

fn MotionTestMatrix motion_test_motion(GeneralizedMotion motion, double[<3>] up) @private {
    MotionTestMatrix result = motion_test_rodrigues(up, motion.twist);
    for (uint axis = 0; axis < 3; axis++) result.cells[axis][3] = motion.translation[axis];
    return result;
}

fn MotionTestMatrix motion_test_frame(GeneralizedMotionFrame frame) @private {
    double[<3>] axis = { frame.rotation.v.x, frame.rotation.v.y, frame.rotation.v.z };
    double length = axis.length();
    MotionTestMatrix result = length == 0 ? motion_test_identity()
      : motion_test_rodrigues(axis / length, 2 * math::atan2(length, frame.rotation.v.w));
    for (uint row = 0; row < 3; row++) {
        for (uint column = 0; column < 3; column++) result.cells[row][column] *= frame.scale;
        result.cells[row][3] = frame.position[row];
    }
    return result;
}

fn void motion_test_worlds(NodeTemplate[] nodes, Transform[] pose, MotionTestMatrix[] worlds) @private {
    foreach (index, node : nodes) {
        MotionTestMatrix local = motion_test_local(pose[index]);
        worlds[index] = node.parent < 0 ? local : motion_test_product(worlds[node.parent], local);
    }
}
