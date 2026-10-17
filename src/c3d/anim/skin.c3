module c3d::anim;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import std::math;

<*
 Mesh-space joint matrices of the binding under the current joint poses.
 @param [out] output : "One entry per joint; written only."
 @param [&in] mesh_node : "World matrix as left by the last update."
 @param [&in] binding : "Live joints."
 @param origin : "Shared absolute origin before mesh-local composition."
 @require output.len == binding.joints.len && inverse_bind.len >= binding.joints.len
*>
fn void evaluate_skin_palette(
    float[<4>][4][] output,
    Node* mesh_node,
    SkinBinding* binding,
    Mat4[] inverse_bind,
    Vec3 origin = {},
) {
    Mat4 inverse_mesh = maths::inverse_affine(maths::rebase(mesh_node.world, origin));
    foreach (index, joint : binding.joints) {
        output[index] = bitcast(
            inverse_mesh.mul(maths::rebase(joint.world, origin)).mul(inverse_bind[index]),
            float[<4>][4],
        );
    }
}

<*
 Evaluate world-space skinned vertex positions using the shader's four-weight palette convention.
 @param [out] output : "Receives one world-space position per source vertex."
 @param [&in] source : "CPU geometry with positions, joints and weights."
 @param palette : "Float joint palette matrices."
 @param world : "Finite affine world matrix."
 @return? c3d::INVALID_ARGUMENT, c3d::ASSET_DATA_UNAVAILABLE
*>
fn void? evaluate_skin_positions(
    Vec3[] output,
    Geometry* source,
    float[<4>][4][] palette,
    Mat4 world,
) {
    if (!source) return c3d::INVALID_ARGUMENT~;
    if (!source.positions.len || !source.joints.len || !source.weights.len) {
        return c3d::ASSET_DATA_UNAVAILABLE~;
    }
    if (output.len != source.positions.len
      || source.joints.len != source.positions.len
      || source.weights.len != source.positions.len
      || !palette.len
      || !skin_affine_finite(world)) {
        return c3d::INVALID_ARGUMENT~;
    }
    foreach (&matrix : palette) {
        if (!skin_palette_finite(*matrix)) return c3d::INVALID_ARGUMENT~;
    }

    foreach (index, position : source.positions) {
        Vec4 weights = source.weights[index];
        ushort[<4>] joints = source.joints[index];
        if (!skin_vec3_finite(position) || !skin_vec4_finite(weights)) return c3d::INVALID_ARGUMENT~;
        if ((usz)joints.x >= palette.len
          || (usz)joints.y >= palette.len
          || (usz)joints.z >= palette.len
          || (usz)joints.w >= palette.len) {
            return c3d::INVALID_ARGUMENT~;
        }

        float[<4>][4] m0 = palette[joints.x];
        float[<4>][4] m1 = palette[joints.y];
        float[<4>][4] m2 = palette[joints.z];
        float[<4>][4] m3 = palette[joints.w];
        float[<4>][4] skin = {
            weights.x * m0[0] + weights.y * m1[0] + weights.z * m2[0] + weights.w * m3[0],
            weights.x * m0[1] + weights.y * m1[1] + weights.z * m2[1] + weights.w * m3[1],
            weights.x * m0[2] + weights.y * m1[2] + weights.z * m2[2] + weights.w * m3[2],
            weights.x * m0[3] + weights.y * m1[3] + weights.z * m2[3] + weights.w * m3[3],
        };
        float[<4>] local4 = skin[0] * position.x + skin[1] * position.y + skin[2] * position.z + skin[3];
        Vec3 local = { local4.x, local4.y, local4.z };
        if (!skin_vec3_finite(local)) return c3d::INVALID_ARGUMENT~;

        Vec3 transformed = maths::transform_point(world, local);
        if (!skin_vec3_finite(transformed)) return c3d::INVALID_ARGUMENT~;
        output[index] = transformed;
    }
}

fn bool skin_vec3_finite(Vec3 v) @local {
    return math::is_finite(v.x) && math::is_finite(v.y) && math::is_finite(v.z);
}

fn bool skin_vec4_finite(Vec4 v) @local {
    return math::is_finite(v.x) && math::is_finite(v.y) && math::is_finite(v.z) && math::is_finite(v.w);
}

fn bool skin_column_finite(float[<4>] col) @local {
    return math::is_finite(col.x) && math::is_finite(col.y) && math::is_finite(col.z) && math::is_finite(col.w);
}

fn bool skin_palette_finite(float[<4>][4] matrix) @local {
    return skin_column_finite(matrix[0])
      && skin_column_finite(matrix[1])
      && skin_column_finite(matrix[2])
      && skin_column_finite(matrix[3]);
}

fn bool skin_affine_finite(Mat4 world) @local {
    return math::is_finite(world.m00) && math::is_finite(world.m01) && math::is_finite(world.m02) && math::is_finite(world.m03)
      && math::is_finite(world.m10) && math::is_finite(world.m11) && math::is_finite(world.m12) && math::is_finite(world.m13)
      && math::is_finite(world.m20) && math::is_finite(world.m21) && math::is_finite(world.m22) && math::is_finite(world.m23)
      && world.m30 == 0 && world.m31 == 0 && world.m32 == 0 && world.m33 == 1;
}
