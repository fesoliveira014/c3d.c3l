module c3d::test::animation_reference;

import c3d;
import c3d::anim;
import c3d::scene;
import std::collections::list;
import std::io;
import std::io::file;
import std::io::path;
import std::math;

const uint REFERENCE_MAGIC @private = 0x46455241;
const uint SNAPSHOT_MAGIC @private = 0x50414e53;
const uint REFERENCE_VERSION @private = 1;
const uint SNAPSHOT_HEADER_WORDS @private = 6;

enum CaptureOperation @private {
    BASELINE,
    PLAY,
    EDIT_ACTION,
    UPDATE,
    STOP,
    CROSS_FADE,
    ADD_SPACE,
    EDIT_SPACE,
    STOP_SPACE,
    APPLY_MOTION,
    REMOVE_TARGET,
}

struct ReferenceCapture @private {
    List{uint} words;
    uint snapshots;
}

fn void ReferenceCapture.f32(&self, float value) {
    self.words.push(bitcast(value, uint));
}

fn void ReferenceCapture.f64(&self, double value) {
    ulong bits = bitcast(value, ulong);
    self.words.push((uint)bits);
    self.words.push((uint)(bits >> 32));
}

fn void ReferenceCapture.transform(&self, Transform value) {
    foreach (channel : value.position) self.f32(channel);
    foreach (channel : value.rotation.v) self.f32(channel);
    foreach (channel : value.scale) self.f32(channel);
}

fn void ReferenceCapture.boolean(&self, bool value) {
    self.words.push(value ? 1 : 0);
}

fn void? ReferenceCapture.snapshot(
    &self,
    ReferenceRig* rig,
    uint case_id,
    CaptureOperation operation,
    float dt = 0,
) {
    sz start = self.words.len();
    self.words.push(SNAPSHOT_MAGIC);
    self.words.push(case_id);
    self.words.push(rig.sample++);
    self.words.push((uint)operation.ordinal);
    self.f32(dt);
    self.words.push(0);

    Animator* animator = rig.playback();
    ModelInstance* instance = rig.scene.get(rig.root, ModelInstance);
    self.transform(rig.root.local);
    self.words.push(animator.root_node);
    self.words.push((uint)instance.nodes.len);

    for (usz index = 0; index < instance.nodes.len; index++) {
        Node* node = instance.present_node(index);
        self.boolean(node != null);

        if (node) self.transform(node.local);
    }

    self.words.push((uint)instance.mesh_nodes.len);

    foreach (node_index : instance.mesh_nodes) {
        Node* node = instance.present_node(node_index);
        Mesh* mesh = node ? rig.scene.get(node, Mesh) : null;
        self.words.push(node_index);
        self.boolean(mesh != null);
        self.words.push(mesh ? (uint)mesh.morph_weights.len : 0);

        if (mesh) {
            foreach (weight : mesh.morph_weights) self.f32(weight);
        }
    }

    foreach (channel : animator.root_motion.translation) self.f32(channel);
    foreach (channel : animator.root_motion.rotation.v) self.f32(channel);
    self.words.push(animator.action_count);

    foreach (identity : animator.order[:animator.action_count]) {
        Action* action = animator.action(identity);
        self.words.push(rig.action_label(identity)!);
        self.words.push(rig.clip_label(action.clip)!);
        self.words.push(action.layer);
        self.words.push((uint)action.root_motion.ordinal);
        self.boolean(action.additive);
        self.boolean(action.loop);
        self.boolean(action.playing);
        self.boolean(action.root_yaw);
        self.f32(action.time);
        self.f32(action.speed);
        self.f32(action.weight);
        self.f32(action.fade_target);
        self.f32(action.fade_rate);
        self.f32(action.published_time);
        self.f64(action.previous_time);
        self.f64(action.clock_delta);
        self.f64(action.clock_time);
        self.words.push(action.blend_space);
        self.words.push((uint)action.mask.len);

        foreach (member : action.mask) self.boolean(member);

        self.words.push((uint)action.reference.len);

        foreach (value : action.reference) self.f32(value);
    }

    self.words.push((uint)animator.blend_spaces.len);

    foreach (&space : animator.blend_spaces) {
        self.words.push(space.count);

        if (!space.count) continue;

        self.f32(space.parameter);
        self.f32(space.weight);
        self.f32(space.fade_target);
        self.f32(space.fade_rate);
        self.f64(space.phase);
        self.f32(space.speed);
        self.boolean(space.playing);

        for (uint index = 0; index < space.count; index++) {
            self.words.push(rig.action_label(space.actions[index])!);
            self.f32(space.positions[index]);
        }
    }

    self.words.push(animator.event_count);
    self.words.push(animator.events_dropped);

    foreach (event : animator.events[:animator.event_count]) {
        self.words.push(rig.action_label(event.action)!);
        self.words.push(rig.clip_label(event.clip)!);
        self.words.push(event.id);
        self.f32(event.time);
    }

    *self.words.get_ref(start + SNAPSHOT_HEADER_WORDS - 1) =
      (uint)(self.words.len() - start - SNAPSHOT_HEADER_WORDS);
    self.snapshots++;
}

