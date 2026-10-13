module c3d::test::lut_cube;

import c3d;
import c3d::asset::image;
import c3d::render::post;
import c3d::shader;
import gpu;
import std::math;

const uint IDENTITY_SIZE @local = 5;
const String SIZE_TWO @local = "LUT_3D_SIZE 2\n";
const String EIGHT_ROWS @local = "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";

fn void expect_fault(String text, fault expected) @local {
    assert(@catch(image::parse_lut_cube(mem, text)) == expected);
}

fn void test_identity_cube_reproduces_the_identity_lut() @test {
    @pool() {
        DString text = dstring::temp();
        text.appendf("LUT_3D_SIZE %d\n", IDENTITY_SIZE)!!;

        float last = (float)(IDENTITY_SIZE - 1);
        for (uint blue = 0; blue < IDENTITY_SIZE; blue++) {
            for (uint green = 0; green < IDENTITY_SIZE; green++) {
                for (uint red = 0; red < IDENTITY_SIZE; red++) {
                    text.appendf("%.6f %.6f %.6f\n", red / last, green / last, blue / last)!!;
                }
            }
        }

        Lut3d lut = image::parse_lut_cube(mem, text.str_view())!!;
        defer image::destroy_lut3d(&lut);
        char[] identity = post::identity_lut(mem, IDENTITY_SIZE);
        defer free(identity.ptr);

        assert(lut.size == IDENTITY_SIZE);
        assert(lut.domain_min.equals((Vec3){ 0, 0, 0 }) && lut.domain_max.equals((Vec3){ 1, 1, 1 }));
        assert(mem::equals(lut.rgba, identity));
        assert(post::lut_texture_desc(&lut).width == IDENTITY_SIZE);
    };
}

fn void test_cube_rows_run_red_fastest_then_green_then_blue() @test {
    // Row i is texel (x, y, z) = (i & 1, (i >> 1) & 1, i >> 2); its output is (z, x, y).
    String text = "LUT_3D_SIZE 2\n0 0 0\n0 1 0\n0 0 1\n0 1 1\n1 0 0\n1 1 0\n1 0 1\n1 1 1\n";
    Lut3d lut = image::parse_lut_cube(mem, text)!!;
    defer image::destroy_lut3d(&lut);

    assert(lut.rgba.len == 8 * 4);

    for (usz index = 0; index < 8; index++) {
        char x = (char)(index & 1) * char::max;
        char y = (char)((index >> 1) & 1) * char::max;
        char z = (char)(index >> 2) * char::max;

        assert(lut.rgba[index * 4] == z && lut.rgba[index * 4 + 1] == x && lut.rgba[index * 4 + 2] == y);
        assert(lut.rgba[index * 4 + 3] == char::max);
    }
}

fn void test_cube_domain_folds_into_the_grade() @test {
    String text = "# exported\r\nTITLE \"warm look\"\r\nDOMAIN_MAX 2 3.5 1\r\nDOMAIN_MIN -1\t0 0.25\r\n"
        "LUT_3D_SIZE 2\r\n# data\r\n-0.5 0 0\r\n1.5 0.5 0\r\n0 0.25 0\r\n0 0 0.75\r\n"
        "0 0 0\r\n0 0 0\r\n0 0 0\r\n1e-1 0 0\r\n\r\n";
    Lut3d lut = image::parse_lut_cube(mem, text)!!;
    defer image::destroy_lut3d(&lut);

    assert(lut.domain_min.equals((Vec3){ -1, 0, 0.25f }) && lut.domain_max.equals((Vec3){ 2, 3.5f, 1 }));

    char[4] first = { 0, 0, 0, char::max };
    char[4] second = { char::max, 128, 0, char::max };
    char[4] third = { 0, 64, 0, char::max };
    char[4] fourth = { 0, 0, 191, char::max };
    char[4] last = { 26, 0, 0, char::max };

    assert(mem::equals(lut.rgba[0:4], first[..]) && mem::equals(lut.rgba[4:4], second[..]));
    assert(mem::equals(lut.rgba[8:4], third[..]) && mem::equals(lut.rgba[12:4], fourth[..]));
    assert(mem::equals(lut.rgba[28:4], last[..]));

    GradeParams params = post::default_post_stack().grade;
    params.lut_domain_min = lut.domain_min;
    params.lut_domain_max = lut.domain_max;
    GradeGpu packed;
    post::write_grade_gpu(
        gpu_grade:       &packed,
        params:          &params,
        camera_exposure: 1,
        lut_texture:     (gpu::TextureIndex)1,
        lut_size:        lut.size,
    );

    for (usz channel = 0; channel < 3; channel++) {
        float low = lut.domain_min[channel] * packed.lut_scale[channel] + packed.lut_offset[channel];
        float high = lut.domain_max[channel] * packed.lut_scale[channel] + packed.lut_offset[channel];
        assert(math::abs(low - 0.25f) < 1e-6f && math::abs(high - 0.75f) < 1e-6f);
    }
}

