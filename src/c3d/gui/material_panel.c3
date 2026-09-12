module c3d::gui;

import c3d;
import c3d::asset;
import imgui;

<*
 Edit material factors and advance the revision on changes.
 @param [&inout] assets : "Live store; called during the current GUI frame."
 @return? c3d::INVALID_ID
*>
fn void? material_panel(AssetStore* assets, MaterialId material) {
    MaterialAsset* record = assets.materials.try_get(material)!;

    bool visible = imgui::begin("Material", null, {});
    defer imgui::end();
    if (!visible) return;

    imgui::push_item_width(imgui::get_content_region_avail().x * 0.5f);
    defer imgui::pop_item_width();

    bool changed;
    switch (record.data.kind) {
        case BASIC:
            changed = imgui::color_edit3("Color", (float*)&record.data.basic.color, {});
        case STANDARD:
            changed |= edit_material_color("Base color", (float*)&record.data.standard.base_color, 4);
            changed |= edit_material_factor(
                label: "Metallic",
                value: &record.data.standard.metallic,
                minimum: 0,
                maximum: 1,
            );
            changed |= edit_material_factor(
                label: "Roughness",
                value: &record.data.standard.roughness,
                minimum: 0,
                maximum: 1,
            );
            changed |= edit_material_factor(
                label: "Normal scale",
                value: &record.data.standard.normal_scale,
                minimum: -float::max,
                maximum: float::max,
            );
            changed |= edit_material_factor(
                label: "Occlusion strength",
                value: &record.data.standard.occlusion_strength,
                minimum: 0,
                maximum: 1,
            );
            changed |= edit_material_color("Emissive", (float*)&record.data.standard.emissive, 3);
            changed |= edit_material_factor(
                label: "Emissive strength",
                value: &record.data.standard.emissive_strength,
                minimum: 0,
                maximum: float::max,
            );
        case TOON:
            changed = edit_material_color("Color", (float*)&record.data.toon.color, 4);
    }
    if (changed) assets.mark_material_dirty(material);
}

fn bool edit_material_factor(
    ZString label,
    float* value,
    float minimum,
    float maximum,
) @local {
    float edited = *value;
    if (!imgui::drag_float_ex(
        label: label,
        v: &edited,
        v_speed: 0.01f,
        v_min: minimum,
        v_max: maximum,
        format: "%.3f",
        flags: imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    )) return false;
    if (!(edited >= minimum && edited <= maximum) || edited == *value) return false;
    *value = edited;
    return true;
}

fn bool edit_material_color(ZString label, float* value, usz channels) @local {
    float[4] edited;
    for (usz index = 0; index < channels; index++) edited[index] = value[index];
    bool changed = channels == 4
        ? imgui::color_edit4(label, &edited[0], {})
        : imgui::color_edit3(label, &edited[0], { .hdr = true, .float_ = true });
    if (!changed) return false;

    float maximum = channels == 4 ? 1 : float::max;
    changed = false;
    for (usz index = 0; index < channels; index++) {
        if (!(edited[index] >= 0 && edited[index] <= maximum)) return false;
        changed |= edited[index] != value[index];
    }
    if (changed) {
        for (usz index = 0; index < channels; index++) value[index] = edited[index];
    }
    return changed;
}
