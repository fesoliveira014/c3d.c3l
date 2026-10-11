module c3d::render::acceptance;

import c3d::light;
import std::math;
import std::math::vector;

alias TraceSegmentVector @private = double[<3>];

struct TraceSegmentTerms @private {
    TraceSegmentVector transmittance;
    TraceSegmentVector scattering;
}

struct TraceSegmentTableData @private {
    TraceSegmentVector[] transmittance;
    TraceSegmentVector[] multiple;
}

fn TraceSegmentVector trace_segment_bilinear(
    TraceSegmentVector[] pixels,
    uint width,
    uint height,
    double horizontal,
    double vertical,
) @private {
    double x = math::clamp(horizontal, 0.0, 1.0) * ((double)width - 1);
    double y = math::clamp(vertical, 0.0, 1.0) * ((double)height - 1);
    uint left = (uint)math::floor(x);
    uint top = (uint)math::floor(y);
    uint right = math::min(left + 1, width - 1);
    uint bottom = math::min(top + 1, height - 1);
    double horizontal_share = x - left;
    double vertical_share = y - top;
    TraceSegmentVector upper = pixels[top * width + left] * (1 - horizontal_share)
      + pixels[top * width + right] * horizontal_share;
    TraceSegmentVector lower = pixels[bottom * width + left] * (1 - horizontal_share)
      + pixels[bottom * width + right] * horizontal_share;
    return upper * (1 - vertical_share) + lower * vertical_share;
}

fn TraceSegmentVector trace_segment_sunlight(
    Atmosphere atmosphere,
    TraceSegmentTableData* tables,
    double altitude,
    double cosine,
) @private {
    double radius = (double)atmosphere.planet_radius + altitude;
    double ground = atmosphere.planet_radius;
    double top = ground + atmosphere.atmosphere_height;
    double lift = altitude * (2 * ground + altitude);
    if (cosine < 0 && radius * radius * cosine * cosine >= lift) return {};

    double tangent_distance = math::sqrt(top * top - ground * ground);
    double tangent_height = math::sqrt(math::max(lift, 0.0));
    double along_up = radius * cosine;
    double distance = math::sqrt(along_up * along_up + top * top - radius * radius) - along_up;
    double minimum = top - radius;
    double maximum = tangent_height + tangent_distance;
    double horizontal = (distance - minimum) / math::max(maximum - minimum, 1e-3);
    return trace_segment_bilinear(
        pixels: tables.transmittance,
        width: TRACE_SEGMENT_TRANSMITTANCE_WIDTH,
        height: TRACE_SEGMENT_TRANSMITTANCE_HEIGHT,
        horizontal: horizontal,
        vertical: tangent_height / tangent_distance,
    );
}

