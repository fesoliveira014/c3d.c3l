#ifndef C3D_DISPATCH_GRID_GLSL
#define C3D_DISPATCH_GRID_GLSL

// The group's place along one logical row of groups, which a dispatch may wrap into rows of its grid.
uint linear_group_id() {
    return gl_WorkGroupID.y * gl_NumWorkGroups.x + gl_WorkGroupID.x;
}

// The invocation's index along one logical row of groups; the last grid row can pass the covered count.
uint linear_group_index(uint group_size) {
    return linear_group_id() * group_size + gl_LocalInvocationID.x;
}

#endif
