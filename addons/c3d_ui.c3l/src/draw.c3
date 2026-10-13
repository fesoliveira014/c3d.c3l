module c3d::ui;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render;
import clay;
import std::math;

const float UI_CARET_PIXELS @private = 1;
const float UI_UNDERLINE_POSITION @private = 0.12;  // em below the baseline; fonts carry no underline metrics
const float UI_UNDERLINE_THICKNESS @private = 0.06; // em, and never under one pixel

<*
 Append the laid-out documents to an overlay list.
 Builds outlines for glyphs met for the first time.
 @param [&inout] list : "Receives rectangles, glyph runs and clips."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn void? Ui.draw(&self, OverlayList* list) {
    self.stats.placement_hits = 0;
    self.stats.placement_misses = 0;
    self.stats.placement_clears = 0;
    if (!self.frame_ready) return;
    refresh_cache_fonts(self);
    foreach (&command : self.commands.commands()) {
        switch (command.command_type) {
            case SCISSOR_START:
                clay::BoundingBox box = command.bounding_box;
                list.push_clip(
                    { box.x * self.scale, box.y * self.scale },
                    { (box.x + box.width) * self.scale, (box.y + box.height) * self.scale },
                )!;
            case SCISSOR_END:
                list.pop_clip();
            case CUSTOM:
                draw_instance(
                    ui:         self,
                    list:       list,
                    instance:   command.render_data.custom.custom_data,
                    layout_box: command.bounding_box,
                )!;
            case TEXT:
                draw_text(self, list, command)!;
            default:
                break;
        }
    }
}

fn Vec4 scaled_box(Ui* ui, clay::BoundingBox box) @private {
    return { box.x * ui.scale, box.y * ui.scale, (box.x + box.width) * ui.scale, (box.y + box.height) * ui.scale };
}

fn OverlayRect styled_rect(Ui* ui, UiProperties* properties, Vec4 box) @private {
    OverlayRect rect = render::OVERLAY_RECT_DEFAULT;
    rect.min = box.xy;
    rect.max = box.zw;
    rect.corner_radii = properties.corner_radii * ui.scale;
    rect.fill = properties.fill;
    rect.border_widths = properties.border_widths * ui.scale;
    rect.border_color = properties.border_color;
    apply_skin(ui, &rect, &properties.skin);
    return rect;
}

fn void apply_skin(Ui* ui, OverlayRect* rect, UiSkin* skin) @private {
    if (!skin.image.generation || !ui.assets.textures.is_live(skin.image)) return;
    TextureDesc desc = ui.assets.texture(skin.image).desc;
    rect.texture = { .kind = ASSET, .asset = skin.image };
    Vec4 texels = { (float)desc.width, (float)desc.height, (float)desc.width, (float)desc.height };
    rect.slice_uv = skin.slice / texels;
    rect.slice_pixels = skin.slice * ui.scale;
    if (rect.fill.w == 0) rect.fill = { 1, 1, 1, 1 };
}

fn Vec4 faded(Vec4 color, float alpha) @private => { color.x, color.y, color.z, color.w * alpha };

fn bool rect_visible(OverlayRect* rect) @private {
    if (rect.fill.w > 0) return true;
    Vec4 widths = rect.border_widths;
    return rect.border_color.w > 0 && (widths.x > 0 || widths.y > 0 || widths.z > 0 || widths.w > 0);
}

fn void? draw_instance(
    Ui* ui,
    OverlayList* list,
    UiInstance* instance,
    clay::BoundingBox layout_box,
) @private {
    UiProperties* properties = &instance.properties;
    Vec4 box = scaled_box(ui, layout_box);
    OverlayRect rect = styled_rect(ui, properties, box);
    if (instance.element.kind == IMAGE) {
        rect.texture = instance.image;
        rect.uv_rect = instance.element.uv;
        if (rect.fill.w == 0) rect.fill = { 1, 1, 1, 1 };
    }
    rect.fill = faded(rect.fill, instance.alpha);
    rect.border_color = faded(rect.border_color, instance.alpha);
    if (rect_visible(&rect)) list.add_rect(rect)!;

    Vec4 padding = properties.padding * ui.scale;
    Vec4 content = { box.x + padding.x, box.y + padding.y, box.z - padding.z, box.w - padding.w };
    switch (instance.element.kind) {
        case BAR:
            draw_bar_fill(
                ui:       ui,
                list:     list,
                instance: instance,
                content:  content,
            )!;
        case GRID:
            draw_footprint(
                ui:      ui,
                list:    list,
                grid:    instance,
                content: content,
            )!;
        case TEXT_FIELD:
            if (instance.state.focused) draw_caret(
                ui:      ui,
                list:    list,
                field:   instance,
                content: content,
            )!;
        case LABEL:
            if (instance.element.span_count) draw_pieces(
                ui:       ui,
                list:     list,
                instance: instance,
                content:  content,
            )!;
        default:
            break;
    }
}

