module c3d::ui;

import c3d;
import clay;
import std::math;

struct UiInstanceLink @private {
    UiPlacement placement;
    String      placeholder; // expanded placeholder of an empty text field
    uint        subtree_end; // instance after the last descendant
    uint        parent;      // Clay id of the enclosing element, zero for a document root
    short       z;           // z of the nearest floating element at or above the instance
}

struct UiFrameStore @private {
    UiInstance[]     instances;
    UiInstanceLink[] links;
    char[]           text;
    UiTextPiece[]    pieces;
}

fn void swap_frames(Ui* ui) @private {
    if (!ui.previous.instances.len) return;

    UiFrameStore current = {
        .instances = ui.instances,
        .links     = ui.links,
        .text      = ui.text,
        .pieces    = ui.pieces,
    };

    ui.instances = ui.previous.instances;
    ui.links = ui.previous.links;
    ui.text = ui.previous.text;
    ui.pieces = ui.previous.pieces;
    ui.previous = current;
}

fn bool exit_continues(Ui* ui, UiTransition* entry) @private {
    if (entry.declared + 1 != ui.update_serial) return false;

    if (!entry.exiting && exit_bits(ui, &ui.previous.instances[entry.instance]) == 0) return false;

    return entry.exit.parent == 0 || lookup_instance(ui, entry.exit.parent) != UI_NONE;
}

fn void declare_exits(UiDeclare* declare, bool previous_ready) @private {
    Ui* ui = declare.ui;
    foreach (&entry : ui.transitions) {
        if (!key_valid(&entry.key) || entry.declared == ui.update_serial) continue;

        entry.exiting = previous_ready && exit_continues(ui, entry);
    }

    foreach (&entry : ui.transitions) {
        if (declare.failure) return;

        if (key_valid(&entry.key) && entry.exiting) declare_exit(declare, entry);
    }
}

fn void declare_exit(UiDeclare* declare, UiTransition* entry) @private {
    Ui* ui = declare.ui;
    uint source = entry.instance;
    UiInstance root = ui.previous.instances[source];
    UiExitRecord* record = &entry.exit;

    // Only a floating element has an offset to start from.
    if (ui.previous.links[source].placement.floating.attach_to == NONE) {
        settle_track(&entry.tracks[UiAnimated.OFFSET.ordinal], {});
    }

    root.properties.width = { .sizing = FIXED, .value = record.size.x };
    root.properties.height = { .sizing = FIXED, .value = record.size.y };

    if (!step_exit(ui, &root, entry)) return;

    float parent_alpha = 1;
    if (record.parent) parent_alpha = ui.instances[lookup_instance(ui, record.parent)].alpha;

    UiPlacement placement = {
        .floating = {
            .offset               = {
                record.position.x + root.properties.offset.x,
                record.position.y + root.properties.offset.y,
            },
            .parent_id            = record.parent,
            .z_index              = ui.previous.links[source].z,
            .attach_points        = { .element = LEFT_TOP, .parent = LEFT_TOP },
            .pointer_capture_mode = PASSTHROUGH,
            .attach_to            = record.parent ? ELEMENT_WITH_ID : ROOT,
            .clip_to              = record.parent ? ATTACHED_PARENT : NONE,
        },
        .grid = UI_NONE,
        .list = UI_NONE,
    };

    entry.declared = ui.update_serial;
    entry.instance = ui.instance_count;
    declare_stored(
        declare:      declare,
        value:        &root,
        source:       source,
        parent_alpha: parent_alpha,
        placement:    &placement,
    );
}

