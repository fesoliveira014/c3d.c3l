module c3d::maths;

<*
 Radical inverse of the index in the base; a low-discrepancy sequence in [0, 1).
 @require base >= 2
 @pure
*>
fn float halton(uint index, uint base) {
    float fraction = 1;
    float result = 0;
    while (index > 0) {
        fraction /= (float)base;
        result += fraction * (float)(index % base);
        index /= base;
    }
    return result;
}
