module c3d::particle;

import std::math;

const uint POTENTIAL_COUNT @private = 3;
const uint CORNER_COUNT @private = 8;
const uint GRADIENT_CHOICES @private = 12;
const uint GRADIENT_FIELD_BITS @private = 10; // each potential reads its own ten bits of the corner hash
const uint GRADIENT_FIELD_MASK @private = (1 << GRADIENT_FIELD_BITS) - 1;
const float CURL_SCALE @private = 0.6f; // brings the first octave's root-mean-square speed to about one
const float OCTAVE_GAIN @private = 0.5f;
const float FADE_QUINTIC_TERM @private = 6;
const float FADE_QUARTIC_TERM @private = 15;
const float FADE_CUBIC_TERM @private = 10;
const float FADE_SLOPE_TERM @private = 30;

const Vec3[GRADIENT_CHOICES] LATTICE_GRADIENTS @private = {
    { 1, 1, 0 }, { -1, 1, 0 }, { 1, -1, 0 }, { -1, -1, 0 },
    { 1, 0, 1 }, { -1, 0, 1 }, { 1, 0, -1 }, { -1, 0, -1 },
    { 0, 1, 1 }, { 0, -1, 1 }, { 0, 1, -1 }, { 0, -1, -1 },
};

struct TurbulenceField @private {
    float strength;
    uint octaves;
    uint period;
    double frequency;
    double length;
    double[<3>] shift;
    double[<3>] drift;
}

fn TurbulenceField turbulence_field(
    ParticleTurbulence* turbulence,
    double[<3>] world_shift,
    double time,
) @private {
    return {
        .strength = turbulence.strength,
        .octaves = turbulence.octaves,
        .period = turbulence.period,
        .frequency = turbulence.frequency,
        .length = (double)turbulence.period / turbulence.frequency,
        .shift = world_shift,
        .drift = {
            (double)turbulence.scroll.x * time,
            (double)turbulence.scroll.y * time,
            (double)turbulence.scroll.z * time,
        },
    };
}

fn double wrap_to_tile(double value, double length) @private {
    double remainder = value - (double)(long)(value / length) * length;
    return remainder < 0 ? remainder + length : remainder;
}

// The tile reduction runs in double so a far or rebased point keeps its precision when the float evaluation starts.
fn Vec3 turbulence_air_velocity(TurbulenceField* self, Vec3 position) @private {
    double[<3>] point = (double[<3>]){ position.x, position.y, position.z } + self.shift - self.drift;
    double[<3>] cells;
    for (usz axis = 0; axis < 3; axis++) cells[axis] = wrap_to_tile(point[axis], self.length) * self.frequency;

    Vec3 air;
    float amplitude = self.strength * CURL_SCALE;
    for (uint octave = 0; octave < self.octaves; octave++) {
        air += turbulence_curl(cells * (double)(1u << octave), self.period << octave) * amplitude;
        amplitude *= OCTAVE_GAIN;
    }
    return air;
}

// Three gradient potentials read disjoint bits of one corner hash; the curl of their gradients is divergence-free.
fn Vec3 turbulence_curl(double[<3>] cells, uint period) @private {
    uint[2][3] lattice;
    Vec3 fraction;
    for (usz axis = 0; axis < 3; axis++) {
        long lower = (long)cells[axis]; // cells are never below zero by more than rounding, so this floors
        fraction[axis] = (float)(cells[axis] - (double)lower);
        uint near = (uint)lower % period;
        lattice[axis] = { near, near + 1 == period ? 0 : near + 1 };
    }

    Vec3[POTENTIAL_COUNT * CORNER_COUNT] gradients;
    for (uint z = 0; z < 2; z++) {
        uint plane = pcg_hash(lattice[2][z]);
        for (uint y = 0; y < 2; y++) {
            uint row = pcg_hash(plane + lattice[1][y]);
            for (uint x = 0; x < 2; x++) {
                uint hash = pcg_hash(row + lattice[0][x]);
                uint corner = x + 2 * y + 4 * z;
                for (uint potential = 0; potential < POTENTIAL_COUNT; potential++) {
                    uint field = (hash >> (potential * GRADIENT_FIELD_BITS)) & GRADIENT_FIELD_MASK;
                    uint choice = (field * GRADIENT_CHOICES) >> GRADIENT_FIELD_BITS;
                    gradients[potential * CORNER_COUNT + corner] = LATTICE_GRADIENTS[choice];
                }
            }
        }
    }

    Vec3 along_x = potential_gradient(gradients[0:CORNER_COUNT], fraction);
    Vec3 along_y = potential_gradient(gradients[CORNER_COUNT:CORNER_COUNT], fraction);
    Vec3 along_z = potential_gradient(gradients[2 * CORNER_COUNT:CORNER_COUNT], fraction);
    return { along_z.y - along_y.z, along_x.z - along_z.x, along_y.x - along_x.y };
}

macro mix(from, to, weight) @private => from + (to - from) * weight;

macro trilinear(array, Vec3 weight) @private {
    var near = mix(mix(array[0], array[1], weight.x), mix(array[2], array[3], weight.x), weight.y);
    var far = mix(mix(array[4], array[5], weight.x), mix(array[6], array[7], weight.x), weight.y);
    return mix(near, far, weight.z);
}

fn Vec3 quintic_fade(Vec3 fraction) @private {
    Vec3 inner = fraction * (fraction * FADE_QUINTIC_TERM - FADE_QUARTIC_TERM) + FADE_CUBIC_TERM;
    return fraction * fraction * fraction * inner;
}

fn Vec3 quintic_fade_slope(Vec3 fraction) @private {
    Vec3 remainder = fraction - 1;
    return fraction * fraction * remainder * remainder * FADE_SLOPE_TERM;
}

fn Vec3 potential_gradient(Vec3[] gradients, Vec3 fraction) @private {
    Vec3 fade = quintic_fade(fraction);
    Vec3 fade_slope = quintic_fade_slope(fraction);

    float[CORNER_COUNT] value;
    for (uint index = 0; index < CORNER_COUNT; index++) {
        Vec3 offset = { (float)(index & 1), (float)((index >> 1) & 1), (float)((index >> 2) & 1) };
        value[index] = gradients[index].dot(fraction - offset);
    }

    float slope_x = mix(
        mix(value[1] - value[0], value[3] - value[2], fade.y),
        mix(value[5] - value[4], value[7] - value[6], fade.y),
        fade.z,
    );
    float slope_y = mix(
        mix(value[2] - value[0], value[3] - value[1], fade.x),
        mix(value[6] - value[4], value[7] - value[5], fade.x),
        fade.z,
    );
    float slope_z = mix(
        mix(value[4] - value[0], value[5] - value[1], fade.x),
        mix(value[6] - value[2], value[7] - value[3], fade.x),
        fade.y,
    );
    return trilinear(gradients, fade) + fade_slope * (Vec3){ slope_x, slope_y, slope_z };
}
