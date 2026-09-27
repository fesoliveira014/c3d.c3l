module c3d::nav;

import std::math;
import c3d;
import c3d::maths;
import c3d::scene;

<* Geometry rasterized into the navmesh; walkable or obstacle, placed by the node's world matrix. *>
struct NavSource {
    GeometryId geometry;    // the zero id names the node's Mesh geometry
    bool       walkable;    // false rasterizes every triangle as NULL_AREA
    char       area;        // area id given to walkable triangles
    bool       changed;
}

<* Area marking volume in node space; the node's world matrix places it. *>
struct NavVolume {
    VolumeKind             kind;
    char                   area;
    Aabb                   box;       // BOX
    Vec3[MAX_VOLUME_VERTS] verts;     // CONVEX; Y ignored
    uint                   vert_count;
    float                  min_y;     // CONVEX
    float                  max_y;
    Vec3                   base;      // CYLINDER
    float                  radius;
    float                  height;
    bool                   changed;
}

<* Runtime mirror of a NavSource: the world bounds its tiles were dirtied with. *>
struct NavSourceRuntime {
    Aabb bounds;
}

<* Runtime mirror of a NavVolume: its world bounds and world-space record. *>
struct NavVolumeRuntime {
    Aabb         bounds;
    VolumeRecord record;
}

<*
 Request a rebuild of the tiles under the old and new bounds on the next sync.
 Moving the node or editing the geometry does nothing until this is called.
*>
fn void NavSource.mark_changed(&self) {
    self.changed = true;
}

<*
 Request a rebuild of the tiles under the old and new bounds on the next sync.
 Moving the node does nothing until this is called.
*>
fn void NavVolume.mark_changed(&self) {
    self.changed = true;
}

<*
 Author a source on the node.
 @param [&in] node : "Carries a Mesh when geometry is the zero id."
 @return? c3d::INVALID_ARGUMENT, SOURCE_EXISTS
 @require self.world.is_registered(NavSource)
*>
fn void? Scene.add_nav_source(
    &self,
    Node* node,
    GeometryId geometry = {},
    bool walkable = true,
    char area = WALKABLE_AREA,
) {
    if (self.has(node, NavSource)) return SOURCE_EXISTS~;
    if (area > WALKABLE_AREA) return c3d::INVALID_ARGUMENT~;
    if (c3d::same_id(geometry, (GeometryId){}) && !self.has(node, scene::Mesh)) return c3d::INVALID_ARGUMENT~;
    self.add(node, (NavSource){ .geometry = geometry, .walkable = walkable, .area = area });
}

<*
 Author one walkable source per Mesh node under root that has none.
 @param [&in] root : "Walked including root."
 @return "How many sources were authored."
 @require self.world.is_registered(NavSource)
*>
fn uint Scene.add_nav_sources(&self, Node* root, char area = WALKABLE_AREA) {
    uint added;
    if (self.has(root, scene::Mesh) && !self.has(root, NavSource)) {
        self.add(root, (NavSource){ .walkable = true, .area = area });
        added++;
    }
    for (Node* child = root.first_child; child; child = child.next_sibling) {
        added += self.add_nav_sources(child, area);
    }
    return added;
}

<*
 Author a volume on the node.
 @return? c3d::INVALID_ARGUMENT, VOLUME_EXISTS
 @require self.world.is_registered(NavVolume)
*>
fn void? Scene.add_nav_volume(&self, Node* node, NavVolume volume) {
    if (self.has(node, NavVolume)) return VOLUME_EXISTS~;
    if (volume.area > WALKABLE_AREA) return c3d::INVALID_ARGUMENT~;
    switch (volume.kind) {
        case BOX:
            break;
        case CONVEX:
            if (volume.vert_count < 3 || volume.vert_count > MAX_VOLUME_VERTS) return c3d::INVALID_ARGUMENT~;
            if (volume.min_y > volume.max_y) return c3d::INVALID_ARGUMENT~;
        case CYLINDER:
            if (volume.radius <= 0 || volume.height <= 0) return c3d::INVALID_ARGUMENT~;
    }
    volume.changed = false;
    self.add(node, volume);
}

<*
 Register the nav components and their mirrors.
 @param [&inout] scene : "Gains NavSource, NavVolume, NavSourceRuntime and NavVolumeRuntime."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? register_nav(Scene* scene) {
    scene.register(NavSource)!;
    scene.register(NavVolume)!;
    scene.register(NavSourceRuntime)!;
    scene.register(NavVolumeRuntime)!;
}
