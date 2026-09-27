module c3d::physics;

import std::math;
import c3d::ecs;
import b3;

<*
 Whether a mover query may touch the node's shapes.
*>
alias MoverFilterFn = fn bool (Entity entity, void* context);

<*
 One fixed step of application movers, between kinematic targets and the solver.
*>
alias MoverStepFn = fn void (void* context, PhysicsWorld* world, float fixed_dt);

<*
 Interpolated write-back of application movers, after the dynamic write-back.
*>
alias MoverWriteFn = fn void (void* context, PhysicsWorld* world, float alpha);

<*
 Planes one solve or clip reads; box3d's cap per touched shape.
*>
const usz MAX_MOVER_PLANES = 64; // under 2 KiB of stack per solve or clip; a mesh or height field reports up to 64

<*
 Upright capsule moved outside the simulation; queries are relative to its center.
*>
struct MoverCapsule {
    Vec3  center;       // world space
    float half_height;  // segment half length along world Y
    float radius;
}

<*
 Plane between a mover and one touched shape; solve_planes writes push.
*>
struct MoverPlane {
    Vec3   normal;         // out of the shape toward the mover
    float  offset;         // separation of p is dot(normal, p) - offset, p relative to the capsule center
    float  push_limit;     // float::max is rigid
    float  push;
    bool   clip_velocity;
    Entity entity;         // node of the touched shape
    Vec3   point;          // world space, on the touched shape's core
}

<*
 Delta a plane solve settled on.
*>
struct MoverSolve {
    Vec3 delta;
    uint iterations;   // index of the converging pass; box3d's pass cap means none converged
}

<*
 Hooks update calls for application movers; null hooks are skipped.
*>
struct MoverPass {
    MoverStepFn  step;
    MoverWriteFn write;
    void*        context;
}

struct MoverFilterContext @private {
    MoverFilterFn accept;
    void*         context;
}

struct CollideContext @private {
    MoverPlane[]       out;
    usz                count;
    Vec3               center;
    MoverFilterContext filter;
}

<*
 Fraction of the translation the capsule may sweep before it touches a shape.
 @param translation : "World space."
 @param accept : "Null accepts every shape the filter passes."
 @return "In [0, 1]; 1 when nothing is in the way."
*>
fn float PhysicsWorld.cast_mover(
    &self,
    MoverCapsule capsule,
    Vec3 translation,
    CollisionFilter filter = FILTER_ALL,
    MoverFilterFn accept = null,
    void* context = null,
) {
    b3::Capsule shape = box3d_capsule(capsule);
    MoverFilterContext filter_context = { .accept = accept, .context = context };
    return b3::world_cast_mover(
        world:       self.world,
        origin:      (b3::Pos)capsule.center,
        mover:       &shape,
        translation: translation,
        filter:      query_filter(filter),
        fcn:         accept ? &accept_shape : null,
        context:     &filter_context,
    );
}

<*
 Planes of every shape the capsule touches, written from the front of out_planes.
 Each plane starts rigid with clip_velocity set and push zero.
 @param [out] out_planes : "Planes past its length are dropped."
 @param accept : "Null accepts every shape the filter passes."
 @return "How many planes were written."
*>
fn usz PhysicsWorld.collide_mover(
    &self,
    MoverCapsule capsule,
    MoverPlane[] out_planes,
    CollisionFilter filter = FILTER_ALL,
    MoverFilterFn accept = null,
    void* context = null,
) {
    b3::Capsule shape = box3d_capsule(capsule);
    CollideContext collide = {
        .out    = out_planes,
        .center = capsule.center,
        .filter = { .accept = accept, .context = context },
    };
    b3::world_collide_mover(
        world:   self.world,
        origin:  (b3::Pos)capsule.center,
        mover:   &shape,
        filter:  query_filter(filter),
        fcn:     &collect_planes,
        context: &collide,
    );
    return collide.count;
}

<*
 Install the application's mover pass; {} removes it.
 The write hook may move nodes but must not add or remove components.
*>
fn void PhysicsWorld.set_mover_pass(&self, MoverPass pass) {
    self.mover_pass = pass;
}

<*
 Delta closest to target_delta that leaves every plane; writes each plane's push.
 @param [inout] planes : "Gathered at the capsule center the delta starts from."
 @require planes.len <= MAX_MOVER_PLANES
*>
fn MoverSolve solve_planes(Vec3 target_delta, MoverPlane[] planes) {
    b3::CollisionPlane[MAX_MOVER_PLANES] storage;
    b3::CollisionPlane[] box3d_planes = to_box3d(planes, storage[..]);
    b3::PlaneSolverResult result = b3::solve_planes(target_delta, box3d_planes);
    foreach (index, &plane : planes) plane.push = box3d_planes[index].push;
    return { .delta = result.delta, .iterations = (uint)result.iteration_count };
}

<*
 Vector without its components into the planes a solve pushed along.
 @param [in] planes : "After solve_planes; planes with push zero or clip_velocity false are skipped."
 @require planes.len <= MAX_MOVER_PLANES
*>
fn Vec3 clip_vector(Vec3 vector, MoverPlane[] planes) {
    b3::CollisionPlane[MAX_MOVER_PLANES] storage;
    return b3::clip_vector(vector, to_box3d(planes, storage[..]));
}

fn b3::Capsule box3d_capsule(MoverCapsule capsule) @local {
    return {
        .center1 = { 0, -capsule.half_height, 0 },
        .center2 = { 0, capsule.half_height, 0 },
        .radius  = capsule.radius,
    };
}

fn b3::CollisionPlane[] to_box3d(MoverPlane[] planes, b3::CollisionPlane[] storage) @local {
    foreach (index, &plane : planes) {
        storage[index] = {
            .plane         = { .normal = plane.normal, .offset = plane.offset },
            .push_limit    = plane.push_limit,
            .push          = plane.push,
            .clip_velocity = plane.clip_velocity,
        };
    }
    return storage[:planes.len];
}

fn bool accept_shape(b3::ShapeId shape, void* context) @local {
    MoverFilterContext* filter = context;
    return filter.accept(unpack_entity(shape.body().user_data()), filter.context);
}

// Planes of a rejected shape are skipped, not ended on: returning false would stop the whole tree.
fn bool collect_planes(
    b3::ShapeId shape,
    b3::PlaneResult* planes,
    int plane_count,
    void* context,
) @local {
    CollideContext* collide = context;
    if (collide.filter.accept && !accept_shape(shape, &collide.filter)) return true;
    Entity entity = unpack_entity(shape.body().user_data());
    foreach (result : planes[:plane_count]) {
        if (collide.count == collide.out.len) return true;
        collide.out[collide.count++] = {
            .normal        = result.plane.normal,
            .offset        = result.plane.offset,
            .push_limit    = float::max,
            .clip_velocity = true,
            .entity        = entity,
            .point         = collide.center + result.point,
        };
    }
    return true;
}
