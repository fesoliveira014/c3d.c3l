#ifndef PHYSICS_CLOTH_ROOT_GLSL
#define PHYSICS_CLOTH_ROOT_GLSL

#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

#ifndef CLOTH_LOCAL_SIZE
#define CLOTH_LOCAL_SIZE 64 // mirrored as FUSED_GROUP_SIZE in gpu/cloth_record.c3
#endif

layout(local_size_x = CLOTH_LOCAL_SIZE) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const uint64_t CLOTH_ROOT_BYTES = uint64_t(480u); // mirrored as ClothRoot::size in gpu/cloth_record.c3; the stride of the roots of a batched dispatch

// Mirrors ClothRoot in gpu/cloth_record.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ClothRoot {
    uint64_t positions;          // vec4 per particle: world position, inverse mass
    uint64_t predicted;          // vec4 per particle: position after this substep's prediction and projections
    uint64_t velocities;         // vec4 per particle
    uint64_t lambdas;            // vec4 per particle: soft attachment multiplier of this substep
    uint64_t reference;          // two vec4 per particle: world reference position at the request's start, then its end
    uint64_t constraints;        // two uvec4 per edge, then per bend: first, second, rest length bits, rest direction
    uint64_t initial;            // vec4 per particle: world position at the first step, inverse mass
    uint64_t rest;               // vec4 per particle: node-local rest position, inverse mass
    uint64_t marks;              // uint per particle: bit 0 set on a constraint of the first pass, bit 1 of the last
    uint64_t color_starts;       // uint per pass plus one: first constraint of each pass
    uint64_t adjacency;          // uint offsets per particle plus one, then the incident triangle numbers
    uint64_t triangles;          // three vertex indices per triangle
    uint64_t geometry_positions; // packed three-float positions of the output geometry
    uint64_t geometry_normals;   // packed three-float normals of the output geometry
    uint64_t soft;               // float per particle: effective compliance of a soft attachment, zero elsewhere
    uint64_t transport;          // float per particle: share of the owner's motion the particle follows
    uint64_t shapes;             // six vec4 per shape: owner pose at the request's start and end, the segment's owner-local end points
    uint64_t push;               // vec4 per particle: contact displacement of this substep, and 1 once it reached its limit
    uint64_t limits;             // float per particle: metres contact may push it within one substep
    uint     particle_count;
    uint     shape_count;
    mat4     anchor_frame;       // owner world matrix where the request starts
    mat4     target_frame;       // owner world matrix where it ends
    mat4     inverse_world;      // node-local frame of the output geometry
    vec4     gravity_step;       // xyz gravity in m/s^2, w substep length in seconds
    vec4     wind;               // xyz air velocity, w relative speed cap; used with CLOTH_FEATURE_WIND
    vec4     aero;               // x drag scale, y lift scale
    float    stretch_stiffness;  // per-pass stiffness of the edges
    float    bend_stiffness;     // per-pass stiffness of the bends
    float    damping;            // velocity share kept per substep
    float    ground;             // lowest height a free particle may reach
    uint     substeps;           // of the whole request
    uint     iterations;
    uint     color_count;        // passes of one iteration: the edge colors, then the bend colors
    uint     edge_colors;
    uint     features;           // CLOTH_FEATURE_* bits
    uint     first;              // first constraint of the dispatched pass
    uint     count;              // constraints of the dispatched pass
    uint     phases;             // PASS_* bits of the dispatched pass
    uint     member_bit;         // bit of marks that tells a particle is on a constraint of the dispatched pass
    float    progress;           // share of the request's motion the dispatched substep ends at
    float    previous_progress;  // share it starts at
    float    stiffness;          // stiffness of the dispatched pass
    uint     payload_offset;     // bytes from the dispatch's parameters to the reference pairs and shapes this root stages
    float    contact_tolerance;  // separation deficit contact accepts, in metres
};

const uint CLOTH_FEATURE_SOFT = 1u;      // mirrored as FEATURE_SOFT in gpu/cloth_pack.c3
const uint CLOTH_FEATURE_TRANSPORT = 2u; // mirrored as FEATURE_TRANSPORT in gpu/cloth_pack.c3
const uint CLOTH_FEATURE_REFERENCE = 4u; // mirrored as FEATURE_REFERENCE in gpu/cloth_pack.c3
const uint CLOTH_FEATURE_WIND = 8u;      // mirrored as FEATURE_WIND in gpu/cloth_pack.c3
const uint CLOTH_FEATURE_SHAPES = 16u;   // mirrored as FEATURE_SHAPES in gpu/cloth_pack.c3
const uint CLOTH_SHAPE_VECTORS = 6u;     // mirrored as SHAPE_VECTORS in gpu/cloth_record.c3
const uint CLOTH_MAX_SHAPES = 32u;       // mirrored as PLACED_SHAPES in gpu/cloth_record.c3
const uint64_t CLOTH_PLACED_OFFSET = uint64_t(3072u); // mirrored as PLACED_OFFSET in gpu/cloth_record.c3; bytes from a slot's staged shapes to its placed segments

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ClothVectors {
    vec4 values[];
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ClothConstraints {
    uvec4 values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer ClothWords {
    uint values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer ClothFloats {
    float values[];
};

#endif
