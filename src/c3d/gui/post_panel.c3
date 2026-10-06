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
const float AO_RADIUS_MIN @local = 0.05f;
const float AO_RADIUS_MAX @local = 5;
const float AO_INTENSITY_MAX @local = 2;
const float SSGI_DISTANCE_MIN @local = 0.1f;
const float SSGI_DISTANCE_MAX @local = 10;
const float SSGI_THICKNESS_MIN @local = 0.01f;
const float SSGI_THICKNESS_MAX @local = 2;
const float SSGI_HISTORY_WEIGHT_MAX @local = 0.99f; // the weight must stay below 1 or the history never changes
const float REFLECTION_ROUGHNESS_MIN @local = 0.05f;
const float REFLECTION_ROUGHNESS_MAX @local = 1;
const uint PATH_TRACE_MAX_SAMPLES_LIMIT @local = 65536; // a float mean gains nothing visible beyond it
// Slider limits that keep every combination valid: the metered window stays inside the histogram range.
const float COMPENSATION_LIMIT @local = 4;
const float EXPOSURE_BOUND_LIMIT @local = 10;
const float ADAPTATION_TIME_MAX @local = 10;
const float LOW_PERCENTILE_MAX @local = 0.45f;
const float HIGH_PERCENTILE_MIN @local = 0.55f;
const ZString[Tonemap::len] TONEMAP_LABELS @local = { "None", "ACES", "AgX", "Reinhard" };
const ZString[AntiAliasing::len] ANTI_ALIASING_LABELS @local = { "None", "FXAA", "TAA" };
const ZString[TaaDebug::len] TAA_DEBUG_LABELS @local = { "None", "Velocity", "Rejection", "History weight" };
const ZString[AoKind::len] AO_KIND_LABELS @local = { "None", "SSAO", "Ray traced" };

<*
 Edit the view's post settings; the caller applies them with configure_view.
 @param [&inout] desc : "Edited in place."
 @param lut : "Offered by a checkbox when live; zero hides it."
 @param [in] stats : "The view's stats; shows its delayed exposure, null hides it."
 @return "Whether any setting changed."
