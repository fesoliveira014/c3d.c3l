#ifndef C3D_INSTANCE_WORLD_GLSL
#define C3D_INSTANCE_WORLD_GLSL

// The world-space form of a stored instance record; every reader of a batch record goes through it.
InstanceGpu instance_to_world(DrawRoot draw, InstanceGpu record) {
    return record;
}

#endif