fn void declare_stored(
    UiDeclare* declare,
    UiInstance* value,
    uint source,
    float parent_alpha,
    UiPlacement* placement,
) @private {
    Ui* ui = declare.ui;
    UiFrameStore* previous = &ui.previous;
    uint? placed = place_stored(ui, value, &previous.links[source]);
    if (catch excuse = placed) return fail_declare(declare, excuse);

    UiInstance* instance = &ui.instances[placed];
    UiInstanceLink* link = &ui.links[placed];
    if (placement) link.placement = *placement;

    instance.alpha = parent_alpha * instance.properties.opacity;
    open_instance(ui, instance, &link.placement);
    declare_stored_text(ui, instance, link);

    uint end = previous.links[source].subtree_end;
    for (uint child = source + 1; child < end; child = previous.links[child].subtree_end) {
        declare_stored(
            declare:      declare,
            value:        &previous.instances[child],
            source:       child,
            parent_alpha: instance.alpha,
            placement:    null,
        );

        if (declare.failure) break;
    }

    clay::close_element();
    link.subtree_end = ui.instance_count;
}

fn uint? place_stored(Ui* ui, UiInstance* value, UiInstanceLink* stored) @private {
    if (ui.instance_count == ui.instances.len) return c3d::CAPACITY_EXCEEDED~;

    uint index = ui.instance_count;
    UiInstance* instance = &ui.instances[index];
    UiInstanceLink* link = &ui.links[index];
    *instance = *value;
    instance.hit = false;
    *link = *stored;
    link.placement.floating.pointer_capture_mode = PASSTHROUGH;
    copy_stored_text(ui, instance, link)!;

    ui.instance_count++;
    instance.clay_id = assign_clay_id(ui, &instance.key, instance.element, index);

    return index;
}

fn void? copy_stored_text(Ui* ui, UiInstance* instance, UiInstanceLink* link) @private {
    UiFrameStore* previous = &ui.previous;
    uint stored_start = (uint)(instance.text.ptr - previous.text.ptr);
    uint start = ui.text_used;
    if (instance.text.len) instance.text = copy_text(ui, instance.text)!;

    if (link.placeholder.len) link.placeholder = copy_text(ui, link.placeholder)!;

    if (!instance.piece_count) return;

    if (instance.piece_count > ui.pieces.len - ui.piece_count) return c3d::CAPACITY_EXCEEDED~;

    uint first = ui.piece_count;
    foreach (piece : previous.pieces[instance.first_piece : instance.piece_count]) {
        piece.offset = piece.offset - stored_start + start;
        ui.pieces[ui.piece_count] = piece;
        ui.piece_count++;
    }

    instance.first_piece = first;
    ui.stats.text_pieces = ui.piece_count;
}

fn void declare_stored_text(Ui* ui, UiInstance* instance, UiInstanceLink* link) @private {
    switch (instance.element.kind) {
        case LABEL:
            if (!instance.element.span_count) clay::text(instance.text, text_config(ui, instance));
        case TEXT_FIELD:
            if (instance.text.len) {
                clay::text(instance.text, text_config(ui, instance));
            } else if (link.placeholder.len) {
                clay::text(link.placeholder, text_config(ui, instance, UI_PLACEHOLDER_ALPHA));
            }
        default:
            break;
    }
}

fn void record_exits(Ui* ui) @private {
    foreach (&entry : ui.transitions) {
        if (!key_valid(&entry.key) || entry.exiting || entry.declared != ui.update_serial) continue;

        UiInstance* instance = &ui.instances[entry.instance];
        if (exit_bits(ui, instance) == 0) continue;

        UiInstanceLink* link = &ui.links[entry.instance];
        clay::BoundingBox box = clay::get_element_data(clay::id(instance.clay_id)).bounding_box;
        Vec2 origin;
        if (link.parent) {
            clay::BoundingBox parent_box = clay::get_element_data(clay::id(link.parent)).bounding_box;
            origin = { parent_box.x, parent_box.y };
        }

        // The box already holds the offset of a floating element.
        Vec2 applied;
        if (link.placement.floating.attach_to != NONE) applied = instance.properties.offset;

        entry.exit = {
            .position = { box.x - origin.x - applied.x, box.y - origin.y - applied.y },
            .size     = { box.width, box.height },
            .parent   = link.parent,
        };
    }
}