*>
fn bool post_panel(ViewDesc* desc, TextureId lut, ViewStats* stats = null) {
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
    bool path_traced = desc.shading == ShadingPath.PATH_TRACED;
    changed |= anti_aliasing_combo("Anti-aliasing", &desc.post.anti_aliasing);
    // Accumulation already antialiases a path-traced view, and it rejects TAA.
    if (path_traced && desc.post.anti_aliasing == AntiAliasing.TAA) desc.post.anti_aliasing = AntiAliasing.NONE;
    changed |= imgui::checkbox("Depth prepass", &desc.depth_prepass);
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
    if (imgui::collapsing_header("Auto exposure", {})) {
        changed |= edit_auto_exposure(&desc.post, stats, post::auto_exposure_active(desc));
    }
    if (imgui::collapsing_header("Depth of field", {})) {
        DofParams* dof = &desc.post.dof_params;
        imgui::begin_disabled(path_traced);
        changed |= imgui::checkbox("Enable depth of field", &desc.post.depth_of_field);
        imgui::end_disabled();
        changed |= edit_grade_factor("Focus distance", &dof.focus_distance, FOCUS_DISTANCE_MIN, FOCUS_DISTANCE_MAX);
        changed |= edit_grade_factor("Focal length", &dof.focal_length, FOCAL_LENGTH_MIN, FOCAL_LENGTH_MAX);
        changed |= edit_grade_factor("Aperture", &dof.aperture, APERTURE_MIN, APERTURE_MAX);
        changed |= edit_grade_factor("Max CoC", &dof.max_coc, MAX_COC_MIN, MAX_COC_MAX);
    }
    if (imgui::collapsing_header("Motion blur", {})) {
        MotionBlurParams* blur = &desc.post.motion_blur_params;
        imgui::begin_disabled(path_traced);
        changed |= imgui::checkbox("Enable motion blur", &desc.post.motion_blur);
        imgui::end_disabled();
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
    imgui::begin_disabled(path_traced);
    if (imgui::collapsing_header("Ambient occlusion", {})) {
        changed |= edit_ambient_occlusion(&desc.ambient_occlusion);
    }
    if (imgui::collapsing_header("Screen-space GI", {})) {
        changed |= edit_screen_space_gi(&desc.screen_space_gi);
    }
    if (imgui::collapsing_header("Ray tracing", {})) {
        changed |= edit_ray_tracing(desc);
    }
    imgui::end_disabled();
    if (path_traced && imgui::collapsing_header("Path tracing", {})) {
        changed |= edit_path_trace(&desc.path_trace);
    }

    return changed;
}

fn bool edit_auto_exposure(PostStack* post, ViewStats* stats, bool active) @local {
    AutoExposureParams* params = &post.auto_exposure_params;
    bool changed = imgui::checkbox("Enable auto exposure", &post.auto_exposure);
    changed |= edit_grade_factor(
        label:   "Compensation (EV)",
        value:   &params.compensation_ev,
        minimum: -COMPENSATION_LIMIT,
        maximum: COMPENSATION_LIMIT,
    );
    changed |= edit_grade_factor(
        label:   "Min (EV)",
        value:   &params.min_ev,
        minimum: -EXPOSURE_BOUND_LIMIT,
        maximum: 0,
    );
    changed |= edit_grade_factor(
        label:   "Max (EV)",
        value:   &params.max_ev,
        minimum: 0,
        maximum: EXPOSURE_BOUND_LIMIT,
    );
    changed |= edit_grade_factor(
        label:   "Brightening (s)",
        value:   &params.brightening_time,
        minimum: 0,
        maximum: ADAPTATION_TIME_MAX,
    );
    changed |= edit_grade_factor(
        label:   "Darkening (s)",
        value:   &params.darkening_time,
        minimum: 0,
        maximum: ADAPTATION_TIME_MAX,
    );
    changed |= edit_grade_factor(
        label:   "Low percentile",
        value:   &params.low_percentile,
        minimum: 0,
        maximum: LOW_PERCENTILE_MAX,
    );
    changed |= edit_grade_factor(
        label:   "High percentile",
        value:   &params.high_percentile,
        minimum: HIGH_PERCENTILE_MIN,
        maximum: 1,
    );
    if (stats && stats.exposure > 0) {
        if (active) {
            imgui::text("Exposure %.2f EV, %u frames old", math::log2(stats.exposure), render::FRAMES_IN_FLIGHT);
        } else {
            imgui::text("Exposure %.2f EV", math::log2(stats.exposure));
        }
    }
    return changed;
}

fn bool edit_ambient_occlusion(AmbientOcclusionDesc* ambient_occlusion) @local {
    int selected = (int)ambient_occlusion.kind.ordinal;
    bool changed = imgui::combo_char(
        label:        "Kind",
        current_item: &selected,
        items:        &AO_KIND_LABELS[0],
        items_count:  AoKind::len,
    );
    if (changed) {
        AoKind kind = (AoKind)selected;
        if (kind != AoKind.NONE && ambient_occlusion.radius == 0) {
            *ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
        }
        ambient_occlusion.kind = kind;
    }
    changed |= edit_grade_factor("Radius", &ambient_occlusion.radius, AO_RADIUS_MIN, AO_RADIUS_MAX);
    changed |= edit_grade_factor("AO intensity", &ambient_occlusion.intensity, 0, AO_INTENSITY_MAX);
    changed |= imgui::checkbox("Full resolution", &ambient_occlusion.full_resolution);
    if (ambient_occlusion.kind == AoKind.RAY_TRACED) {
        changed |= edit_level_count(
            label:   "Rays",
            value:   &ambient_occlusion.ray_count,
            minimum: render::RT_AO_RAYS_MIN,
            maximum: render::RT_AO_RAYS_MAX,
        );
    }
    return changed;
}

fn bool edit_screen_space_gi(ScreenSpaceGiDesc* screen_space_gi) @local {
    bool enabled = screen_space_gi.enabled;
    bool changed = imgui::checkbox("Enabled", &enabled);
    if (changed) *screen_space_gi = enabled ? render::SCREEN_SPACE_GI_DEFAULT : (ScreenSpaceGiDesc){};
    if (!screen_space_gi.enabled) return changed;
    changed |= edit_level_count(
        label:   "GI rays",
        value:   &screen_space_gi.rays,
        minimum: render::SSGI_RAYS_MIN,
        maximum: render::SSGI_RAYS_MAX,
    );
    changed |= edit_level_count(
        label:   "GI steps",
        value:   &screen_space_gi.max_steps,
        minimum: render::SSGI_STEPS_MIN,
        maximum: render::SSGI_STEPS_MAX,
    );
    changed |= edit_grade_factor("GI distance", &screen_space_gi.max_distance, SSGI_DISTANCE_MIN, SSGI_DISTANCE_MAX);
    changed |= edit_grade_factor("GI thickness", &screen_space_gi.thickness, SSGI_THICKNESS_MIN, SSGI_THICKNESS_MAX);
    changed |= edit_grade_factor("GI intensity", &screen_space_gi.intensity, 0, 1);
    changed |= edit_grade_factor("GI history weight", &screen_space_gi.history_weight, 0, SSGI_HISTORY_WEIGHT_MAX);
    return changed;
}

fn bool edit_path_trace(PathTraceDesc* path_trace) @local {
    bool changed = edit_level_count(
        label:   "Bounces",
        value:   &path_trace.max_bounces,
        minimum: 1,
        maximum: render::PATH_TRACE_BOUNCES_MAX,
    );
    changed |= edit_level_count(
        label:   "Samples per frame",
        value:   &path_trace.samples_per_frame,
        minimum: 1,
        maximum: render::PATH_TRACE_SAMPLES_PER_FRAME_MAX,
    );
    if (imgui::input_scalar("Max samples (0 = unlimited)", imgui::DATA_TYPE_U32, &path_trace.max_samples)) {
        path_trace.max_samples = math::min(path_trace.max_samples, PATH_TRACE_MAX_SAMPLES_LIMIT);
        changed = true;
    }
    return changed;
}

fn bool edit_ray_tracing(ViewDesc* desc) @local {
    RayTracingDesc* ray_tracing = &desc.ray_tracing;
    bool changed = imgui::checkbox("Shadows", &ray_tracing.shadows);

    imgui::begin_disabled(desc.shading != ShadingPath.DEFERRED);
    if (imgui::checkbox("Reflections", &ray_tracing.reflections)) {
        if (ray_tracing.reflections && ray_tracing.max_reflection_roughness == 0) {
            ray_tracing.max_reflection_roughness = render::RT_REFLECTION_ROUGHNESS_DEFAULT;
        }
        changed = true;
    }
    imgui::end_disabled();
    if (ray_tracing.reflections) {
        changed |= edit_grade_factor(
            label:   "Max roughness",
            value:   &ray_tracing.max_reflection_roughness,
            minimum: REFLECTION_ROUGHNESS_MIN,
            maximum: REFLECTION_ROUGHNESS_MAX,
        );
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
