module c3d::gui;

import c3d;
import c3d::render;
import c3d::render::post;
import imgui;
import std::math;

const float CONTRAST_MAX @local = 2;
const float SATURATION_MAX @local = 2;
const float BALANCE_LIMIT @local = 1;
const float LIFT_LIMIT @local = 1;
const float GAMMA_MIN @local = 0.2f;
const float GAMMA_MAX @local = 3;
const float GAIN_MAX @local = 3;
const float TRIPLE_DRAG_SPEED @local = 0.005f;
const float BLOOM_THRESHOLD_MAX @local = 8;
const float BLOOM_KNEE_MAX @local = 1;
const float BLOOM_INTENSITY_MAX @local = 1;
const float FOCUS_DISTANCE_MIN @local = 0.1f;
const float FOCUS_DISTANCE_MAX @local = 50;
const float FOCAL_LENGTH_MIN @local = 0.005f;
const float FOCAL_LENGTH_MAX @local = 0.3f;
const float APERTURE_MIN @local = 0.7f;
const float APERTURE_MAX @local = 22;
const float MAX_COC_MIN @local = 1;
const float MAX_COC_MAX @local = 32;
const float SHUTTER_MAX @local = 1;
const float MAX_VELOCITY_MIN @local = 1;
const float MAX_VELOCITY_MAX @local = 128;
const float CURRENT_WEIGHT_MIN @local = 0.01f;
const float CLIP_GAMMA_MIN @local = 0.25f;
const float CLIP_GAMMA_MAX @local = 3;
const float DEPTH_TOLERANCE_MIN @local = 0.001f;
const float DEPTH_TOLERANCE_MAX @local = 0.5f;
const float VELOCITY_THRESHOLD_MIN @local = 0.1f;
const float VELOCITY_THRESHOLD_MAX @local = 16;
const ZString[Tonemap::len] TONEMAP_LABELS @local = { "None", "ACES", "AgX", "Reinhard" };
const ZString[AntiAliasing::len] ANTI_ALIASING_LABELS @local = { "None", "FXAA", "TAA" };
const ZString[TaaDebug::len] TAA_DEBUG_LABELS @local = { "None", "Velocity", "Rejection", "History weight" };

<*
 Edit the view's post settings; the caller applies them with configure_view.
 @param [&inout] desc : "Edited in place."
 @param lut : "Offered by a checkbox when live; zero hides it."
 @return "Whether any setting changed."
