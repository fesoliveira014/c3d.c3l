bool peel_transparency_accept(float depth) {
    Draw root = Draw(pc.fragment_root);
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    if (root.mode == 0u) {
        return root.has_previous == 0u || depth < fetch_depth(root.previous, pixel);
    }
    if (root.mode == 1u) return depth == fetch_depth(root.selected, pixel);
    if (root.mode == 2u) return depth < fetch_depth(root.selected, pixel);
    return true;
}
