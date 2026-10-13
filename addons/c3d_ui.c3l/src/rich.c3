module c3d::ui;

import c3d;
import c3d::asset;
import clay;
import std::math;

struct UiTextPiece @private {
    uint  offset;     // bytes in the frame text arena
    uint  length;
    uint  font_set;
    float font_size;  // layout units
    Vec4  color;
    Vec4  highlight;
    bool  underline;
    float x;          // layout units from the line start
    float width;
    float baseline;   // layout units from the content top
    float top;        // line top
    float height;     // line height
    float line_width; // for text_align
}

struct UiRichRun @private {
    uint         offset;     // bytes in the frame text arena
    uint         length;
    UiProperties properties;
}

struct UiRichFlow @private {
    Ui*           ui;
    UiProperties* label;
    float         wrap_width;
    uint          text_start; // first byte of the label in the frame text arena
    uint          line_first; // first piece of the open line
    uint          lines;
    float         x;          // width of the open line
    float         y;          // top of the open line
    float         width;      // widest finished line
}

struct UiLineMetrics @private {
    float ascent;
    float descent;
    float height;
}

fn Vec2 padding_extent(UiProperties* properties) @private {
    return {
        (float)clay_units(properties.padding.x) + (float)clay_units(properties.padding.z),
        (float)clay_units(properties.padding.y) + (float)clay_units(properties.padding.w),
    };
}

fn float rich_wrap_width(UiProperties* properties) @private {
    if (properties.wrap != WORDS) return float::max;

    float padding = padding_extent(properties).x;
    if (properties.width.sizing == FIXED) return math::max(properties.width.value - padding, 0.0f);
    if (properties.max_width < float::max) return math::max(properties.max_width - padding, 0.0f);

    return float::max;
}

fn void size_rich_label(UiInstance* instance, clay::Sizing* sizing) @private {
    UiProperties* properties = &instance.properties;
    Vec2 padding = padding_extent(properties);
    if (properties.width.sizing == FIT) {
        float width = instance.text_size.x + padding.x;
        sizing.width = clay::fixed(math::min(math::max(width, properties.min_width), properties.max_width));
    }

    if (properties.height.sizing == FIT) {
        float height = instance.text_size.y + padding.y;
        sizing.height = clay::fixed(math::min(math::max(height, properties.min_height), properties.max_height));
    }
}

fn String run_text(Ui* ui, UiRichRun* run) @private => (String)ui.text[run.offset : run.length];

fn String piece_text(Ui* ui, UiTextPiece* piece) @private => (String)ui.text[piece.offset : piece.length];

fn UiProperties run_properties(Ui* ui, UiInstance* instance, uint span) @private {
    UiProperties properties = instance.properties;
    UiSpan[] spans = instance.document.spans;
    uint[UI_SPAN_DEPTH] chain;
    uint depth;
    for (uint at = span; at != UI_NONE; at = spans[at].parent) {
        chain[depth] = at;
        depth++;
    }

    ulong mask;
    while (depth > 0) {
        depth--;
        UiStyle* style = &ui.styles.styles[spans[chain[depth]].style];
        UiProperties overrides = style_properties(style, instance.state);
        apply_properties(
            target:      &properties,
            target_mask: &mask,
            source:      &overrides,
            source_mask: style_mask(style, instance.state),
        );
    }

    return properties;
}

fn void? layout_rich_label(Ui* ui, UiInstance* instance, UiScope* scope) @private {
    UiElement* element = instance.element;
    UiDocument* document = instance.document;
    UiRichFlow flow = {
        .ui         = ui,
        .label      = &instance.properties,
        .wrap_width = rich_wrap_width(&instance.properties),
        .text_start = ui.text_used,
        .line_first = ui.piece_count,
    };

    instance.first_piece = ui.piece_count;

    uint segment = element.text_first;
    uint segment_end = element.text_first + element.text_count;
    while (segment < segment_end) {
        uint span = document.segments[segment].span;
        UiRichRun run = { .offset = ui.text_used };
        while (segment < segment_end && document.segments[segment].span == span) {
            append_segment(ui, document, &document.segments[segment], scope)!;
            segment++;
        }

        run.length = ui.text_used - run.offset;
        if (!valid_utf8(run_text(ui, &run))) return c3d::INVALID_ARGUMENT~;

        run.properties = run_properties(ui, instance, span);
        flow_run(&flow, &run)!;
    }

    if (flow.line_first < ui.piece_count || !flow.lines) finish_line(&flow, ui.piece_count);

    instance.text = (String)ui.text[flow.text_start : ui.text_used - flow.text_start];
    instance.piece_count = ui.piece_count - instance.first_piece;
    instance.text_size = { flow.width, flow.y };
    ui.stats.text_pieces = ui.piece_count;
}

