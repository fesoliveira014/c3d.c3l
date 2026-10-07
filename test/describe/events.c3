module c3d::test::describe_consumers @private;

import c3d;
import c3d::describe;
import described_component;
import std::core::mem::allocators;
import std::math;

const usz MAX_EVENTS = 96;

enum EventPhase {
    ENTER,
    LEAF,
    LEAVE,
    SKIP,
    HOOK,
}

struct VisitEvent {
    EventPhase phase;
    char[80] name;
    char[32] display;
    char[16] unit;
    char[32] choices;
    describe::Kind kind;
    usz size;
    usz alignment;
    typeid identity;
    describe::Range range;
    bool has_asset_kind;
    AssetKind metadata_asset_kind;
    describe::Kind element_kind;
    usz element_size;
    usz element_alignment;
    usz extent;
}

struct EventLog {
    VisitEvent[MAX_EVENTS] events;
    usz count;
    bool skip_arrays;
    bool expect_null;
    bool edited_int;
}

EventLog* active_event_log;

fn void copy_label(char[] destination, String source) {
    assert(source.len < destination.len);
    destination[:source.len] = ((char[])source)[..];
}

fn void record_event(EventLog* log, EventPhase phase, describe::Info* info) {
    assert(log.count < MAX_EVENTS);
    VisitEvent* event = &log.events[log.count++];
    *event = {
        .phase = phase,
        .kind = info.kind,
        .size = info.size,
        .alignment = info.alignment,
        .identity = info.identity,
        .range = info.metadata.range,
        .has_asset_kind = info.metadata.has_asset_kind,
        .metadata_asset_kind = info.metadata.asset_kind,
        .element_kind = info.element_kind,
        .element_size = info.element_size,
        .element_alignment = info.element_alignment,
        .extent = info.extent,
    };
    copy_label(event.name[..], info.name);
    copy_label(event.display[..], info.metadata.display_name);
    copy_label(event.unit[..], info.metadata.unit);
    usz position;
    foreach (name : info.enum_names) {
        assert(position + name.len + 1 < event.choices.len);
        event.choices[position:name.len] = ((char[])name)[..];
        position += (usz)name.len;
        event.choices[position++] = '|';
    }
}

fn bool? event_begin(describe::Visitor* visitor, describe::Info* info, void* value) {
    EventLog* log = (EventLog*)visitor.user;
    assert(!log.expect_null || value == null);
    record_event(log, ENTER, info);
    if (log.skip_arrays && info.kind == ARRAY) {
        record_event(log, SKIP, info);
        return false;
    }
    return true;
}

fn void? event_end(describe::Visitor* visitor, describe::Info* info, void* value) {
    EventLog* log = (EventLog*)visitor.user;
    assert(!log.expect_null || value == null);
    record_event(log, LEAVE, info);
}

fn bool? event_field(describe::Visitor* visitor, describe::Info* info, void* value) {
    EventLog* log = (EventLog*)visitor.user;
    assert(!log.expect_null || value == null);
    record_event(log, LEAF, info);
    if (visitor.mode == EDIT && info.kind == INT && !log.edited_int) {
        *(int*)value ^= 1;
        log.edited_int = true;
        return true;
    }
    return false;
}

fn void record_fixture_hook(EventLog* log) {
    describe::Info info = {
        .name = "fixture",
        .kind = STRUCT,
        .size = Fixture::size,
        .alignment = Fixture::alignment,
        .identity = Fixture,
    };
    record_event(log, HOOK, &info);
}

fn void? finish_event_fixture(void* raw) {
    finish_fixture(raw)!;
    record_fixture_hook(active_event_log);
}