fn void? draw_bar_fill(
    Ui* ui,
    OverlayList* list,
    UiInstance* instance,
    Vec4 content,
) @private {
    if (instance.value <= 0) return;
    Vec4 fill = content;
    float width = content.z - content.x;
    float height = content.w - content.y;
    switch (instance.element.bar_direction) {
        case LEFT_TO_RIGHT: fill.z = content.x + width * instance.value;
        case RIGHT_TO_LEFT: fill.x = content.z - width * instance.value;
        case BOTTOM_TO_TOP: fill.y = content.w - height * instance.value;
        case TOP_TO_BOTTOM: fill.w = content.y + height * instance.value;
    }
    OverlayRect rect = render::OVERLAY_RECT_DEFAULT;
    rect.min = fill.xy;
    rect.max = fill.zw;
    rect.corner_radii = instance.properties.corner_radii * ui.scale;
    rect.fill = instance.properties.bar_fill;
    apply_skin(ui, &rect, &instance.properties.bar_skin);
    rect.fill = faded(rect.fill, instance.alpha);
    if (rect_visible(&rect)) list.add_rect(rect)!;
}

fn void? draw_footprint(
    Ui* ui,
    OverlayList* list,
    UiInstance* grid,
    Vec4 content,
) @private {
    if (!ui.drag.active || ui.drag.cell == UI_NO_CELL || !same_key(&ui.drag.target, &grid.key)) return;
    if (grid.properties.highlight.w <= 0) return;
    UiElement* element = grid.element;
    Vec2 cell = element.cell_size * ui.scale;
    uint column = ui.drag.cell % element.columns;
    uint row = ui.drag.cell / element.columns;
    OverlayRect rect = render::OVERLAY_RECT_DEFAULT;
    rect.min = { content.x + column * cell.x, content.y + row * cell.y };
    rect.max = rect.min + (Vec2){ ui.drag.span_width * cell.x, ui.drag.span_height * cell.y };
    rect.fill = faded(grid.properties.highlight, grid.alpha);
    list.add_rect(rect)!;
}

fn void? draw_caret(
    Ui* ui,
    OverlayList* list,
    UiInstance* field,
    Vec4 content,
) @private {
    UiProperties* properties = &field.properties;
    float prefix = measure_line(
        ui:        ui,
        font_set:  properties.font_set,
        text:      (String)ui.field[:ui.caret],
        font_size: properties.font_size,
    );
    float height = line_height(ui, properties) * ui.scale;
    float top = content.y + (content.w - content.y - height) / 2;
    OverlayRect rect = render::OVERLAY_RECT_DEFAULT;
    rect.min = { math::round(content.x + prefix * ui.scale), top };
    rect.max = { rect.min.x + UI_CARET_PIXELS, top + height };
    rect.fill = faded(properties.text_color, field.alpha);
    list.add_rect(rect)!;
}