fn UiTextPiece run_piece(UiRichRun* run, uint offset, usz length) @private {
    UiProperties* properties = &run.properties;
    return {
        .offset    = offset,
        .length    = (uint)length,
        .font_set  = properties.font_set,
        .font_size = properties.font_size,
        .color     = properties.text_color,
        .highlight = properties.text_highlight,
        .underline = properties.underline,
    };
}

fn float measure_piece(Ui* ui, UiTextPiece* piece) @private {
    return measure_line(
        ui:        ui,
        font_set:  piece.font_set,
        text:      piece_text(ui, piece),
        font_size: piece.font_size,
    );
}

fn usz find_break(String text, usz from, UiWrap wrap) @private {
    for (usz at = from; at < text.len; at++) {
        if (text[at] == '\n' && wrap != NONE) return at;
        if (text[at] == ' ' && wrap == WORDS) return at;
    }

    return text.len;
}

fn void? flow_run(UiRichFlow* flow, UiRichRun* run) @private {
    if (!run.length) return;

    Ui* ui = flow.ui;
    String text = run_text(ui, run);
    UiTextPiece whole = run_piece(run, run.offset, run.length);
    whole.width = measure_piece(ui, &whole);
    bool has_newline = flow.label.wrap != NONE && @ok(text.index_of_char('\n'));
    if (!has_newline && flow.x + whole.width <= flow.wrap_width) return push_piece(flow, &whole);

    usz cursor;
    while (cursor < text.len) {
        usz stop = find_break(text, cursor, flow.label.wrap);
        if (stop > cursor) {
            place_chunk(
                flow:   flow,
                run:    run,
                offset: run.offset + (uint)cursor,
                length: stop - cursor,
                word:   true,
            )!;
        }

        if (stop < text.len && text[stop] == '\n') {
            end_line(flow);
        } else if (stop < text.len) {
            place_chunk(
                flow:   flow,
                run:    run,
                offset: run.offset + (uint)stop,
                length: 1,
                word:   false,
            )!;
        }

        cursor = stop + 1;
    }
}

fn void? place_chunk(
    UiRichFlow* flow,
    UiRichRun* run,
    uint offset,
    usz length,
    bool word,
) @private {
    Ui* ui = flow.ui;
    UiTextPiece chunk = run_piece(run, offset, length);
    chunk.width = measure_piece(ui, &chunk);

    if (word && ui.piece_count > flow.line_first && flow.x + chunk.width > flow.wrap_width) {
        if (continues_word(flow, run, offset)) {
            carry_word_to_next_line(flow)!;
        } else {
            wrap_line(flow);
        }
    }

    if (ui.piece_count > flow.line_first) {
        UiTextPiece* last = &ui.pieces[ui.piece_count - 1];
        if (last.offset >= run.offset && last.offset + last.length == offset) {
            last.length += (uint)length;
            last.width += chunk.width;
            flow.x += chunk.width;
            return;
        }
    }

    push_piece(flow, &chunk)!;
}

fn bool continues_word(UiRichFlow* flow, UiRichRun* run, uint offset) @private {
    if (offset != run.offset || offset == flow.text_start) return false;

    char previous = flow.ui.text[offset - 1];
    return previous != ' ' && previous != '\n';
}

fn void? push_piece(UiRichFlow* flow, UiTextPiece* piece) @private {
    Ui* ui = flow.ui;
    if (ui.piece_count == ui.pieces.len) return c3d::CAPACITY_EXCEEDED~;

    piece.x = flow.x;
    ui.pieces[ui.piece_count] = *piece;
    ui.piece_count++;
    flow.x += piece.width;
}

fn void wrap_line(UiRichFlow* flow) @private {
    Ui* ui = flow.ui;
    if (ui.piece_count > flow.line_first) trim_trailing_space(flow);

    end_line(flow);
}

fn void trim_trailing_space(UiRichFlow* flow) @private {
    Ui* ui = flow.ui;
    UiTextPiece* last = &ui.pieces[ui.piece_count - 1];
    if (ui.text[last.offset + last.length - 1] != ' ') return;

    UiTextPiece space = *last;
    space.offset = last.offset + last.length - 1;
    space.length = 1;
    float space_width = measure_piece(ui, &space);
    flow.x -= space_width;
    if (last.length == 1) {
        ui.piece_count--;
        return;
    }

    last.length--;
    last.width -= space_width;
}

