module c3d::test::transparency_fixtures;

import std::math;

<* Scene-linear float64 fixture color. *>
alias Color = double[<3>];

<* Version of the deterministic transparency fixture inputs. *>
const uint TRANSPARENCY_FIXTURE_VERSION = 1;
<* Orthographic fixture viewport width and height. *>
const uint PLANAR_EXTENT = 128;
<* Orthographic near distance. *>
const float PLANAR_NEAR = 1;
<* Orthographic far distance. *>
const float PLANAR_FAR = 9;
<* Opaque scene-linear background for the planar corpus. *>
const Color PLANAR_BACKGROUND = { 0.125, 0.25, 0.5 };
<* Six sheet distances, from nearest to farthest. *>
const float[6] PLANAR_DISTANCES = { 3, 4, 5, 6, 7, 8 };
<* Exact intended R32 depths for the six sheets. *>
const float[6] PLANAR_DEPTHS = { 0.75, 0.625, 0.5, 0.375, 0.25, 0.125 };
<* Straight radiance of each planar sheet. *>
const Color[6] PLANAR_COLORS = {
    { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 },
    { 1, 1, 0 }, { 0, 1, 1 }, { 1, 0, 1 },
};
<* Coverage of each planar sheet. *>
const double[6] PLANAR_COVERAGES = { 0.25, 0.5, 0.75, 0.25, 0.5, 0.75 };
<* Quad triangle order. *>
const uint[6] QUAD_INDICES = { 0, 1, 2, 0, 2, 3 };
<* Reversed quad triangle order. *>
const uint[6] REVERSED_QUAD_INDICES = { 0, 2, 1, 0, 3, 2 };
<* Raw roughness samples before the BRDF floor. *>
const double[5] ROUGHNESS_VALUES = { 0, 0.25, 0.5, 0.75, 1 };
<* Authored indices of refraction. *>
const double[4] IOR_VALUES = { 1, 1.33, 1.5, 2 };
<* Exact skinning weight assigned to the translated bone. *>
const float[4] TRANSLATED_BONE_WEIGHTS = { 0, 0.5, 1, 0.5 };
<* Translation of the second fixture bone. *>
const float[3] TRANSLATED_BONE_POSITION = { 0, 0, 0.5 };
<* Mirrored model scale. *>
const float[3] MIRRORED_SCALE = { -1, 1, 1 };
<* Position delta for the morph fixture. *>
const float[3] MORPH_POSITION = { 0, 0, 0.25 };
<* Weight of the morph fixture. *>
const float MORPH_WEIGHT = 0.5;
<* Billboard width and height. *>
const float BILLBOARD_EXTENT = 1.5;
<* Homogeneous extinction used by the independent fog reduction. *>
const double FOG_EXTINCTION = 0.125;
<* Homogeneous fog in-scatter color. *>
const Color FOG_COLOR = { 0.1, 0.2, 0.4 };
<* Independent fog segment lengths. *>
const double[3] FOG_DISTANCES = { 1, 2, 4 };
<* Mapped transmission-factor samples. *>
const double[4] TRANSMISSION_VALUES = { 0, 0.25, 0.5, 1 };
<* Mapped metallic-factor samples. *>
const double[3] METALLIC_VALUES = { 0, 0.25, 1 };
<* Authored optical base color. *>
const Color OPTICAL_COLOR = { 0.8, 0.6, 0.4 };
<* Authored volume attenuation color. *>
const Color ATTENUATION_COLOR = { 0.5, 0.25, 0.125 };
<* Authored attenuation distance. *>
const double ATTENUATION_DISTANCE = 2;
<* Nearest-sampled transmission-map texels. *>
const double[4] TRANSMISSION_MAP = { 0.25, 0.5, 0.75, 1 };
<* Nearest-sampled thickness-map texels. *>
const double[4] THICKNESS_MAP = { 0, 0.25, 0.5, 1 };
<* Nearest-sampled coverage-map texels. *>
const double[4] COVERAGE_MAP = { 0, 0.49, 0.5, 1 };
<* Mask coverage threshold. *>
const double MASK_CUTOFF = 0.5;
<* Temporal sequence frame count. *>
const uint TEMPORAL_FRAMES = 120;
<* Dense overflow tile's first pixel coordinate. *>
const uint DENSE_TILE_BEGIN = 56;
<* Dense overflow tile's exclusive final pixel coordinate. *>
const uint DENSE_TILE_END = 72;