fn void? draw_text(Ui* ui, OverlayList* list, clay::RenderCommand* command) @private {
    clay::TextRenderData* data = &command.render_data.text;
    String line = data.string_contents.str();
    if (!line.len) return;
    uint font_set = data.font_id;
    UiPlacementLine* placed = cached_line(ui, font_set, line)!;

    float font_size = data.font_size;
    FontMetrics metrics = ui.assets.font_metrics(ui.font_sets[font_set].fonts[0]);
    clay::BoundingBox box = command.bounding_box;
    float extent = (metrics.ascent - metrics.descent) * font_size;
    float baseline = box.y + (box.height - extent) / 2 + metrics.ascent * font_size;
    Vec2 origin = { box.x * ui.scale, math::round(baseline * ui.scale) };
    float size_pixels = font_size * ui.scale;
    UiInstance* instance = command.user_data;
    Vec4 color = faded({ data.text_color.r, data.text_color.g, data.text_color.b, data.text_color.a }, instance.alpha);

    Vec4 pixels = scaled_box(ui, box);
    if (instance.properties.text_highlight.w > 0) {
        add_fill(list, pixels, faded(instance.properties.text_highlight, instance.alpha))!;
    }

    add_line_glyphs(
        ui:          ui,
        list:        list,
        placed:      placed,
        origin:      origin,
        size_pixels: size_pixels,
        color:       color,
    )!;

    if (instance.properties.underline) add_underline(
        list:        list,
        left:        pixels.x,
        right:       pixels.z,
        baseline:    origin.y,
        size_pixels: size_pixels,
        color:       color,
    )!;
}

fn void? draw_pieces(
    Ui* ui,
    OverlayList* list,
    UiInstance* instance,
    Vec4 content,
) @private {
    UiProperties* properties = &instance.properties;
    float content_width = (content.z - content.x) / ui.scale;

    for (uint index = instance.first_piece; index < instance.first_piece + instance.piece_count; index++) {
        UiTextPiece* piece = &ui.pieces[index];
        float slack = math::max(content_width - piece.line_width, 0.0f);
        float line_start;
        switch (properties.text_align) {
            case LEFT: line_start = 0;
            case CENTER: line_start = slack / 2;
            case RIGHT: line_start = slack;
        }

        float left = content.x + (line_start + piece.x) * ui.scale;
        float right = left + piece.width * ui.scale;
        float top = content.y + piece.top * ui.scale;
        Vec4 color = faded(piece.color, instance.alpha);
        Vec4 highlight = faded(piece.highlight, instance.alpha);
        if (piece.highlight.w > 0) {
            add_fill(list, { left, top, right, top + piece.height * ui.scale }, highlight)!;
        }

        float size_pixels = piece.font_size * ui.scale;
        float baseline = math::round(content.y + piece.baseline * ui.scale);
        UiPlacementLine* placed = cached_line(ui, piece.font_set, piece_text(ui, piece))!;
        add_line_glyphs(
            ui:          ui,
            list:        list,
            placed:      placed,
            origin:      { left, baseline },
            size_pixels: size_pixels,
            color:       color,
        )!;

        if (piece.underline) add_underline(
            list:        list,
            left:        left,
            right:       right,
            baseline:    baseline,
            size_pixels: size_pixels,
            color:       color,
        )!;
    }
}

fn void? add_line_glyphs(
    Ui* ui,
    OverlayList* list,
    UiPlacementLine* placed,
    Vec2 origin,
    float size_pixels,
    Vec4 color,
) @private {
    for (uint index = placed.first_segment; index < placed.first_segment + placed.segment_count; index++) {
        UiPlacementSegment* segment = &ui.cache.segments[index];
        if (!segment.count) continue;
        list.add_glyphs({
            .font        = segment.font,
            .glyphs      = ui.cache.glyphs[segment.first : segment.count],
            .origin      = { origin.x + segment.x_em * size_pixels, origin.y },
            .size_pixels = size_pixels,
            .color       = color,
        })!;
    }
}

fn void? add_fill(OverlayList* list, Vec4 box, Vec4 color) @private {
    OverlayRect rect = render::OVERLAY_RECT_DEFAULT;
    rect.min = box.xy;
    rect.max = box.zw;
    rect.fill = color;
    list.add_rect(rect)!;
}

fn void? add_underline(
    OverlayList* list,
    float left,
    float right,
    float baseline,
    float size_pixels,
    Vec4 color,
) @private {
    float top = math::round(baseline + UI_UNDERLINE_POSITION * size_pixels);
    float thickness = math::max(math::round(UI_UNDERLINE_THICKNESS * size_pixels), 1.0f);
    add_fill(list, { left, top, right, top + thickness }, color)!;
}
