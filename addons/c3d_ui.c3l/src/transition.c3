module c3d::ui;

import c3d;
import std::math;

const uint UI_DEFAULT_TRANSITIONS @private = 128; // 256 slots of 424 bytes: 106 KiB; when full, changes snap

struct UiTrack @private {
    Vec4     from;
    Vec4     to;       // the last target
    float    elapsed;  // seconds since the retarget, the delay included
    float    duration; // seconds, after distance scaling
    float    delay;
    UiEasing easing;
    bool     running;
}

struct UiTransition @private {
    UiElementKey             key;      // zero generation: free
    uint                     hash;
    uint                     declared; // update serial of the last declaration
    UiTrack[UiAnimated::len] tracks;
}

$assert UiTransition::size == 424; // the cost stated at UI_DEFAULT_TRANSITIONS and in the README

struct UiTransitionStep @private {
    UiTransition* entry;   // null: the element snaps
    bool          created;
    bool          advance; // first declaration of the entry in this update
}

<*
 Make offset, size and bar motion instant; colour and opacity fades still run.
*>
fn void Ui.set_reduced_motion(&self, bool reduced) {
    self.reduced_motion = reduced;
}

fn bool is_motion(UiAnimated animated) @private {
    return animated == OFFSET || animated == SIZE || animated == VALUE;
}

fn float ease(UiEasing easing, float progress) @private {
    switch (easing) {
        case LINEAR:
            return progress;
        case EASE_IN:
            return progress * progress * progress;
        case EASE_OUT:
            float remaining = 1 - progress;
            return 1 - remaining * remaining * remaining;
        case EASE_IN_OUT:
            if (progress < 0.5f) return 4 * progress * progress * progress;

            float mirrored = 2 - 2 * progress;
            return 1 - mirrored * mirrored * mirrored / 2;
    }
}

fn float track_distance(Vec4 first, Vec4 second) @private => math::abs(first - second).max();

fn Vec4 track_value(UiTrack* track) @private {
    if (!track.running) return track.to;

    float progress = 1;
    if (track.duration > 0) progress = math::clamp((track.elapsed - track.delay) / track.duration, 0.0f, 1.0f);

    return track.from + (track.to - track.from) * ease(track.easing, progress);
}

fn Vec4 track_target(UiInstance* instance, UiAnimated animated) @private {
    UiProperties* properties = &instance.properties;
    switch (animated) {
        case FILL: return properties.fill;
        case BORDER_COLOR: return properties.border_color;
        case BORDER_WIDTHS: return properties.border_widths;
        case TEXT_COLOR: return properties.text_color;
        case OPACITY: return { properties.opacity, 0, 0, 0 };
        case OFFSET: return { properties.offset.x, properties.offset.y, 0, 0 };
        case VALUE: return { instance.value, 0, 0, 0 };
        case SIZE:
            // The z lane tells whether both sizes are numbers: only those interpolate.
            if (properties.width.sizing != FIXED || properties.height.sizing != FIXED) return {};

            return { properties.width.value, properties.height.value, 1, 0 };
    }
}

fn void apply_track(UiInstance* instance, UiAnimated animated, Vec4 value) @private {
    UiProperties* properties = &instance.properties;
    switch (animated) {
        case FILL: properties.fill = value;
        case BORDER_COLOR: properties.border_color = value;
        case BORDER_WIDTHS: properties.border_widths = value;
        case TEXT_COLOR: properties.text_color = value;
        case OPACITY: properties.opacity = value.x;
        case OFFSET: properties.offset = value.xy;
        case VALUE: instance.value = value.x;
        case SIZE:
            if (value.z == 0) return;

            properties.width = { .sizing = FIXED, .value = value.x };
            properties.height = { .sizing = FIXED, .value = value.y };
    }
}

fn void settle_track(UiTrack* track, Vec4 target) @private {
    *track = { .from = target, .to = target };
}

fn void advance_track(UiTrack* track, float delta_seconds, bool snap) @private {
    if (!track.running) return;

    track.elapsed += delta_seconds;
    if (snap || track.elapsed - track.delay >= track.duration) settle_track(track, track.to);
}

fn void retarget_track(UiTrack* track, Vec4 target, UiTransitionConfig* config) @private {
    Vec4 current = track_value(track);
    float scale = 1;
    if (track.running) {
        float span = track_distance(track.from, track.to);
        if (span > 0) scale = math::clamp(track_distance(current, target) / span, 0.0f, 1.0f);
    }

    float duration = config.duration * scale;
    if (duration <= 0 && config.delay <= 0) return settle_track(track, target);

    *track = {
        .from     = current,
        .to       = target,
        .duration = duration,
        .delay    = config.delay,
        .easing   = config.easing,
        .running  = true,
    };
}

fn Vec4 step_track(
    Ui* ui,
    UiTransitionStep* step,
    UiTrack* track,
    UiAnimated animated,
    Vec4 target,
    UiTransitionConfig* config,
) @private {
    if (step.created) {
        settle_track(track, target);
        return target;
    }

    bool instant = ui.reduced_motion && is_motion(animated);
    if (step.advance) advance_track(track, ui.delta_seconds, instant);

    if (target != track.to) {
        bool listed = (config.properties & @animated_bit(animated)) != 0;
        bool numeric = animated != SIZE || (target.z != 0 && track.to.z != 0);
        if (listed && numeric && !instant) {
            retarget_track(track, target, config);
        } else {
            settle_track(track, target);
        }
    }

    return track_value(track);
}

