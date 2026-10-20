#ifndef PHYSICS_CLOTH_ROOT_GLSL
#define PHYSICS_CLOTH_ROOT_GLSL

#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

#ifndef CLOTH_LOCAL_SIZE
#define CLOTH_LOCAL_SIZE 64 // mirrored as FUSED_GROUP_SIZE in gpu/cloth.c3
#endif

layout(local_size_x = CLOTH_LOCAL_SIZE) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Mirrors ClothRoot in gpu/cloth.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ClothRoot {
    uint64_t positions;          // vec4 per particle: world position, inverse mass
    uint64_t predicted;          // vec4 per particle: position after this substep's prediction and projections
    uint64_t velocities;         // vec4 per particle
    uint64_t edges;              // uvec4 per edge: first, second, rest length bits, unused
    uint64_t initial;            // vec4 per particle: world position at the first step, inverse mass
    uint64_t rest;               // vec4 per particle: node-local rest position, inverse mass
    uint64_t marks;              // uint per particle: bit 0 set in the first color, bit 1 in the last
    uint64_t color_starts;       // uint per color plus one: first edge of each color
    uint64_t adjacency;          // uint offsets per particle plus one, then the incident triangle numbers
    uint64_t triangles;          // three vertex indices per triangle
    uint64_t geometry_positions; // packed three-float positions of the output geometry
    uint64_t geometry_normals;   // packed three-float normals of the output geometry
    mat4     anchor_frame;       // owner world matrix where the request starts
    mat4     target_frame;       // owner world matrix where it ends
    mat4     inverse_world;      // node-local frame of the output geometry
    vec4     gravity_step;       // xyz gravity in m/s^2, w substep length in seconds
    vec4     sphere;             // xyz center, w radius with the contact offset; zero disables
    uint     particle_count;
    float    stiffness;          // per-pass stretch stiffness
    float    damping;            // velocity share kept per substep
    float    ground;             // lowest height a free particle may reach
    uint     substeps;           // of the whole request
    uint     iterations;
    uint     color_count;
    uint     first;              // first edge of the dispatched color
    uint     count;              // edges of the dispatched color
    uint     phases;             // PASS_* bits of the dispatched pass
    uint     member_bit;         // bit of marks that tells a particle is on an edge of the dispatched color
    float    progress;           // share of the request's motion the dispatched substep ends at
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ClothVectors {
    vec4 values[];
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ClothEdges {
    uvec4 values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer ClothWords {
    uint values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer ClothFloats {
    float values[];
};

#endif