fn bool? handwritten_fixture(describe::Visitor* visitor, void* raw) {
    Fixture* value = (Fixture*)raw;
    bool changed;
    changed = describe::@field(visitor, "top_values", value.top_values)! || changed;
    changed = describe::@field(visitor, "signed_count", value.signed_count)! || changed;
    changed = describe::@field(visitor, "unsigned_count", value.unsigned_count)! || changed;
    changed = describe::@field(visitor, "signed_total", value.signed_total)! || changed;
    changed = describe::@field(visitor, "unsigned_total", value.unsigned_total)! || changed;
    changed = describe::@field(
        visitor: visitor,
        name: "precision",
        #field: value.precision,
        metadata: {
            .display_name = "Precision",
            .range = { .enabled = true, .min = -2.0, .max = 2.0 },
            .unit = "rad",
        },
    )! || changed;
    changed = describe::@field(visitor, "direction", value.direction)! || changed;
    changed = describe::@field(visitor, "tint", value.tint)! || changed;
    changed = describe::@field(visitor, "rotation", value.rotation)! || changed;
    changed = describe::@field(visitor, "title", value.title)! || changed;
    changed = describe::@field(visitor, "category", value.category)! || changed;
    changed = describe::@field(visitor, "owner", value.owner)! || changed;
    changed = describe::@field(visitor, "texture", value.texture)! || changed;
    changed = describe::@field(visitor, "nested", value.nested)! || changed;
    changed = describe::@field(visitor, "steps", value.steps)! || changed;
    changed = describe::@field(visitor, "entries", value.entries)! || changed;
    return changed;
}

macro void expected_leaf(
    log,
    $Type,
    String name,
    describe::Kind kind,
) {
    describe::Info info = {
        .name = name,
        .kind = kind,
        .size = $Type::size,
        .alignment = $Type::alignment,
        .identity = $Type,
    };
    record_event(log, LEAF, &info);
    return;
}

macro void expected_scope(
    log,
    $Type,
    String name,
    EventPhase phase,
) {
    describe::Info info = {
        .name = name,
        .kind = STRUCT,
        .size = $Type::size,
        .alignment = $Type::alignment,
        .identity = $Type,
    };
    record_event(log, phase, &info);
    return;
}

macro void expected_sequence(
    log,
    $Type,
    $Element,
    String name,
    describe::Kind kind,
    describe::Kind element_kind,
    EventPhase phase,
    usz extent = 0,
) {
    describe::Info info = {
        .name = name,
        .kind = kind,
        .size = $Type::size,
        .alignment = $Type::alignment,
        .identity = $Type,
        .element_kind = element_kind,
        .element_size = $Element::size,
        .element_alignment = $Element::alignment,
        .extent = extent,
    };
    record_event(log, phase, &info);
    return;
}

