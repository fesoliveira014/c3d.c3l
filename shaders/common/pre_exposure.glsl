#ifndef C3D_PRE_EXPOSURE_GLSL
#define C3D_PRE_EXPOSURE_GLSL

// Radiance a stage emits on its own, in the units the frame's lights, ambient and environment already carry.
vec3 pre_exposed(FrameRoot frame, vec3 radiance) {
    return radiance * frame.pre_exposure;
}

#endif
