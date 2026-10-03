module c3d::serial::test;

import c3d::serial;
import c3d::maths;
import std::math;

fn void test_scalar_wire_values() @test {
    char[64] bytes;
    Writer writer = serial::writer_over(bytes[..]);
    writer.write_uint(0x12345678);
    writer.write_int(-2);
    writer.write_ulong(0x1020304050607080);
    writer.write_float(-1.5f);
    writer.write_bool(true);
    writer.write_bool(false);
    writer.write_string("hélix");
    writer.finish()!!;
    assert(bytes[0] == 0x78 && bytes[1] == 0x56 && bytes[2] == 0x34 && bytes[3] == 0x12);
    Reader reader = serial::reader_over(bytes[:writer.written()]);
    assert(reader.read_uint()!! == 0x12345678);
    assert(reader.read_int()!! == -2);
    assert(reader.read_ulong()!! == 0x1020304050607080);
    assert(reader.read_float()!! == -1.5f);
    assert(reader.read_bool()!!);
    assert(!reader.read_bool()!!);
    assert(reader.read_string()!! == "hélix");
    assert(reader.remaining() == 0);
}

fn void test_scalar_measurement_and_value_fields() @test {
    char[256] bytes;
    Writer measured = serial::measuring_writer();
    Writer stored = serial::writer_over(bytes[..]);
    Transform transform = {
        .position = { 1, -2, 3 },
        .rotation = { .v = { 0.1f, 0.2f, 0.3f, 0.4f } },
        .scale = { 4, 5, 6 },
    };
    Mat4 matrix = transform.to_mat4();
    Aabb bounds = { .min = { -1, -2, -3 }, .max = { 4, 5, 6 } };
    foreach (writer : (Writer*[]){ &measured, &stored }) {
        writer.write_transform(transform);
        writer.write_mat4(matrix);
        writer.write_aabb(bounds);
        writer.write_vec2({ 7, 8 });
        writer.write_vec4({ 9, 10, 11, 12 });
        writer.finish()!!;
    }
    assert(measured.written() == stored.written());
    Reader reader = serial::reader_over(bytes[:stored.written()]);
    Transform actual = reader.read_transform()!!;
    assert(actual.position == transform.position && actual.rotation.v == transform.rotation.v);
    assert(actual.scale == transform.scale);
    Mat4 actual_matrix = reader.read_mat4()!!;
    assert(actual_matrix == matrix);
    Aabb actual_bounds = reader.read_aabb()!!;
    assert(actual_bounds.min == bounds.min && actual_bounds.max == bounds.max);
    assert(reader.read_vec2()!! == (Vec2){ 7, 8 });
    assert(reader.read_vec4()!! == (Vec4){ 9, 10, 11, 12 });
    assert(reader.remaining() == 0);
}

fn void test_scalar_faults_and_overflow() @test {
    char[7] short_bytes;
    Reader reader = serial::reader_over(short_bytes[:3]);
    assert(@catch(reader.read_uint()) == c3d::ASSET_FORMAT_ERROR);
    reader = serial::reader_over(short_bytes[..]);
    assert(@catch(reader.read_ulong()) == c3d::ASSET_FORMAT_ERROR);
    reader = serial::reader_over(short_bytes[:3]);
    assert(@catch(reader.read_float()) == c3d::ASSET_FORMAT_ERROR);
    short_bytes[0] = 2;
    reader = serial::reader_over(short_bytes[:1]);
    assert(@catch(reader.read_bool()) == c3d::ASSET_FORMAT_ERROR);
    char[4] enum_bytes = { 255, 255, 255, 255 };
    reader = serial::reader_over(enum_bytes[..]);
    assert(@catch(reader.read_enum(RestorePhase)) == c3d::ASSET_FORMAT_ERROR);
    char[6] invalid_utf8 = { 2, 0, 0, 0, 0xc0, 0x80 };
    reader = serial::reader_over(invalid_utf8[..]);
    assert(@catch(reader.read_string()) == c3d::ASSET_FORMAT_ERROR);
    invalid_utf8[0] = 3;
    reader = serial::reader_over(invalid_utf8[..]);
    assert(@catch(reader.read_string()) == c3d::ASSET_FORMAT_ERROR);
    Writer measured = serial::measuring_writer();
    measured.offset = uint::max - 1;
    measured.write_uint(7);
    assert(@catch(measured.finish()) == c3d::CAPACITY_EXCEEDED);
}
