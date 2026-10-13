module c3d::ui::transition_test;

import c3d;
import c3d::render @public;
import c3d::ui @public;
import c3d::ui::fixture;
import std::math;

const String FADE_SHEET @local = `{
  "fade": {
    "fill": "#000000ff", "size": [40, 20],
    "transition": { "properties": ["fill"], "duration": 1 },
    "hover": { "fill": "#ffffffff" }
  },
  "slide": {
    "fill": "#000000ff", "size": [40, 20],
    "transition": { "properties": ["fill", "offset"], "duration": 1 },
    "hover": { "fill": "#ffffffff", "offset": [20, 0] }
  }
}`;

const Vec2 OVER @local = { 10, 10 };
const Vec2 AWAY @local = { 300, 300 };

fn void load_card(Fixture* fixture, String style) @local {
    fixture.ui.load_styles({ FADE_SHEET })!!;
    fixture.ui.load_document(string::tformat(`{ "root": { "kind": "button", "style": "%s" } }`, style))!!;
    fixture::frame(fixture);
}

fn void move_pointer(Fixture* fixture, Vec2 at, float delta = 0) @local {
    fixture::point(fixture, at);
    fixture::frame(
        fixture: fixture,
        events:  { fixture::motion(at) },
        delta:   delta,
    );
}

fn OverlayRect* nth_rect(Fixture* fixture, uint nth = 0) @local {
    uint seen;
    foreach (&entry : fixture.list.entries[:fixture.list.item_count]) {
        if (entry.kind != RECT) continue;
        if (seen == nth) return &entry.rect;

        seen++;
    }

    unreachable("no such rect");
}

fn void test_reversed_transition_retargets_from_current_value() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    load_card(&fixture, "fade");

    move_pointer(&fixture, OVER);
    assert(nth_rect(&fixture).fill.x == 0, "a retargeted track shows its start value");

    fixture::frame(&fixture, delta: 0.5f);
    assert(nth_rect(&fixture).fill.x == 0.5f);

    move_pointer(&fixture, AWAY);
    assert(nth_rect(&fixture).fill.x == 0.5f, "the return starts at the current value");

    fixture::frame(&fixture, delta: 0.25f);
    assert(nth_rect(&fixture).fill.x == 0.25f);

    fixture::frame(&fixture, delta: 0.25f);
    assert(nth_rect(&fixture).fill.x == 0, "half the distance takes half the duration");
}

fn void test_zero_delta_holds_and_large_delta_finishes() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    load_card(&fixture, "fade");

    move_pointer(&fixture, OVER);
    fixture::frame(&fixture, delta: 0.5f);
    fixture::frame(&fixture);
    fixture::frame(&fixture);
    assert(nth_rect(&fixture).fill.x == 0.5f, "a zero delta advances nothing");

    fixture::frame(&fixture, delta: 100);
    assert(nth_rect(&fixture).fill.x == 1, "a large delta ends the transition in the same update");
}

fn void test_reduced_motion_snaps_offset_and_keeps_fades() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    load_card(&fixture, "slide");

    move_pointer(&fixture, OVER);
    fixture::frame(&fixture, delta: 0.5f);
    assert(nth_rect(&fixture).min.x == 10 && nth_rect(&fixture).fill.x == 0.5f);

    fixture.ui.set_reduced_motion(true);
    fixture::frame(&fixture);
    assert(nth_rect(&fixture).min.x == 20, "a running offset snaps at the next update");
    assert(nth_rect(&fixture).fill.x == 0.5f);

    fixture::frame(&fixture, delta: 0.25f);
    assert(nth_rect(&fixture).fill.x == 0.75f, "the fade keeps running");

    move_pointer(&fixture, AWAY);
    assert(nth_rect(&fixture).min.x == 0, "a retargeted offset is instant");
    assert(nth_rect(&fixture).fill.x == 0.75f);

    fixture::frame(&fixture, delta: 0.375f);
    assert(nth_rect(&fixture).fill.x == 0.375f);
}

fn void test_transition_retargets_across_reload_by_id() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture.ui.load_styles({ FADE_SHEET })!!;
    UiDocumentId document = fixture.ui.load_document(
        `{ "root": { "kind": "button", "children": [
            { "kind": "panel", "id": "named", "style": "fade" },
            { "kind": "panel", "style": "fade" } ] } }`,
    )!!;
    fixture::frame(&fixture);

    move_pointer(&fixture, OVER);
    fixture::frame(&fixture, delta: 0.5f);
    assert(nth_rect(&fixture, 0).fill.x == 0.5f && nth_rect(&fixture, 1).fill.x == 0.5f);

    fixture.ui.reload_document(
        document,
        `{ "root": { "kind": "button", "children": [
            { "kind": "panel", "size": [4, 20] },
            { "kind": "panel", "id": "named", "style": "fade" },
            { "kind": "panel", "style": "fade" } ] } }`,
    )!!;
    fixture::frame(&fixture);
    assert(nth_rect(&fixture, 0).fill.x == 0.5f, "an element with an id keeps its value and retargets from it");
    assert(nth_rect(&fixture, 1).fill.x == 0, "an element without an id snaps to its target");
}
