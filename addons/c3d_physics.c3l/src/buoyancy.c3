module c3d::physics;

import std::math;
import c3d;
import c3d::maths;
import b3;

<*
 World height of the fluid surface over a point; an empty optional is no fluid there.
 @param step_offset : "Seconds from the update's first fixed step to this one."
*>
alias FluidSurfaceFn = fn float? (void* context, float x, float z, float step_offset);

<*
 Cells a buoyant body's box is split into, one per octant.
*>
const uint BUOYANCY_CELLS = 8; // eight surface samples per body and step; enough for roll and pitch

<*
 Fresh water, kilograms per cubic metre.
*>
const float DEFAULT_FLUID_DENSITY = 1000;

// Octant of each cell in half-box units; bit 0 is x, bit 1 y, bit 2 z.
const Vec3[BUOYANCY_CELLS] CELL_OCTANTS @private = {
    { -1, -1, -1 }, { 1, -1, -1 }, { -1, 1, -1 }, { 1, 1, -1 },
    { -1, -1, 1 }, { 1, -1, 1 }, { -1, 1, 1 }, { 1, 1, 1 },
};

<*
 Lift and drag of the world's fluid on the body's colliders, each fixed step.
*>
struct Buoyancy {
    float fluid_density;      // kilograms per cubic metre
    float linear_drag;        // newton-seconds per metre on the whole body fully submerged
    float submerged_fraction; // written each step: mean cell submersion in [0, 1]
}

struct SolidMeasure @private {
    maths::Aabb bounds;
    float       volume;
}

<*
 Install the surface buoyancy samples; a second call replaces it, null removes it.
 @param [in] context : "Passed to every call; the caller keeps it alive."
*>
fn void PhysicsWorld.set_fluid_surface(&self, FluidSurfaceFn surface, void* context) {
    self.fluid_surface = surface;
    self.fluid_context = context;
}

fn void apply_buoyancy(
    PhysicsWorld* world,
    Buoyancy* buoyancy,
    RigidBody* body,
    float step_offset,
) @private {
    buoyancy.submerged_fraction = 0;
    if (!world.fluid_surface || body.kind != DYNAMIC || !(body.solid_volume > 0)) return;
    Vec3 half_cell = (body.solid_bounds.max - body.solid_bounds.min) / 4;
    Vec3 center = (body.solid_bounds.min + body.solid_bounds.max) / 2;
    Quat rotation = body.current.rotation;
    // A cell's world height span, so a tilted body still submerges each cell over its full height.
    float vertical_half = math::abs(rotation.rotate_vec3({ 1, 0, 0 }).y) * half_cell.x
        + math::abs(rotation.rotate_vec3({ 0, 1, 0 }).y) * half_cell.y
        + math::abs(rotation.rotate_vec3({ 0, 0, 1 }).y) * half_cell.z;
    Vec3 cell_lift = -world.desc.tuning.gravity * (buoyancy.fluid_density * body.solid_volume / BUOYANCY_CELLS);
    float cell_drag = buoyancy.linear_drag / BUOYANCY_CELLS;
    float submerged;
    foreach (octant : CELL_OCTANTS) {
        Vec3 point = body.current.position + rotation.rotate_vec3(center + octant * half_cell);
        float? surface = world.fluid_surface(
            context:     world.fluid_context,
            x:           point.x,
            z:           point.z,
            step_offset: step_offset,
        );
        if (catch surface) continue;
        float fraction = math::clamp((surface - point.y) / (2 * vertical_half) + 0.5f, 0.0f, 1.0f);
        if (fraction == 0) continue;
        submerged += fraction;
        Vec3 drag = body.body.world_point_velocity((b3::Pos)point) * -cell_drag;
        b3::body_apply_force(
            body:  body.body,
            force: (cell_lift + drag) * fraction,
            point: (b3::Pos)point,
            wake:  true,
        );
    }
    buoyancy.submerged_fraction = submerged / BUOYANCY_CELLS;
}

// Colliders without density add neither mass nor volume, so the body floats at its mass-weighted density.
fn SolidMeasure measure_solids(Collider[] colliders) @private {
    SolidMeasure solid;
    bool first = true;
    foreach (&collider : colliders) {
        float density = collider.shape.density();
        if (!(density > 0)) continue;
        b3::Aabb? box = shape_bounds(collider.shape);
        if (catch box) continue;
        solid.volume += collider.shape.compute_mass_data().mass / density;
        maths::Aabb bounds = { .min = box.lower_bound, .max = box.upper_bound };
        solid.bounds = first ? bounds : maths::aabb_merge(solid.bounds, bounds);
        first = false;
    }
    return solid;
}

// Shapes hold body-space geometry, so the identity transform gives body-space bounds.
fn b3::Aabb? shape_bounds(b3::ShapeId shape) @private {
    b3::Transform identity = { .q = maths::TRANSFORM_IDENTITY.rotation };
    switch (shape.type()) {
        case SPHERE:
            return shape.sphere()!.compute_aabb(identity);
        case CAPSULE:
            return shape.capsule()!.compute_aabb(identity);
        case HULL:
            return shape.hull()!.compute_aabb(identity);
        case COMPOUND:
        case HEIGHT_FIELD:
        case MESH:
            return c3d::UNSUPPORTED~;
    }
}