<* Independent scene-reader expression selected by a fixture fragment. *>
enum ReaderMode {
    NONE,
    COLOR,
    DEPTH,
    COLOR_DEPTH,
}

<* Deterministic linear backdrop patterns. *>
enum BackdropPattern {
    BLACK,
    BLUE,
    HDR,
    IMPULSE,
    CHECKER,
    STEP,
}

<* Quad attributes before renderer conversion. *>
struct QuadVertex {
    float[3] position;
    float[3] color;
}

<* One accepted fragment and its frozen canonical identity. *>
struct DepthFragment {
    float depth;
    uint node_index;
    uint node_generation;
    uint part_index;
    uint range_index;
    uint instance_index;
    uint primitive_index;
    Color radiance;
    double coverage;
    bool additive;
    ReaderMode reader;
    double opaque_depth;
}

<* Consecutive exact-depth fragments in near-first canonical storage. *>
struct DepthGroup {
    float depth;
    uint begin;
    uint count;
}

<* Caller-owned row-major scene-linear image. *>
struct ColorImage {
    uint width;
    uint height;
    Color[] pixels;
}

<* Temporal offsets and configuration events, without a jitter model. *>
struct TemporalFrame {
    double glass_offset;
    double background_offset;
    float render_scale;
    bool toggle_mode;
}

<* Generate the six fixed planar fragments.
   @require output.len == PLANAR_DISTANCES.len *>
fn void make_planar_fragments(DepthFragment[] output, bool additive = false) {
    foreach (uint index, &fragment : output) {
        *fragment = {
            .depth = PLANAR_DEPTHS[index],
            .node_index = index,
            .node_generation = 1,
            .radiance = PLANAR_COLORS[index],
            .coverage = PLANAR_COVERAGES[index],
            .additive = additive,
        };
    }
}

<* Generate seventeen uniform-coverage sheets without randomness.
   @require output.len == 17 *>
fn void make_dense_fragments(DepthFragment[] output, bool additive = false) {
    foreach (uint index, &fragment : output) {
        double distance = 2 + (double)index / 4;
        *fragment = {
            .depth = (float)((9 - distance) / 8),
            .node_index = index,
            .node_generation = 1,
            .radiance = PLANAR_COLORS[index % PLANAR_COLORS.len],
            .coverage = 0.5,
            .additive = additive,
        };
    }
}

<* Generate caller-owned quad vertices and global triangle indices.
   @require vertices.len == distances.len * 4
   @require indices.len == distances.len * 6 *>
fn void make_planar_quads(
    QuadVertex[] vertices,
    uint[] indices,
    float[] distances,
    bool reversed = false,
) {
    float[2][4] corners = { { -0.75, -0.75 }, { 0.75, -0.75 }, { 0.75, 0.75 }, { -0.75, 0.75 } };
    foreach (uint quad, distance : distances) {
        foreach (uint corner, position : corners) {
            vertices[quad * 4 + corner] = {
                .position = { position[0], position[1], -distance },
                .color = { 1, 1, 1 },
            };
        }
        for (uint index = 0; index < QUAD_INDICES.len; index++) {
            indices[quad * 6 + index] = quad * 4
              + (reversed ? REVERSED_QUAD_INDICES[index] : QUAD_INDICES[index]);
        }
    }
}

<* Sort near-first, then by the exact canonical identity. *>
fn void order_depth_fragments(DepthFragment[] fragments) {
    for (uint index = 1; index < fragments.len; index++) {
        DepthFragment inserted = fragments[index];
        uint destination = index;
        while (destination > 0 && fragment_precedes(inserted, fragments[destination - 1])) {
            fragments[destination] = fragments[destination - 1];
            destination--;
        }
        fragments[destination] = inserted;
    }
}

<* Partition already ordered fragments by exact stored depth.
   @require groups.len >= ordered.len *>
