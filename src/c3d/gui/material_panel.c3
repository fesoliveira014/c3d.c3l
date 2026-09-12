module c3d::gui;

import c3d;
import c3d::asset;
import imgui;

const float MIN_EDITABLE_RIM_POWER @local = 0.01f; // Matches the drag step within the positive contract.

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

    bool changed = edit_material_common(&record.data.common);
    switch (record.data.kind) {
        case BASIC:
            changed |= edit_material_color("Color", (float*)&record.data.basic.color, 4);
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
            changed |= edit_material_color("Color", (float*)&record.data.toon.color, 4);
            changed |= edit_material_steps(&record.data.toon.steps);
            changed |= edit_material_color("Rim color", (float*)&record.data.toon.rim_color, 3);
            changed |= edit_material_factor(
                label: "Rim strength",
                value: &record.data.toon.rim_strength,
                minimum: 0,
                maximum: float::max,
            );
            changed |= edit_material_factor(
                label: "Rim power",
                value: &record.data.toon.rim_power,
                minimum: MIN_EDITABLE_RIM_POWER,
                maximum: float::max,
            );
    }
    if (changed) assets.mark_material_dirty(material);
}

fn bool edit_material_common(MaterialCommon* common) @local {
    bool changed;

    imgui::separator_text("Surface");
    if (imgui::radio_button("Opaque", common.alpha_mode == OPAQUE)) {
        common.alpha_mode = OPAQUE;
        changed = true;
    }
    imgui::same_line();
    if (imgui::radio_button("Mask", common.alpha_mode == MASK)) {
        common.alpha_mode = MASK;
        changed = true;
    }
    imgui::same_line();
    if (imgui::radio_button("Blend", common.alpha_mode == BLEND)) {
        common.alpha_mode = BLEND;
        changed = true;
    }

    changed |= edit_material_factor(
        label: "Alpha cutoff",
        value: &common.alpha_cutoff,
        minimum: 0,
        maximum: 1,
    );
    changed |= imgui::checkbox("Double sided", &common.double_sided);
    changed |= imgui::checkbox("Depth test", &common.depth_test);

    if (common.alpha_mode == BLEND) {
        bool effective_depth_write;
        imgui::begin_disabled(true);
        imgui::checkbox("Depth write", &effective_depth_write);
        imgui::end_disabled();
        imgui::text_disabled("Blended draws always leave depth writes off.");
    } else {
        changed |= imgui::checkbox("Depth write", &common.depth_write);
    }
    changed |= imgui::checkbox("Wireframe", &common.wireframe);
    imgui::separator_text("Factors");
    return changed;
}

fn bool edit_material_steps(uint* steps) @local {
    int edited = *steps > (uint)int::max ? int::max : (int)*steps;
    if (!imgui::drag_int_ex(
        label: "Steps",
        v: &edited,
        v_speed: 0.1f,
        v_min: 2,
        v_max: int::max,
        format: "%d",
        flags: imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    )) return false;
    if (edited < 2 || (uint)edited == *steps) return false;
    *steps = (uint)edited;
    return true;
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
