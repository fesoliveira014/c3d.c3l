module c3d::nav;

fn int previous_index(int index, int count) @private => index - 1 >= 0 ? index - 1 : count - 1;

fn int next_index(int index, int count) @private => index + 1 < count ? index + 1 : 0;

// Vertices are read as x = vertex[0], z = vertex[2].
fn int area2(int* a, int* b, int* c) @private => (b[0] - a[0]) * (c[2] - a[2]) - (c[0] - a[0]) * (b[2] - a[2]);

fn bool left(int* a, int* b, int* c) @private => area2(a, b, c) < 0;

fn bool left_on(int* a, int* b, int* c) @private => area2(a, b, c) <= 0;

fn bool collinear(int* a, int* b, int* c) @private => area2(a, b, c) == 0;

fn bool intersect_prop(
    int* a,
    int* b,
    int* c,
    int* d,
) @private {
    if (collinear(a, b, c) || collinear(a, b, d) || collinear(c, d, a) || collinear(c, d, b)) return false;
    return (left(a, b, c) ^ left(a, b, d)) && (left(c, d, a) ^ left(c, d, b));
}

fn bool between(int* a, int* b, int* c) @private {
    if (!collinear(a, b, c)) return false;
    if (a[0] != b[0]) return (a[0] <= c[0] && c[0] <= b[0]) || (a[0] >= c[0] && c[0] >= b[0]);
    return (a[2] <= c[2] && c[2] <= b[2]) || (a[2] >= c[2] && c[2] >= b[2]);
}

fn bool intersect(
    int* a,
    int* b,
    int* c,
    int* d,
) @private {
    if (intersect_prop(a: a, b: b, c: c, d: d)) return true;
    return between(a, b, c) || between(a, b, d) || between(c, d, a) || between(c, d, b);
}

fn bool equal_xz(int* a, int* b) @private => a[0] == b[0] && a[2] == b[2];