fn void expected_fixture_events(EventLog* log, describe::Mode mode) {
    expected_scope(
        log: log,
        $Type: Fixture,
        name: "fixture",
        phase: ENTER,
    );
    expected_sequence(
        log: log,
        $Type: uint[],
        $Element: uint,
        name: "top_values",
        kind: SLICE,
        element_kind: UINT,
        phase: ENTER,
    );
    usz top_count = mode == SCHEMA ? 1 : mode == READ ? 0 : 2;
    for (usz index = 0; index < top_count; index++) {
        expected_leaf(
            log: log,
            $Type: uint,
            name: "",
            kind: UINT,
        );
    }
    expected_sequence(
        log: log,
        $Type: uint[],
        $Element: uint,
        name: "top_values",
        kind: SLICE,
        element_kind: UINT,
        phase: LEAVE,
    );
    expected_leaf(
        log: log,
        $Type: int,
        name: "signed_count",
        kind: INT,
    );
    expected_leaf(
        log: log,
        $Type: uint,
        name: "unsigned_count",
        kind: UINT,
    );
    expected_leaf(
        log: log,
        $Type: long,
        name: "signed_total",
        kind: LONG,
    );
    expected_leaf(
        log: log,
        $Type: ulong,
        name: "unsigned_total",
        kind: ULONG,
    );
    expected_leaf(
        log: log,
        $Type: double,
        name: "precision",
        kind: DOUBLE,
    );
    VisitEvent* precision = &log.events[log.count - 1];
    copy_label(precision.display[..], "Precision");
    copy_label(precision.unit[..], "rad");
    precision.range = { .enabled = true, .min = -2.0, .max = 2.0 };
    expected_leaf(
        log: log,
        $Type: Vec2,
        name: "direction",
        kind: VEC2,
    );
    expected_leaf(
        log: log,
        $Type: Vec4,
        name: "tint",
        kind: VEC4,
    );
    expected_leaf(
        log: log,
        $Type: Quat,
        name: "rotation",
        kind: QUAT,
    );
    expected_leaf(
        log: log,
        $Type: String,
        name: "title",
        kind: STRING,
    );
    expected_leaf(
        log: log,
        $Type: FixtureStyle,
        name: "category",
        kind: ENUM,
    );
    copy_label(log.events[log.count - 1].choices[..], "FIRST|SECOND|THIRD|");
    expected_leaf(
        log: log,
        $Type: Entity,
        name: "owner",
        kind: ENTITY,
    );
    expected_leaf(
        log: log,
        $Type: TextureId,
        name: "texture",
        kind: ASSET,
    );
    log.events[log.count - 1].has_asset_kind = true;
    log.events[log.count - 1].metadata_asset_kind = TEXTURE;
    expected_scope(
        log: log,
        $Type: FixtureNested,
        name: "nested",
        phase: ENTER,
    );
    expected_sequence(
        log: log,
        $Type: uint[],
        $Element: uint,
        name: "weights",
        kind: SLICE,
        element_kind: UINT,
        phase: ENTER,
    );
    usz weight_count = mode == SCHEMA ? 1 : mode == READ ? 0 : 3;
    for (usz index = 0; index < weight_count; index++) {
        expected_leaf(
            log: log,
            $Type: uint,
            name: "",
            kind: UINT,
        );
    }
    expected_sequence(
        log: log,
        $Type: uint[],
        $Element: uint,
        name: "weights",
        kind: SLICE,
        element_kind: UINT,
        phase: LEAVE,
    );
    expected_leaf(
        log: log,
        $Type: int,
        name: "nested_guard",
        kind: INT,
    );
    expected_scope(
        log: log,
        $Type: FixtureNested,
        name: "nested",
        phase: LEAVE,
    );
    expected_sequence(
        log: log,
        $Type: int[3],
        $Element: int,
        name: "steps",
        kind: ARRAY,
        element_kind: INT,
        phase: ENTER,
        extent: 3,
    );
    if (log.skip_arrays) {
        expected_sequence(
            log: log,
            $Type: int[3],
            $Element: int,
            name: "steps",
            kind: ARRAY,
            element_kind: INT,
            phase: SKIP,
            extent: 3,
        );
    } else {
        usz step_count = mode == SCHEMA ? 1 : 3;
        for (usz index = 0; index < step_count; index++) {
            expected_leaf(
                log: log,
                $Type: int,
                name: "",
                kind: INT,
            );
        }
        expected_sequence(
            log: log,
            $Type: int[3],
            $Element: int,
            name: "steps",
            kind: ARRAY,
            element_kind: INT,
            phase: LEAVE,
            extent: 3,
        );
    }
    expected_sequence(
        log: log,
        $Type: FixtureEntry[],
        $Element: FixtureEntry,
        name: "entries",
        kind: SLICE,
        element_kind: STRUCT,
        phase: ENTER,
    );
    usz entry_count = mode == SCHEMA ? 1 : mode == READ ? 0 : 2;
    for (usz index = 0; index < entry_count; index++) {
        expected_scope(
            log: log,
            $Type: FixtureEntry,
            name: "",
            phase: ENTER,
        );
        expected_leaf(
            log: log,
            $Type: String,
            name: "label",
            kind: STRING,
        );
        expected_leaf(
            log: log,
            $Type: uint,
            name: "amount",
            kind: UINT,
        );
        expected_scope(
            log: log,
            $Type: FixtureEntry,
            name: "",
            phase: LEAVE,
        );
    }
    expected_sequence(
        log: log,
        $Type: FixtureEntry[],
        $Element: FixtureEntry,
        name: "entries",
        kind: SLICE,
        element_kind: STRUCT,
        phase: LEAVE,
    );
    expected_scope(
        log: log,
        $Type: Fixture,
        name: "fixture",
        phase: LEAVE,
    );
    if (mode == READ || mode == EDIT) record_fixture_hook(log);
}

fn void assert_events_equal(EventLog* actual, EventLog* expected) {
    assert(actual.count == expected.count);
    for (usz index = 0; index < actual.count; index++) {
        VisitEvent* left = &actual.events[index];
        VisitEvent* right = &expected.events[index];
        assert(left.phase == right.phase);
        assert(left.name == right.name);
        assert(left.display == right.display);
        assert(left.unit == right.unit);
        assert(left.choices == right.choices);
        assert(left.kind == right.kind);
        assert(left.size == right.size);
        assert(left.alignment == right.alignment);
        assert(left.identity == right.identity);
        assert(left.range.enabled == right.range.enabled);
        if (left.range.enabled) assert(left.range.min == right.range.min && left.range.max == right.range.max);
        assert(left.has_asset_kind == right.has_asset_kind);
        if (left.has_asset_kind) assert(left.metadata_asset_kind == right.metadata_asset_kind);
        if (left.kind == ARRAY || left.kind == SLICE) {
            assert(left.element_kind == right.element_kind);
            assert(left.element_size == right.element_size);
            assert(left.element_alignment == right.element_alignment);
        }
        if (left.kind == ARRAY) assert(left.extent == right.extent);
    }
}