fn void end_line(UiRichFlow* flow) @private {
    finish_line(flow, flow.ui.piece_count);
    flow.line_first = flow.ui.piece_count;
    flow.x = 0;
}

fn UiLineMetrics text_metrics(
    Ui* ui,
    uint font_set,
    float font_size,
    float fixed_height,
) @private {
    FontMetrics metrics = ui.assets.font_metrics(ui.font_sets[font_set].fonts[0]);
    return {
        .ascent  = metrics.ascent * font_size,
        .descent = -metrics.descent * font_size,
        .height  = text_line_height(
            ui:           ui,
            font_set:     font_set,
            font_size:    font_size,
            fixed_height: fixed_height,
        ),
    };
}

fn void finish_line(UiRichFlow* flow, uint end) @private {
    Ui* ui = flow.ui;
    UiProperties* label = flow.label;
    UiLineMetrics line;
    if (end == flow.line_first) line = text_metrics(ui, label.font_set, label.font_size, label.line_height);

    for (uint index = flow.line_first; index < end; index++) {
        UiTextPiece* piece = &ui.pieces[index];
        UiLineMetrics metrics = text_metrics(ui, piece.font_set, piece.font_size, label.line_height);
        line.ascent = math::max(line.ascent, metrics.ascent);
        line.descent = math::max(line.descent, metrics.descent);
        line.height = math::max(line.height, metrics.height);
    }

    float line_width;
    if (end > flow.line_first) line_width = ui.pieces[end - 1].x + ui.pieces[end - 1].width;

    float baseline = flow.y + (line.height - (line.ascent + line.descent)) / 2 + line.ascent;
    for (uint index = flow.line_first; index < end; index++) {
        UiTextPiece* piece = &ui.pieces[index];
        piece.top = flow.y;
        piece.height = line.height;
        piece.baseline = baseline;
        piece.line_width = line_width;
    }

    flow.y += line.height;
    flow.width = math::max(flow.width, line_width);
    flow.lines++;
}

fn usz last_space(String text) @private {
    usz at = text.len;
    while (at > 0) {
        at--;
        if (text[at] == ' ') return at;
    }

    return text.len;
}

// Breaks fall only at spaces, so a word that spans runs moves to the next line whole.
fn void? carry_word_to_next_line(UiRichFlow* flow) @private {
    Ui* ui = flow.ui;
    uint index = ui.piece_count;
    while (index > flow.line_first) {
        index--;
        usz space = last_space(piece_text(ui, &ui.pieces[index]));
        if (space == ui.pieces[index].length) continue;

        return split_piece_at_space(flow, index, space);
    }
}

fn void? split_piece_at_space(UiRichFlow* flow, uint index, usz space) @private {
    Ui* ui = flow.ui;
    UiTextPiece original = ui.pieces[index];
    UiTextPiece head = original;
    head.length = (uint)space;
    UiTextPiece tail = original;
    tail.offset = original.offset + (uint)space + 1;
    tail.length = original.length - (uint)space - 1;
    head.width = head.length ? measure_piece(ui, &head) : 0;
    tail.width = tail.length ? measure_piece(ui, &tail) : 0;
    tail.x = original.x + original.width - tail.width;

    uint kept = (head.length ? 1 : 0) + (tail.length ? 1 : 0);
    if (kept == 2) {
        if (ui.piece_count == ui.pieces.len) return c3d::CAPACITY_EXCEEDED~;

        for (uint at = ui.piece_count; at > index + 1; at--) ui.pieces[at] = ui.pieces[at - 1];

        ui.piece_count++;
    } else if (kept == 0) {
        for (uint at = index + 1; at < ui.piece_count; at++) ui.pieces[at - 1] = ui.pieces[at];

        ui.piece_count--;
    }

    uint moved_first = index;
    if (head.length) {
        ui.pieces[moved_first] = head;
        moved_first++;
    }

    if (tail.length) ui.pieces[moved_first] = tail;

    float shift = original.x + original.width - tail.width;
    for (uint at = moved_first; at < ui.piece_count; at++) ui.pieces[at].x -= shift;

    finish_line(flow, moved_first);
    flow.line_first = moved_first;
    flow.x = 0;
    if (moved_first < ui.piece_count) {
        UiTextPiece* last = &ui.pieces[ui.piece_count - 1];
        flow.x = last.x + last.width;
    }
}
