module c3d::render;

<*
 Recorded work the renderer times separately.
*>
enum Pass : int {
    UPLOADS,
    SHADOW_ATLAS,
    ACCELERATION_BUILD,
    DEPTH_PREPASS,
    FORWARD_OPAQUE,
    SKY,
    FORWARD_TRANSPARENT,
    POST_CHAIN,
    COMPOSITE,
}

<*
 Passes the renderer reserves timing slots for.
*>
const usz PASS_COUNT = Pass::len;

<*
 Timestamps written per timed pass.
*>
const uint TIMESTAMPS_PER_PASS = 2;

<*
 Counters and timings for the frame that most recently completed.
*>
struct Stats {
    uint  draws;
    uint  triangles;
    uint  culled;
    uint  lights;
    uint  shadow_layers;
    uint  uploads;
    uint  upload_bytes;
    uint  dangling_refs;
    float frame_ms;
    float cpu_record_ms;
    float[PASS_COUNT] gpu_pass_ms;
}

<*
 First timestamp slot a frame slot reserves for one pass.
 @require pass_ordinal < PASS_COUNT
 @pure
*>
fn uint pass_timestamp_slot(ulong frame_index, usz pass_ordinal) {
    return (uint)(frame_index % FRAMES_IN_FLIGHT) * (uint)PASS_COUNT * TIMESTAMPS_PER_PASS
      + (uint)pass_ordinal * TIMESTAMPS_PER_PASS;
}