fn EventLog collect_fixture_events(describe::Descriptor* descriptor, describe::Mode mode, bool skip_arrays) {
    FixtureSource source;
    if (mode != READ && mode != SCHEMA) initialize_fixture(&source);
    EventLog log = { .skip_arrays = skip_arrays, .expect_null = mode == SCHEMA };
    describe::Visitor visitor = {
        .mode = mode,
        .field = &event_field,
        .begin = &event_begin,
        .end = &event_end,
        .user = &log,
    };
    active_event_log = &log;
    defer active_event_log = null;
    Allocator previous = mem;
    mem = &allocators::NULL_ALLOCATOR;
    defer mem = previous;
    bool changed = describe::walk_descriptor(descriptor, &visitor, mode == SCHEMA ? null : &source.value)!!;
    assert(changed == (mode == EDIT));
    if (mode == WRITE || mode == SCHEMA) assert(source.value.derived == 0);
    return log;
}

fn void test_authored_and_reflected_events_match_all_modes_and_goldens() @test @public {
    register_fixtures()!!;
    describe::Descriptor reflected = *describe::get(Fixture)!!;
    reflected.name = "fixture";
    reflected.after = &finish_event_fixture;
    describe::Descriptor authored = reflected;
    authored.fields = &handwritten_fixture;
    foreach (mode : (describe::Mode[]){ WRITE, READ, EDIT, SCHEMA }) {
        for (usz skip = 0; skip < 2; skip++) {
            EventLog reflected_events = collect_fixture_events(&reflected, mode, skip != 0);
            EventLog authored_events = collect_fixture_events(&authored, mode, skip != 0);
            EventLog golden = { .skip_arrays = skip != 0 };
            expected_fixture_events(&golden, mode);
            assert_events_equal(&reflected_events, &authored_events);
            assert_events_equal(&reflected_events, &golden);
        }
    }
}

fn void test_shared_demo_schema_records_metadata_without_a_value() @test @public {
    described_component::register_described_component()!!;
    EventLog actual = { .expect_null = true };
    describe::Visitor visitor = {
        .mode = SCHEMA,
        .field = &event_field,
        .begin = &event_begin,
        .end = &event_end,
        .user = &actual,
    };
    describe::Descriptor descriptor = *describe::get(DescribedComponent)!!;
    descriptor.name = "demo";
    describe::walk_descriptor(&descriptor, &visitor, null)!!;
    EventLog golden;
    expected_scope(
        log: &golden,
        $Type: DescribedComponent,
        name: "demo",
        phase: ENTER,
    );
    expected_leaf(
        log: &golden,
        $Type: bool,
        name: "enabled",
        kind: BOOL,
    );
    expected_leaf(
        log: &golden,
        $Type: float,
        name: "speed",
        kind: FLOAT,
    );
    copy_label(golden.events[golden.count - 1].display[..], "Speed");
    copy_label(golden.events[golden.count - 1].unit[..], "m/s");
    golden.events[golden.count - 1].range = { .enabled = true, .min = 0, .max = 10 };
    expected_leaf(
        log: &golden,
        $Type: MotionStyle,
        name: "mode",
        kind: ENUM,
    );
    copy_label(golden.events[golden.count - 1].choices[..], "STILL|ORBIT|PULSE|");
    expected_leaf(
        log: &golden,
        $Type: Vec3,
        name: "offset",
        kind: VEC3,
    );
    expected_leaf(
        log: &golden,
        $Type: Entity,
        name: "target",
        kind: ENTITY,
    );
    expected_leaf(
        log: &golden,
        $Type: GeometryId,
        name: "geometry",
        kind: ASSET,
    );
    golden.events[golden.count - 1].has_asset_kind = true;
    golden.events[golden.count - 1].metadata_asset_kind = GEOMETRY;
    expected_scope(
        log: &golden,
        $Type: DescribedComponent,
        name: "demo",
        phase: LEAVE,
    );
    assert_events_equal(&actual, &golden);
}
