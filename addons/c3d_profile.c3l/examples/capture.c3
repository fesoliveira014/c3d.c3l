module c3d_profile_capture;

import c3d::profile;
import std::io;

fn void main() {
    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 120,
        .cpu_scopes_per_frame = 2_048,
        .max_depth = 64,
        .label_bytes_per_frame = 65_536,
    })!!;
    defer profile::destroy_recorder(&recorder);

    ulong checksum;
    profile::@capture(&recorder, 7) {
        profile::@scope("simulation") {
            for (uint value = 1; value <= 1_000; value++) checksum += (ulong)value * value;
        };
    };

    ulong captured_frame_id = checksum ? 7 : 8;
    String encoded = profile::capture_json(mem, recorder.frame(captured_frame_id)!!);
    defer alloc::free(mem, encoded.ptr);
    io::eprintfn("CPU capture storage: %s bytes", recorder.allocated_bytes);
    io::printn(encoded);
}