fn uint classify_depth_groups(DepthFragment[] ordered, DepthGroup[] groups) {
    uint count;
    foreach (uint index, fragment : ordered) {
        if (count == 0 || groups[count - 1].depth != fragment.depth) {
            groups[count++] = { .depth = fragment.depth, .begin = index, .count = 1 };
        } else {
            groups[count - 1].count++;
        }
    }
    return count;
}

<* Independent premultiplied source-over recurrence. *>
fn Color compose_over(Color behind, Color radiance, double coverage) {
    return coverage * radiance + (1 - coverage) * behind;
}

<* Independent additive radiance recurrence. *>
fn Color compose_additive(Color behind, Color radiance, double coverage) {
    return behind + coverage * radiance;
}

<* Evaluate the approved toy Custom reader before coverage. *>
fn Color sample_fragment_radiance(DepthFragment fragment, Color behind_snapshot) {
    switch (fragment.reader) {
        case NONE: return fragment.radiance;
        case COLOR: return 0.5 * fragment.radiance + 0.5 * behind_snapshot;
        case DEPTH: return fragment.radiance * fragment.opaque_depth;
        case COLOR_DEPTH:
            return 0.5 * fragment.radiance + 0.5 * behind_snapshot
              + fragment.radiance * fragment.opaque_depth;
    }
}

<* Compose explicit sorted input against one shared reader snapshot. *>
fn Color compose_sorted(DepthFragment[] sorted, Color background, Color reader_snapshot) {
    Color result = background;
    foreach (fragment : sorted) {
        Color radiance = sample_fragment_radiance(fragment, reader_snapshot);
        result = fragment.additive ? compose_additive(result, radiance, fragment.coverage)
          : compose_over(result, radiance, fragment.coverage);
    }
    return result;
}

<* Compose retained groups over the explicitly ordered sorted remainder.
   @require capacity >= 1 && capacity <= 16 *>
fn Color compose_hybrid(
    DepthFragment[] ordered,
    DepthGroup[] groups,
    uint capacity,
    DepthFragment[] sorted,
    Color background,
) {
    uint retained = math::min(capacity, (uint)groups.len);
    Color result = background;
    if (retained) {
        float cutoff = groups[retained - 1].depth;
        foreach (fragment : sorted) {
            if (fragment.depth >= cutoff) continue;
            Color radiance = sample_fragment_radiance(fragment, background);
            result = fragment.additive ? compose_additive(result, radiance, fragment.coverage)
              : compose_over(result, radiance, fragment.coverage);
        }
    }
    for (uint index = retained; index > 0; index--) {
        DepthGroup group = groups[index - 1];
        Color snapshot = result;
        foreach (fragment : ordered[group.begin:group.count]) {
            Color radiance = sample_fragment_radiance(fragment, snapshot);
            result = fragment.additive ? compose_additive(result, radiance, fragment.coverage)
              : compose_over(result, radiance, fragment.coverage);
        }
    }
    return result;
}

<* Number of floor-halved image levels, including the base.
   @require width > 0 && height > 0 *>
fn uint mip_level_count(uint width, uint height) {
    uint levels = 1;
    while (width > 1 || height > 1) {
        width = math::max(1u, width / 2);
        height = math::max(1u, height / 2);
        levels++;
    }
    return levels;
}

<* Independent roughness footprint using the approved raw inputs.
   @require width > 0 && height > 0
   @require roughness >= 0 && roughness <= 1 && ior >= 1 *>
fn double rough_transmission_lod(
    uint width,
    uint height,
    double roughness,
    double ior,
) {
    double footprint = math::log2((double)math::max(width, height));
    double last_mip = (double)(mip_level_count(width, height) - 1);
    return math::min(last_mip, footprint * roughness * math::clamp(2 * ior - 2, 0.0, 1.0));
}

<* Fill a borrowed image with a fixed linear backdrop.
   @require image.width > 0 && image.height > 0
   @require image.pixels.len == (usz)image.width * image.height *>
