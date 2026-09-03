module c3d_test @test;

import c3d;

fn void test_version_is_not_empty()
{
    assert(c3d::VERSION.len > 0);
}
