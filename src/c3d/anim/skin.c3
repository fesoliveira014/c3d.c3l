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
 @return? c3d::INVALID_ARGUMENT
 @require output.len == source.positions.len && source.positions.len > 0
 @require source.joints.len == source.positions.len && source.weights.len == source.positions.len && palette.len > 0
*>
fn void? evaluate_skin_positions(
    Vec3[] output,
    Geometry* source,
    float[<4>][4][] palette,
    Mat4 world,
) {
    foreach (index, position : source.positions) {
        Vec4 weights = source.weights[index];
        ushort[<4>] joints = source.joints[index];
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
        Vec3 transformed = maths::transform_point(world, local);
        if (!skin_vec3_finite(transformed)) return c3d::INVALID_ARGUMENT~;
        output[index] = transformed;
    }
}

fn bool skin_vec3_finite(Vec3 v) @local {
    return math::is_finite(v.x) && math::is_finite(v.y) && math::is_finite(v.z);
}