fn void fill_backdrop(ColorImage image, BackdropPattern pattern) {
    for (uint row = 0; row < image.height; row++) {
        for (uint column = 0; column < image.width; column++) {
            Color value;
            switch (pattern) {
                case BLACK: value = {};
                case BLUE: value = { 0.25, 0.5, 1 };
                case HDR: value = { 4, 2, 1 };
                case IMPULSE:
                    double intensity = row == image.height / 2 && column == image.width / 2 ? 4 : 0;
                    value = { intensity, intensity, intensity };
                case CHECKER:
                    double intensity = (double)((row + column) % 2);
                    value = { intensity, intensity, intensity };
                case STEP:
                    double intensity = column < image.width / 2 ? 0 : 1;
                    value = { intensity, intensity, intensity };
            }
            image.pixels[(usz)row * image.width + column] = value;
        }
    }
}

<* Integrate source texel overlap over each full output footprint.
   @require source.width > 0 && source.height > 0
   @require output.width == math::max(1u, source.width / 2)
   @require output.height == math::max(1u, source.height / 2)
   @require source.pixels.len == (usz)source.width * source.height
   @require output.pixels.len == (usz)output.width * output.height *>
fn void reduce_area_box(ColorImage source, ColorImage output) {
    for (uint row = 0; row < output.height; row++) {
        double top = (double)row * source.height / output.height;
        double bottom = (double)(row + 1) * source.height / output.height;
        uint begin_row = (uint)math::floor(top);
        uint end_row = math::min(source.height, (uint)math::ceil(bottom));
        for (uint column = 0; column < output.width; column++) {
            double left = (double)column * source.width / output.width;
            double right = (double)(column + 1) * source.width / output.width;
            uint begin_column = (uint)math::floor(left);
            uint end_column = math::min(source.width, (uint)math::ceil(right));
            Color sum;
            for (uint source_row = begin_row; source_row < end_row; source_row++) {
                double vertical = math::min(bottom, (double)(source_row + 1)) - math::max(top, (double)source_row);
                for (uint source_column = begin_column; source_column < end_column; source_column++) {
                    double horizontal = math::min(right, (double)(source_column + 1))
                      - math::max(left, (double)source_column);
                    sum += source.pixels[(usz)source_row * source.width + source_column] * horizontal * vertical;
                }
            }
            output.pixels[(usz)row * output.width + column] = sum / ((right - left) * (bottom - top));
        }
    }
}

<* Independent homogeneous fog transfer for a physical segment.
   @require extinction >= 0 && distance >= 0 *>
fn Color fog_segment(
    Color radiance,
    Color color,
    double extinction,
    double distance,
) {
    double transmission = math::exp(-extinction * distance);
    return transmission * radiance + (1 - transmission) * color;
}

<* Attenuate an additive contribution without fog in-scatter.
   @require extinction >= 0 && distance >= 0 *>
fn Color fog_attenuation(
    Color radiance,
    double coverage,
    double extinction,
    double distance,
) {
    return math::exp(-extinction * distance) * coverage * radiance;
}

<* Frozen movement and toggle events for one temporal frame.
   @require frame < TEMPORAL_FRAMES *>
fn TemporalFrame temporal_frame(uint frame) {
    return {
        .glass_offset = (double)frame / 64,
        .background_offset = -(double)frame / 128,
        .render_scale = frame >= 45 && frame < 75 ? 0.75 : 1,
        .toggle_mode = frame == 30 || frame == 60 || frame == 90,
    };
}

<* Opposite crossing-sheet depths at a normalized pixel coordinate.
   @require coordinate >= 0 && coordinate <= 1 *>
fn double[2] crossing_depths(double coordinate) {
    double displacement = (coordinate - 0.5) / 8;
    return { 0.5 + displacement, 0.5 - displacement };
}

fn bool fragment_precedes(DepthFragment first, DepthFragment second) @private {
    if (first.depth != second.depth) return first.depth > second.depth;
    if (first.node_index != second.node_index) return first.node_index < second.node_index;
    if (first.node_generation != second.node_generation) return first.node_generation < second.node_generation;
    if (first.part_index != second.part_index) return first.part_index < second.part_index;
    if (first.range_index != second.range_index) return first.range_index < second.range_index;
    if (first.instance_index != second.instance_index) return first.instance_index < second.instance_index;
    return first.primitive_index < second.primitive_index;
}
