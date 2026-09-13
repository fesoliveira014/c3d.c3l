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
            changed |= edit_standard_params(&record.data.standard);
        case PHYSICAL:
            changed |= edit_standard_params(&record.data.physical.standard);
            imgui::separator_text("Clearcoat");
            changed |= edit_material_factor(
                label: "Coat strength",
                value: &record.data.physical.clearcoat,
                minimum: 0,
                maximum: 1,
            );
            changed |= edit_material_factor(
                label: "Coat roughness",
                value: &record.data.physical.clearcoat_roughness,
                minimum: 0,
                maximum: 1,
            );
            changed |= edit_material_factor(
                label: "Coat normal scale",
                value: &record.data.physical.clearcoat_normal_scale,
                minimum: -float::max,
                maximum: float::max,
            );
            imgui::separator_text("Sheen");
            changed |= edit_material_color(
                label: "Sheen color",
                value: (float*)&record.data.physical.sheen_color,
                channels: 3,
                hdr_rgb: false,
            );
            changed |= edit_material_factor(
                label: "Sheen roughness",
                value: &record.data.physical.sheen_roughness,
                minimum: 0,
                maximum: 1,
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

fn bool edit_standard_params(StandardParams* params) @local {
    bool changed;
    changed |= edit_material_color("Base color", (float*)&params.base_color, 4);
    changed |= edit_material_factor(
        label: "Metallic",
        value: &params.metallic,
        minimum: 0,
        maximum: 1,
    );
    changed |= edit_material_factor(
        label: "Roughness",
        value: &params.roughness,
        minimum: 0,
        maximum: 1,
    );
    changed |= edit_material_factor(
        label: "Normal scale",
        value: &params.normal_scale,
        minimum: -float::max,
        maximum: float::max,
    );
    changed |= edit_material_factor(
        label: "Occlusion strength",
        value: &params.occlusion_strength,
        minimum: 0,
        maximum: 1,
    );
    changed |= edit_material_color("Emissive", (float*)&params.emissive, 3);
    changed |= edit_material_factor(
        label: "Emissive strength",
        value: &params.emissive_strength,
        minimum: 0,
        maximum: float::max,
    );
    return changed;
}

fn bool edit_material_common(MaterialCommon* common) @local {
    bool changed;
    AlphaMode selected_alpha_mode = common.alpha_mode;

    imgui::separator_text("Surface");
    if (imgui::radio_button("Opaque", selected_alpha_mode == OPAQUE)) selected_alpha_mode = OPAQUE;
    imgui::same_line();
    if (imgui::radio_button("Mask", selected_alpha_mode == MASK)) selected_alpha_mode = MASK;
    imgui::same_line();
    if (imgui::radio_button("Blend", selected_alpha_mode == BLEND)) selected_alpha_mode = BLEND;
    if (selected_alpha_mode != common.alpha_mode) {
        common.alpha_mode = selected_alpha_mode;
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
    uint edited = *steps;
    uint minimum = 2;
    uint maximum = uint::max;
    if (!imgui::drag_scalar_ex(
        label: "Steps",
        data_type: imgui::DATA_TYPE_U32,
        p_data: &edited,
        v_speed: 0.1f,
        p_min: &minimum,
        p_max: &maximum,
        format: "%u",
        flags: imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    )) return false;
    if (edited == *steps) return false;
    *steps = edited;
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

fn bool edit_material_color(
    ZString label,
    float* value,
    usz channels,
    bool hdr_rgb = true,
) @local {
    float[4] edited;
    for (usz index = 0; index < channels; index++) edited[index] = value[index];
    bool changed = channels == 4
        ? imgui::color_edit4(label, &edited[0], {})
        : imgui::color_edit3(label, &edited[0], { .hdr = hdr_rgb, .float_ = true });
    if (!changed) return false;

    float maximum = channels == 4 || !hdr_rgb ? 1 : float::max;
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
