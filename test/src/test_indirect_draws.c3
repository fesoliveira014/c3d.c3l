module c3d::test::indirect_draws;

import c3d;
import c3d::render;
import gpu;

const char UNWRITTEN @local = 0xAB;

fn void test_indirect_args_pack() @test {
    char[32] buffer @align(16);

    buffer[..] = UNWRITTEN;
    GeometryLayout indexed = { .vertex_count = 24, .index_count = 36 };
    assert(render::indirect_args_bytes(&indexed) == gpu::DrawIndexedIndirectCommand::size);
    render::write_indirect_args(buffer[..], &indexed, 7);
    gpu::DrawIndexedIndirectCommand* indexed_command = (gpu::DrawIndexedIndirectCommand*)&buffer;
    assert(indexed_command.index_count == 36 && indexed_command.instance_count == 7);
    assert(indexed_command.first_index == 0 && indexed_command.vertex_offset == 0);
    assert(indexed_command.first_instance == 0);

    buffer[..] = UNWRITTEN;
    GeometryLayout listed = { .vertex_count = 3 };
    assert(render::indirect_args_bytes(&listed) == gpu::DrawIndirectCommand::size);
    render::write_indirect_args(buffer[..], &listed, 5);
    gpu::DrawIndirectCommand* listed_command = (gpu::DrawIndirectCommand*)&buffer;
    assert(listed_command.vertex_count == 3 && listed_command.instance_count == 5);
    assert(listed_command.first_vertex == 0 && listed_command.first_instance == 0);
}
