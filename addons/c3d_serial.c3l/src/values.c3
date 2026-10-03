module c3d::serial;

import c3d;
import c3d::maths;
import std::math;

<* Append Vec2 components in field order. *>
fn void Writer.write_vec2(&self, Vec2 value) {
    self.write_float(value.x);
    self.write_float(value.y);
}

<*
 Read Vec2 components in field order.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn Vec2? Reader.read_vec2(&self) {
    Vec2 value;
    value.x = self.read_float()!;
    value.y = self.read_float()!;
    return value;
}

<* Append Vec3 components in field order. *>
fn void Writer.write_vec3(&self, Vec3 value) {
    self.write_float(value.x);
    self.write_float(value.y);
    self.write_float(value.z);
}

<*
 Read Vec3 components in field order.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn Vec3? Reader.read_vec3(&self) {
    Vec3 value;
    value.x = self.read_float()!;
    value.y = self.read_float()!;
    value.z = self.read_float()!;
    return value;
}

<* Append Vec4 components in field order. *>
fn void Writer.write_vec4(&self, Vec4 value) {
    self.write_float(value.x);
    self.write_float(value.y);
    self.write_float(value.z);
    self.write_float(value.w);
}

<*
 Read Vec4 components in field order.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn Vec4? Reader.read_vec4(&self) {
    Vec4 value;
    value.x = self.read_float()!;
    value.y = self.read_float()!;
    value.z = self.read_float()!;
    value.w = self.read_float()!;
    return value;
}

<* Append Quat components in field order. *>
fn void Writer.write_quat(&self, Quat value) {
    self.write_float(value.v.x);
    self.write_float(value.v.y);
    self.write_float(value.v.z);
    self.write_float(value.v.w);
}

<*
 Read Quat components in field order.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn Quat? Reader.read_quat(&self) {
    Quat value;
    value.v.x = self.read_float()!;
    value.v.y = self.read_float()!;
    value.v.z = self.read_float()!;
    value.v.w = self.read_float()!;
    return value;
}

<* Append matrix columns in column-major order. *>
fn void Writer.write_mat4(&self, Mat4 value) {
    self.write_float(value.m00);
    self.write_float(value.m10);
    self.write_float(value.m20);
    self.write_float(value.m30);
    self.write_float(value.m01);
    self.write_float(value.m11);
    self.write_float(value.m21);
    self.write_float(value.m31);
    self.write_float(value.m02);
    self.write_float(value.m12);
    self.write_float(value.m22);
    self.write_float(value.m32);
    self.write_float(value.m03);
    self.write_float(value.m13);
    self.write_float(value.m23);
    self.write_float(value.m33);
}

<*
 Read matrix columns in column-major order.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn Mat4? Reader.read_mat4(&self) {
    Mat4 value;
    value.m00 = self.read_float()!;
    value.m10 = self.read_float()!;
    value.m20 = self.read_float()!;
    value.m30 = self.read_float()!;
    value.m01 = self.read_float()!;
    value.m11 = self.read_float()!;
    value.m21 = self.read_float()!;
    value.m31 = self.read_float()!;
    value.m02 = self.read_float()!;
    value.m12 = self.read_float()!;
    value.m22 = self.read_float()!;
    value.m32 = self.read_float()!;
    value.m03 = self.read_float()!;
    value.m13 = self.read_float()!;
    value.m23 = self.read_float()!;
    value.m33 = self.read_float()!;
    return value;
}

<* Append position, rotation and scale. *>
fn void Writer.write_transform(&self, Transform value) {
    self.write_vec3(value.position);
    self.write_quat(value.rotation);
    self.write_vec3(value.scale);
}

<*
 Read position, rotation and scale.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn Transform? Reader.read_transform(&self) {
    Transform value;
    value.position = self.read_vec3()!;
    value.rotation = self.read_quat()!;
    value.scale = self.read_vec3()!;
    return value;
}

<* Append minimum and maximum bounds. *>
fn void Writer.write_aabb(&self, Aabb value) {
    self.write_vec3(value.min);
    self.write_vec3(value.max);
}

<*
 Read minimum and maximum bounds.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn Aabb? Reader.read_aabb(&self) {
    Aabb value;
    value.min = self.read_vec3()!;
    value.max = self.read_vec3()!;
    return value;
}