fn UiTransition* acquire_transition(Ui* ui, UiInstance* instance, bool* created) @private {
    UiTransition[] table = ui.transitions;
    usz slots = table.len;
    if (!slots) return null;

    uint hash = key_hash(&instance.key, instance.element);
    usz slot = hash % slots;
    while (key_valid(&table[slot].key)) {
        if (table[slot].hash == hash && same_key(&table[slot].key, &instance.key)) return &table[slot];

        slot = (slot + 1) % slots;
    }

    if (ui.transition_count == ui.desc.max_transitions) return null;

    table[slot] = { .key = instance.key, .hash = hash };
    ui.transition_count++;
    *created = true;

    return &table[slot];
}

fn UiTransitionStep begin_transition(Ui* ui, UiInstance* instance) @private {
    if (!instance.element.may_transition) return {};

    UiTransitionStep step;
    step.entry = acquire_transition(ui, instance, &step.created);
    if (!step.entry) return {};

    step.advance = step.entry.declared != ui.update_serial;
    step.entry.declared = ui.update_serial;

    UiTransitionConfig config = instance.properties.transition;
    for (usz index = 0; index < UiAnimated::len; index++) {
        UiAnimated animated = UiAnimated::from_ordinal(index);
        if (animated == VALUE) continue;

        Vec4 value = step_track(
            ui:       ui,
            step:     &step,
            track:    &step.entry.tracks[index],
            animated: animated,
            target:   track_target(instance, animated),
            config:   &config,
        );
        apply_track(instance, animated, value);
    }

    return step;
}

fn void animate_value(Ui* ui, UiInstance* instance, UiTransitionStep* step) @private {
    if (!step.entry) return;

    UiTransitionConfig config = instance.properties.transition;
    Vec4 value = step_track(
        ui:       ui,
        step:     step,
        track:    &step.entry.tracks[UiAnimated.VALUE.ordinal],
        animated: UiAnimated.VALUE,
        target:   track_target(instance, UiAnimated.VALUE),
        config:   &config,
    );
    apply_track(instance, UiAnimated.VALUE, value);
}

fn void erase_transition(Ui* ui, usz slot) @private {
    UiTransition[] table = ui.transitions;
    usz slots = table.len;
    usz hole = slot;
    usz next = (slot + 1) % slots;
    while (key_valid(&table[next].key)) {
        // An entry moves back into the hole unless its home slot lies cyclically between the hole and itself.
        usz home = table[next].hash % slots;
        usz travelled = (next + slots - home) % slots;
        usz gap = (next + slots - hole) % slots;
        if (travelled >= gap) {
            table[hole] = table[next];
            hole = next;
        }

        next = (next + 1) % slots;
    }

    table[hole] = {};
    ui.transition_count--;
}

fn bool transition_running(UiTransition* entry) @private {
    foreach (&track : entry.tracks) {
        if (track.running) return true;
    }

    return false;
}

fn void finish_transitions(Ui* ui) @private {
    usz slot;
    while (slot < ui.transitions.len) {
        UiTransition* entry = &ui.transitions[slot];
        if (key_valid(&entry.key) && entry.declared != ui.update_serial) {
            erase_transition(ui, slot);
            continue;
        }

        slot++;
    }

    uint running;
    foreach (&entry : ui.transitions) {
        if (key_valid(&entry.key) && transition_running(entry)) running++;
    }

    ui.stats.transitions = running;
}

fn bool named_transition(Ui* ui, UiTransition* entry) @private {
    UiDocument*? document = ui.documents.try_get(entry.key.document);
    if (catch document) return false;

    return document.elements[entry.key.element].id_length != 0;
}

fn void drop_transitions(Ui* ui, UiDocumentId document) @private {
    usz slot;
    while (slot < ui.transitions.len) {
        UiTransition* entry = &ui.transitions[slot];
        if (key_valid(&entry.key) && c3d::same_id(entry.key.document, document)) {
            erase_transition(ui, slot);
            continue;
        }

        slot++;
    }
}

fn void drop_unnamed_transitions(Ui* ui) @private {
    usz slot;
    while (slot < ui.transitions.len) {
        UiTransition* entry = &ui.transitions[slot];
        if (key_valid(&entry.key) && !named_transition(ui, entry)) {
            erase_transition(ui, slot);
            continue;
        }

        slot++;
    }
}

fn uint renamed_element(UiDocument* previous, UiDocument* replacement, uint element) @private {
    UiElement* old_element = &previous.elements[element];
    if (!old_element.id_length) return UI_NONE;

    return find_id_element(replacement, previous.strings[old_element.id_offset : old_element.id_length]);
}

fn void remap_transitions(Ui* ui, UiDocument* previous, UiDocument* replacement) @private {
    usz slot;
    while (slot < ui.transitions.len) {
        UiTransition* entry = &ui.transitions[slot];
        bool owned = key_valid(&entry.key) && c3d::same_id(entry.key.document, previous.id);
        if (owned && renamed_element(previous, replacement, entry.key.element) == UI_NONE) {
            erase_transition(ui, slot);
            continue;
        }

        slot++;
    }

    foreach (&entry : ui.transitions) {
        if (!key_valid(&entry.key) || !c3d::same_id(entry.key.document, previous.id)) continue;

        entry.key.element = renamed_element(previous, replacement, entry.key.element);
    }
}
