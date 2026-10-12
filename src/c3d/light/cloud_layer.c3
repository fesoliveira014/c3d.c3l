module c3d::light;

import c3d;
import std::math;

<*
 A broken cumulus deck between 1.5 and 3 km, thick where the weather map is full.
*>
const CloudLayer CLOUD_LAYER_DEFAULT = {
    .bottom          = 1_500,
    .top             = 3_000,
    .density         = 0.04f,
    .coverage_extent = 20_000,
    .noise_scale     = 8_000,
    .erosion         = 0.3f,
    .albedo          = 1,
    .anisotropy      = 0.6f,
};

<*
 Raymarched cloud layer between two altitudes; the application owns its weather and placement.
*>
struct CloudLayer {
    float     bottom;          // metres above the y = 0 datum
    float     top;             // metres; above bottom
    float     density;         // extinction per metre at full coverage
    TextureId coverage;        // 2D weather map: R is coverage, G the share of the layer a cloud fills; unset: full
    float     coverage_extent; // metres one coverage repeat spans
    float     noise_scale;     // metres one noise repeat spans
    float     erosion;         // detail noise strength, 0 to 1
    Vec3      wind_offset;     // metres the clouds have drifted; the application advances it
    float     albedo;          // single-scattering albedo
    float     anisotropy;      // Henyey-Greenstein g of the forward lobe; the back lobe is -g / 2
}

<*
 Whether the layer can be drawn.
 @param [&in] layer : "Component to check."
 @pure
*>
fn bool cloud_layer_valid(CloudLayer* layer) {
    float[7] finite = {
        layer.bottom, layer.top, layer.density, layer.coverage_extent, layer.noise_scale, layer.erosion, layer.albedo,
    };
    foreach (value : finite) {
        if (!math::is_finite(value)) return false;
    }
    foreach (offset : layer.wind_offset) {
        if (!math::is_finite(offset)) return false;
    }
    if (layer.top <= layer.bottom || layer.density < 0) return false;
    if (layer.coverage_extent <= 0 || layer.noise_scale <= 0) return false;
    if (layer.erosion < 0 || layer.erosion > 1 || layer.albedo < 0 || layer.albedo > 1) return false;
    return math::is_finite(layer.anisotropy) && math::abs(layer.anisotropy) < 1;
}
