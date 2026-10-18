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
 Fluid height and velocity at a point; an empty optional means no fluid.
 @param [in] context : "The pointer given at install."
 @param step_offset : "Seconds from the update's first fixed step to this one."
 @param [&out] velocity : "Metres per second; unspecified when the optional is empty."
*>
alias FluidSampleFn = fn float? (void* context, float x, float z, float step_offset, Vec3* velocity);

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
    float drag_coefficient;   // dimensionless C_d on the solid bounds' projected area; 0 keeps only linear drag
    float submerged_fraction; // written each step: mean cell submersion in [0, 1]
}

struct SolidMeasure @private {
    maths::Aabb bounds;
    float       volume;
}

// A body's drag constants at its current pose; the eight cells share the body's projected area equally.
struct CellDrag @private {
    float   linear;          // newton-seconds per metre of one cell fully submerged
    float   quadratic;       // half the fluid density times the drag coefficient
    Vec3    face_areas;      // square metres of one cell's share of the bounds' faces normal to each body axis
    Vec3[3] axes;            // body axes in world space
    float   force_per_speed; // newtons per metre per second: a cell's mass over the fixed step
}

<*
 Install a height-only fluid at rest; any install replaces the previous one, null removes it.
 @param [in] context : "Passed to every call; the caller keeps it alive."
*>
fn void PhysicsWorld.set_fluid_surface(&self, FluidSurfaceFn surface, void* context) {
    self.fluid_sampler = null;
    self.fluid_surface = surface;
    self.fluid_context = context;
}

<*
 Install a fluid sampler that reports height and fluid velocity for buoyancy.
 @param [in] context : "Borrowed; outlives the sampler's installation."
*>
fn void PhysicsWorld.set_fluid_sampler(&self, FluidSampleFn sample, void* context) {
    self.fluid_surface = null;
    self.fluid_sampler = sample;
    self.fluid_context = context;
}

// The limit keeps one explicit step from reversing the cell's velocity relative to the fluid.
fn Vec3 CellDrag.force(&self, Vec3 relative_velocity, float fraction) {
    float swept_volume_rate = self.face_areas.x * math::abs(relative_velocity.dot(self.axes[0]))
        + self.face_areas.y * math::abs(relative_velocity.dot(self.axes[1]))
        + self.face_areas.z * math::abs(relative_velocity.dot(self.axes[2]));
    Vec3 force = relative_velocity * -((self.linear + self.quadratic * swept_volume_rate) * fraction);

    float limit = self.force_per_speed * relative_velocity.length();
    float magnitude = force.length();
    return magnitude > limit ? force * (limit / magnitude) : force;
}

fn float? sample_fluid(
    PhysicsWorld* world,
    Vec3 point,
    float step_offset,
    Vec3* velocity,
) @private {
    if (world.fluid_sampler) {
        return world.fluid_sampler(
            context:     world.fluid_context,
            x:           point.x,
            z:           point.z,
            step_offset: step_offset,
            velocity:    velocity,
        );
    }

    return world.fluid_surface(
        context:     world.fluid_context,
        x:           point.x,
        z:           point.z,
        step_offset: step_offset,
    );
}

fn void apply_buoyancy(
    PhysicsWorld* world,
    Buoyancy* buoyancy,
    RigidBody* body,
    float step_offset,
) @private {
    buoyancy.submerged_fraction = 0;
    if (!(world.fluid_sampler || world.fluid_surface) || body.kind != DYNAMIC || !(body.solid_volume > 0)) return;

    Vec3 box_size = body.solid_bounds.max - body.solid_bounds.min;
    Vec3 half_cell = box_size / 4;
    Vec3 center = (body.solid_bounds.min + body.solid_bounds.max) / 2;
    Quat rotation = body.current.rotation;
    Vec3[3] axes = {
        rotation.rotate_vec3({ 1, 0, 0 }),
        rotation.rotate_vec3({ 0, 1, 0 }),
        rotation.rotate_vec3({ 0, 0, 1 }),
    };
    // A cell's world height span, so a tilted body still submerges each cell over its full height.
    float vertical_half = math::abs(axes[0].y) * half_cell.x
        + math::abs(axes[1].y) * half_cell.y
        + math::abs(axes[2].y) * half_cell.z;

    Vec3 cell_lift = -world.desc.tuning.gravity * (buoyancy.fluid_density * body.solid_volume / BUOYANCY_CELLS);
    Vec3 box_faces = { box_size.y * box_size.z, box_size.x * box_size.z, box_size.x * box_size.y };
    CellDrag drag = {
        .linear          = buoyancy.linear_drag / BUOYANCY_CELLS,
        .quadratic       = 0.5f * buoyancy.fluid_density * buoyancy.drag_coefficient,
        .face_areas      = box_faces / (float)BUOYANCY_CELLS,
        .axes            = axes,
        .force_per_speed = body.body.mass() / BUOYANCY_CELLS / world.desc.tuning.fixed_dt,
    };

    float submerged;
    foreach (octant : CELL_OCTANTS) {
        Vec3 point = body.current.position + rotation.rotate_vec3(center + octant * half_cell);
        Vec3 fluid_velocity;
        float? surface = sample_fluid(
            world:       world,
            point:       point,
            step_offset: step_offset,
            velocity:    &fluid_velocity,
        );
        if (catch surface) continue;

        float fraction = math::clamp((surface - point.y) / (2 * vertical_half) + 0.5f, 0.0f, 1.0f);
        if (fraction == 0) continue;

        submerged += fraction;
        Vec3 relative_velocity = body.body.world_point_velocity((b3::Pos)point) - fluid_velocity;
        b3::body_apply_force(
            body:  body.body,
            force: cell_lift * fraction + drag.force(relative_velocity, fraction),
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