fn void? ReferenceCapture.update(
    &self,
    ReferenceRig* rig,
    uint case_id,
    float dt,
) {
    anim::update(&rig.assets, &rig.scene, dt);
    rig.scene.update_world();
    self.snapshot(
        rig: rig,
        case_id: case_id,
        operation: CaptureOperation.UPDATE,
        dt: dt,
    )!;
}

fn char[] encode_reference_words(Allocator allocator, uint[] words) @private {
    char[] bytes = alloc::new_array(allocator, char, (sz)(words.len * uint::size));

    foreach (usz index, word : words) {
        for (usz byte = 0; byte < uint::size; byte++) {
            bytes[index * uint::size + byte] = (char)(word >> (byte * 8));
        }
    }

    return bytes;
}

fn uint reference_word(char[] bytes, usz index) @private {
    uint word;

    for (usz byte = 0; byte < uint::size; byte++) {
        word |= (uint)bytes[index * uint::size + byte] << (byte * 8);
    }

    return word;
}

fn bool compare_reference(char[] expected, char[] candidate) @private {
    if (expected == candidate) return true;

    usz compared = (usz)math::min(expected.len, candidate.len) / uint::size;
    usz mismatch;

    while (mismatch < compared && reference_word(expected, mismatch) == reference_word(candidate, mismatch)) mismatch++;

    io::eprintfn("Reference mismatch at field word %s.", mismatch);
    io::eprintfn("Expected %s bytes, candidate %s bytes.", expected.len, candidate.len);

    if (mismatch < 3 || mismatch >= candidate.len / uint::size) return false;

    usz snapshot = 3;

    while (snapshot + SNAPSHOT_HEADER_WORDS <= candidate.len / uint::size) {
        uint count = reference_word(candidate, snapshot + SNAPSHOT_HEADER_WORDS - 1);

        if (mismatch < snapshot + SNAPSHOT_HEADER_WORDS + count) {
            io::eprintfn(
                "Case %s, sample %s.",
                reference_word(candidate, snapshot + 1),
                reference_word(candidate, snapshot + 2),
            );
            io::eprintfn(
                "Operation %s, snapshot word %s.",
                reference_word(candidate, snapshot + 3),
                mismatch - snapshot,
            );
            break;
        }

        snapshot += (usz)SNAPSHOT_HEADER_WORDS + count;
    }

    return false;
}

fn void? run_capture(
    String output_path,
    String reference_path = "",
    String repository = "",
) @private {
    if (!repository.len) {
        Path source = path::tnew($$FILEPATH)!;
        repository = (String)source.parent()!.tappend("../..")!;
    }

    ReferenceCapture capture;
    capture.words.init(mem);
    defer capture.words.free();
    capture.words.push(REFERENCE_MAGIC);
    capture.words.push(REFERENCE_VERSION);
    capture.words.push(0);

    capture_exact_controls(&capture)!;
    capture_exact_layers(&capture)!;
    capture_exact_spaces(&capture)!;
    capture_exact_motion(&capture)!;
    capture_quaternius(&capture, repository)!;
    capture_animated_morph_cube(&capture, repository)!;

    *capture.words.get_ref(2) = capture.snapshots;
    char[] bytes = encode_reference_words(mem, capture.words.array_view());
    defer alloc::free(mem, bytes.ptr);

    file::save(output_path, bytes)!;
    io::printfn("Captured %s snapshots, %s field words.", capture.snapshots, capture.words.len());
    io::printfn("Output bytes: %s.", bytes.len);

    if (reference_path.len) {
        char[] expected = file::load(mem, reference_path)!;
        defer alloc::free(mem, expected.ptr);

        if (!compare_reference(expected, bytes)) return c3d::INVALID_ARGUMENT~;

        io::printn("Reference comparison is bit-identical.");
    }
}

<* Capture ordinary Animator fields and optionally compare frozen bytes. *>
fn int main(String[] arguments) {
    if (arguments.len < 2 || arguments.len > 4) {
        io::eprintn("Usage: animation_reference OUTPUT.bin [REFERENCE.bin] [REPOSITORY_ROOT]");
        return 2;
    }

    String reference = arguments.len >= 3 ? arguments[2] : "";
    String repository = arguments.len == 4 ? arguments[3] : "";

    @pool() {
        if (catch excuse = run_capture(arguments[1], reference, repository)) {
            io::eprintfn("Capture failed: %s.", excuse);
            return 1;
        }
    };

    return 0;
}