*>
fn bool post_panel(ViewDesc* desc, TextureId lut) {
    bool visible = imgui::begin("Post", null, {});
    defer imgui::end();
    if (!visible) return false;

    GradeParams* grade = &desc.post.grade;
    bool changed;
    int tonemap = (int)grade.tonemap.ordinal;
    if (imgui::combo_char("Tonemap", &tonemap, &TONEMAP_LABELS[0], Tonemap::len)) {
        grade.tonemap = (Tonemap)tonemap;
        changed = true;
    }
    changed |= anti_aliasing_combo("Anti-aliasing", &desc.post.anti_aliasing);
    if (lut.generation) {
        bool lut_enabled = grade.lut.generation != 0;
        if (imgui::checkbox("LUT", &lut_enabled)) {
            grade.lut = lut_enabled ? lut : (TextureId){};
            changed = true;
        }
    }

    imgui::separator_text("Grade");
    changed |= edit_grade_factor("Contrast", &grade.contrast, 0, CONTRAST_MAX);
    changed |= edit_grade_factor("Saturation", &grade.saturation, 0, SATURATION_MAX);
    changed |= edit_grade_factor("Temperature", &grade.temperature, -BALANCE_LIMIT, BALANCE_LIMIT);
    changed |= edit_grade_factor("Tint", &grade.tint, -BALANCE_LIMIT, BALANCE_LIMIT);
    changed |= edit_grade_triple("Lift", &grade.lift, -LIFT_LIMIT, LIFT_LIMIT);
    changed |= edit_grade_triple("Gamma", &grade.gamma, GAMMA_MIN, GAMMA_MAX);
    changed |= edit_grade_triple("Gain", &grade.gain, 0, GAIN_MAX);

    if (imgui::collapsing_header("Bloom", {})) {
        BloomParams* bloom = &desc.post.bloom_params;
        changed |= imgui::checkbox("Enable bloom", &desc.post.bloom);
        changed |= edit_grade_factor("Threshold", &bloom.threshold, 0, BLOOM_THRESHOLD_MAX);
        changed |= edit_grade_factor("Knee", &bloom.knee, 0, BLOOM_KNEE_MAX);
        changed |= edit_grade_factor("Intensity", &bloom.intensity, 0, BLOOM_INTENSITY_MAX);
        changed |= edit_level_count("Levels", &bloom.levels, 1, post::BLOOM_MAX_LEVELS);
    }
    if (imgui::collapsing_header("Depth of field", {})) {
        DofParams* dof = &desc.post.dof_params;
        changed |= imgui::checkbox("Enable depth of field", &desc.post.depth_of_field);
        changed |= edit_grade_factor("Focus distance", &dof.focus_distance, FOCUS_DISTANCE_MIN, FOCUS_DISTANCE_MAX);
        changed |= edit_grade_factor("Focal length", &dof.focal_length, FOCAL_LENGTH_MIN, FOCAL_LENGTH_MAX);
        changed |= edit_grade_factor("Aperture", &dof.aperture, APERTURE_MIN, APERTURE_MAX);
        changed |= edit_grade_factor("Max CoC", &dof.max_coc, MAX_COC_MIN, MAX_COC_MAX);
    }
    if (imgui::collapsing_header("Motion blur", {})) {
        MotionBlurParams* blur = &desc.post.motion_blur_params;
        changed |= imgui::checkbox("Enable motion blur", &desc.post.motion_blur);
        changed |= edit_grade_factor("Shutter", &blur.shutter, 0, SHUTTER_MAX);
        changed |= edit_level_count("Samples", &blur.samples, 1, post::MOTION_BLUR_MAX_SAMPLES);
        changed |= edit_grade_factor("Max velocity", &blur.max_velocity, MAX_VELOCITY_MIN, MAX_VELOCITY_MAX);
    }
    if (desc.post.anti_aliasing == AntiAliasing.TAA && imgui::collapsing_header("Temporal AA", {})) {
        TaaParams* taa = &desc.post.taa_params;
        changed |= edit_grade_factor(
            label:   "Current weight",
            value:   &taa.current_weight,
            minimum: CURRENT_WEIGHT_MIN,
            maximum: 1,
        );
        changed |= edit_grade_factor(
            label:   "Clip gamma",
            value:   &taa.clip_gamma,
            minimum: CLIP_GAMMA_MIN,
            maximum: CLIP_GAMMA_MAX,
        );
        changed |= edit_grade_factor(
            label:   "Depth tolerance",
            value:   &taa.depth_tolerance,
            minimum: DEPTH_TOLERANCE_MIN,
            maximum: DEPTH_TOLERANCE_MAX,
        );
        changed |= edit_grade_factor(
            label:   "Velocity threshold",
            value:   &taa.velocity_threshold,
            minimum: VELOCITY_THRESHOLD_MIN,
            maximum: VELOCITY_THRESHOLD_MAX,
        );
        changed |= edit_grade_factor(
            label:   "Mip bias",
            value:   &taa.mip_bias,
            minimum: post::TAA_MIP_BIAS_MIN,
            maximum: 0,
        );
        int debug = (int)taa.debug.ordinal;
        if (imgui::combo_char(
            label:        "Debug",
            current_item: &debug,
            items:        &TAA_DEBUG_LABELS[0],
            items_count:  TaaDebug::len,
        )) {
            taa.debug = (TaaDebug)debug;
            changed = true;
        }
    }

    return changed;
}

<*
 Combo selecting a view's anti-aliasing filter.
 @param [&inout] anti_aliasing : "Edited in place."
 @return "Whether the selection changed."
*>
fn bool anti_aliasing_combo(ZString label, AntiAliasing* anti_aliasing) {
    int selected = (int)anti_aliasing.ordinal;
    bool changed = imgui::combo_char(
        label:        label,
        current_item: &selected,
        items:        &ANTI_ALIASING_LABELS[0],
        items_count:  AntiAliasing::len,
    );
    if (!changed) return false;
    *anti_aliasing = (AntiAliasing)selected;
    return true;
}

fn bool edit_level_count(
    ZString label,
    uint* value,
    uint minimum,
    uint maximum,
) @local {
    int count = (int)*value;
    bool changed = imgui::slider_int_ex(
        label:  label,
        v:      &count,
        v_min:  (int)minimum,
        v_max:  (int)maximum,
        format: "%d",
        flags:  imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    );
    *value = (uint)count;
    return changed;
}

fn bool edit_grade_factor(
    ZString label,
    float* value,
    float minimum,
    float maximum,
) @local {
    return imgui::slider_float_ex(
        label:  label,
        v:      value,
        v_min:  minimum,
        v_max:  maximum,
        format: "%.3f",
        flags:  imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    );
}

fn bool edit_grade_triple(
    ZString label,
    Vec3* value,
    float minimum,
    float maximum,
) @local {
    return imgui::drag_float3_ex(
        label:   label,
        v:       (float*)value,
        v_speed: TRIPLE_DRAG_SPEED,
        v_min:   minimum,
        v_max:   maximum,
        format:  "%.3f",
        flags:   imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    );
}