fn void test_cube_faults_name_the_problem() @test {
    expect_fault("LUT_1D_SIZE 4\n0 0 0\n1 1 1\n0 0 0\n1 1 1\n", c3d::UNSUPPORTED);
    expect_fault("LUT_3D_SIZE 1\n0 0 0\n", c3d::UNSUPPORTED);
    expect_fault("LUT_3D_SIZE 65\n", c3d::UNSUPPORTED);

    expect_fault(SIZE_TWO +++ "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n", c3d::ASSET_FORMAT_ERROR);
    expect_fault(SIZE_TWO +++ EIGHT_ROWS +++ "0 0 0\n", c3d::ASSET_FORMAT_ERROR);
    expect_fault(SIZE_TWO +++ "0 0\n" +++ EIGHT_ROWS, c3d::ASSET_FORMAT_ERROR);
    expect_fault(SIZE_TWO +++ "0 0 0 0\n" +++ EIGHT_ROWS, c3d::ASSET_FORMAT_ERROR);
    expect_fault(SIZE_TWO +++ "0 red 0\n" +++ EIGHT_ROWS, c3d::ASSET_FORMAT_ERROR);
    expect_fault("LUT_3D_SIZE two\n" +++ EIGHT_ROWS, c3d::ASSET_FORMAT_ERROR);
    expect_fault(SIZE_TWO +++ "LUT_3D_INPUT_RANGE 0 1\n" +++ EIGHT_ROWS, c3d::ASSET_FORMAT_ERROR);

    expect_fault(SIZE_TWO +++ SIZE_TWO +++ EIGHT_ROWS, c3d::ASSET_FORMAT_ERROR);
    expect_fault("TITLE \"a\"\nTITLE \"b\"\n" +++ SIZE_TWO +++ EIGHT_ROWS, c3d::ASSET_FORMAT_ERROR);
    expect_fault("DOMAIN_MIN 0 0 0\nDOMAIN_MIN 0 0 0\n" +++ SIZE_TWO +++ EIGHT_ROWS, c3d::ASSET_FORMAT_ERROR);
    expect_fault("DOMAIN_MAX 1 1 1\nDOMAIN_MAX 1 1 1\n" +++ SIZE_TWO +++ EIGHT_ROWS, c3d::ASSET_FORMAT_ERROR);

    expect_fault(SIZE_TWO +++ EIGHT_ROWS +++ "TITLE \"late\"\n", c3d::ASSET_FORMAT_ERROR);
    expect_fault(SIZE_TWO +++ "0 0 0\nDOMAIN_MAX 1 1 1\n", c3d::ASSET_FORMAT_ERROR);
    expect_fault(EIGHT_ROWS +++ SIZE_TWO, c3d::ASSET_FORMAT_ERROR);
    expect_fault("# nothing here\n", c3d::ASSET_FORMAT_ERROR);

    expect_fault("DOMAIN_MAX 1 0 1\n" +++ SIZE_TWO +++ EIGHT_ROWS, c3d::ASSET_FORMAT_ERROR);
    expect_fault("DOMAIN_MIN 2 0 0\n" +++ SIZE_TWO +++ EIGHT_ROWS, c3d::ASSET_FORMAT_ERROR);
}