fn TraceSegmentTerms trace_segment_atmosphere_reference(
    TraceSegmentCase entry,
    Atmosphere atmosphere,
    TraceSegmentTableData* tables,
    uint steps,
) @private {
    TraceSegmentTerms result = { .transmittance = { 1, 1, 1 } };
    if (entry.quotient) {
        return {
            .transmittance = { 0.001, 0.001, 0.001 },
            .scattering = { -2500, -2000, -1500 },
        };
    }
    if (!entry.atmosphere || entry.distance <= 0) return result;

    TraceSegmentVector direction = { entry.direction.x, entry.direction.y, entry.direction.z };
    TraceSegmentVector sun = { entry.sun.x, entry.sun.y, entry.sun.z };
    double altitude = math::max((double)entry.origin.y, 0.0);
    double planet = atmosphere.planet_radius;
    double radius = planet + altitude;
    double top = planet + atmosphere.atmosphere_height;
    double along_up = radius * direction.y;
    double lift = altitude * (2 * planet + altitude);
    double ground_discriminant = along_up * along_up - lift;
    double boundary = math::sqrt(along_up * along_up + top * top - radius * radius) - along_up;
    if (direction.y < 0 && ground_discriminant >= 0) {
        boundary = -along_up - math::sqrt(ground_discriminant);
    }
    double length = math::max(0.0, math::min((double)entry.distance, boundary));
    double spacing = length / steps;
    double cosine = direction.dot(sun);
    double rayleigh_phase = 3 * (1 + cosine * cosine) / (16 * math::PI);
    double anisotropy = atmosphere.mie_anisotropy;
    double angular = 1 + anisotropy * anisotropy - 2 * anisotropy * cosine;
    double mie_phase = 3 * (1 - anisotropy * anisotropy) * (1 + cosine * cosine)
      / (8 * math::PI * (2 + anisotropy * anisotropy) * math::pow(angular, 1.5));
    TraceSegmentVector rayleigh_coefficients = {
        atmosphere.rayleigh_scattering.x, atmosphere.rayleigh_scattering.y, atmosphere.rayleigh_scattering.z,
    };
    TraceSegmentVector ozone_coefficients = {
        atmosphere.ozone_absorption.x, atmosphere.ozone_absorption.y, atmosphere.ozone_absorption.z,
    };
    for (uint index = 0; index < steps; index++) {
        double distance = ((double)index + 0.5) * spacing;
        TraceSegmentVector position = direction * distance + (TraceSegmentVector){ 0, radius, 0 };
        double reached_radius = position.length();
        double height = reached_radius - planet;
        double cos_sun = position.dot(sun) / reached_radius;
        double rayleigh_density = math::exp(-height / atmosphere.rayleigh_scale_height);
        double mie_density = math::exp(-height / atmosphere.mie_scale_height);
        double ozone_density = math::max(0.0,
            1 - math::abs(height - atmosphere.ozone_center_altitude) / atmosphere.ozone_half_width);
        TraceSegmentVector rayleigh = rayleigh_coefficients * rayleigh_density;
        double mie = atmosphere.mie_scattering * mie_density;
        double mie_extinction = ((double)atmosphere.mie_scattering + (double)atmosphere.mie_absorption) * mie_density;
        TraceSegmentVector extinction = rayleigh + ozone_coefficients * ozone_density
          + (TraceSegmentVector){ mie_extinction, mie_extinction, mie_extinction };
        TraceSegmentVector sunlight = trace_segment_sunlight(
            atmosphere: atmosphere,
            tables: tables,
            altitude: height,
            cosine: cos_sun,
        );
        TraceSegmentVector multiple = trace_segment_bilinear(
            pixels: tables.multiple,
            width: TRACE_SEGMENT_MULTIPLE_SIZE,
            height: TRACE_SEGMENT_MULTIPLE_SIZE,
            horizontal: (cos_sun + 1) / 2,
            vertical: height / atmosphere.atmosphere_height,
        );
        TraceSegmentVector source = sunlight
          * (rayleigh * rayleigh_phase + (TraceSegmentVector){ mie, mie, mie } * mie_phase)
          + multiple * (rayleigh + (TraceSegmentVector){ mie, mie, mie });
        for (uint channel = 0; channel < 3; channel++) {
            double attenuation = math::exp(-extinction[channel] * spacing);
            double integral = extinction[channel] > 0 ? (1 - attenuation) / extinction[channel] : spacing;
            result.scattering[channel] += result.transmittance[channel] * source[channel] * integral;
            result.transmittance[channel] *= attenuation;
        }
    }
    return result;
}

fn TraceSegmentTerms trace_segment_height_reference(TraceSegmentCase entry) @private {
    TraceSegmentTerms result = { .transmittance = { 1, 1, 1 } };
    if (!entry.height || entry.density == 0) return result;

    double height_from_base = (double)entry.origin.y - (double)entry.base_height;
    double density = (double)entry.density * math::exp(-(double)entry.falloff * height_from_base);
    double rate = (double)entry.falloff * entry.direction.y;
    double integrated;
    if (entry.distance < 0) {
        if (rate <= 0) {
            integrated = density > 0 ? double::inf : 0;
        } else {
            integrated = density / rate;
        }
    } else {
        integrated = rate == 0 ? density * entry.distance
          : density * (1 - math::exp(-rate * entry.distance)) / rate;
    }
    double attenuation = math::exp(-integrated);
    result.transmittance = { attenuation, attenuation, attenuation };
    result.scattering = (TraceSegmentVector){ 0.1, 0.2, 0.4 } * (1 - attenuation);
    return result;
}
