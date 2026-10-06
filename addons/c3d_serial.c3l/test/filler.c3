module c3d::serial::test::filler <INDEX>;

import c3d::scene;
import c3d::serial;

struct SerialFiller @private {
    uint value;
}

fn void? write_filler(void* component, Writer* writer, WriteContext* context) @private {
    writer.write_uint(((SerialFiller*)component).value);
}

fn void? read_filler(Reader* reader, ReadContext* context) @private {
    context.scene.add(context.node, (SerialFiller){ .value = reader.read_uint()! });
}
