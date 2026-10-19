#ifndef TEST_DISPLACE_GLSL
#define TEST_DISPLACE_GLSL

// motion: amplitude, spatial frequency, angular rate, phase per unit of the instance's world x.
vec3 displace_position(vec3 local_position, float time, vec4 motion, float instance_x) {
    float height = motion.x * sin(local_position.x * motion.y + time * motion.z + instance_x * motion.w);
    return local_position + vec3(0.0, height, 0.0);
}

#endif
