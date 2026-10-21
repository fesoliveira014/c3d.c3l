# Inverse kinematics

`c3d::anim::ik` bends existing joint nodes toward targets after the animator has written its pose. Three types cover
limbs, feet and looking, and retained foot contacts keep a planted foot on a moving support. `solve`, `align` and
`align_contact` read world matrices and write local rotations only. `place`, `release` and `reset_contact` move the
target node and `lower_pelvis` moves the pelvis. Nothing allocates, and no feature flag applies.

## Quick start

Solve a leg to a target node after animation and a world refresh.

```c3
import c3d::anim;
import c3d::anim::ik;

IkChain leg = ik::ik_chain(hip, knee, ankle, target, pole);

anim::update(&assets, &scene, dt);
scene.update_world();
leg.solve();
scene.update_world();
```

`ik_chain(root, middle, end, target, pole = null)` returns a unit-weight chain without limits. `solve` requires
`ik_chain_valid(&leg)`: live joints that are each the parent of the next, a root joint, target and pole that each have
a parent, `PARENT` space on the middle and end joints, and nonzero bone lengths.

## Concepts

- **`IkChain`** has three joints (root, middle, end) solved analytically so the end reaches `target`. `pole` picks the
  side the middle joint bends toward; without one, the incoming bend is kept. `weight` blends from the incoming
  rotations (0) to the solve (1). `solve` writes only the root and middle local rotations, so bone lengths never
  change. A target beyond reach straightens the limb toward it.
- **`FootIk`** is a leg `IkChain` whose target follows the ground under the ankle.
- **`LookAt`** turns the `forward` axis of its last joint toward a target, at most `max_angle` from the incoming pose,
  without adding roll. It spreads the turn over up to eight joints by `weights`. `look_at(joints, target, forward)`
  fills shares that grow toward the tip and sum to 1: joint `i` of `n` takes `(i + 1) / (n * (n + 1) / 2)`, so the tip
  turns most. A second pass corrects the tip's own swing about the lower joints. `solve` requires `look_at_valid`: every
  joint has a parent, the later joints use `PARENT` space and the shares sum to 1 within `1e-4`.
- **Components.** `create_scene` registers all three as components, so the Scene inspector and `DebugDraw.ik` find
  them. Nothing solves them for you: the application calls `solve`, `place`, `release` and `align` in its own order.
- **Ownership.** Joints, targets and poles are borrowed nodes and must outlive the component that names them.

### Transform spaces

The first joint of an `IkChain` or `LookAt` may use `TransformSpace.WORLD`. Every later joint must use `PARENT`,
because the solvers articulate descendants by rotating their ancestors; the validity predicates reject a `WORLD`
interior joint. Targets, poles and the pelvis may use either space; foot placement and pelvis lowering convert through
their selected basis. See [Authored and published transforms](scene.md#authored-and-published-transforms).

### Solve order

Solvers read world matrices and write locals. A chain whose joints or target descend from a joint another solve writes
needs an `update_world` between the two solves. On a humanoid the arms hang off the upper spine, so a spine look-at
solves before them; legs and arms are then independent.

```c3
FootIk*[2] feet = { &left_foot, &right_foot };

anim::update(&assets, &scene, dt);
scene.update_world();
// Physics here, when present; then scene.update_world().
foreach (foot : feet) {
    Ray ray = foot.ground_ray();
    if (try hit = query_ground(ray, foot.ray_length)) {
        foot.place(hit, floor_height);
    } else {
        foot.release();
    }
}
ik::lower_pelvis(hips, feet[..]);
scene.update_world();
look.solve();
scene.update_world();
foreach (foot : feet) foot.leg.solve();
arm.solve();
scene.update_world();
foreach (foot : feet) foot.align();
scene.update_world();
```

`query_ground` stands for the application's ground query and returns a `GroundHit?` (`point`, unit `normal`).

## Feet

The application owns the ground query. `foot_ik(hip, knee, ankle, target, pole = null)` builds a `FootIk` with these
defaults:

| Field | Default | Meaning |
| --- | --- | --- |
| `foot_height` | 0.08 m | Ankle height above the sole in the authored stance. |
| `lift_fade` | 0.1 m | Ankle lift over which foot alignment fades out. Positive. |
| `ray_height` | 0.5 m | Start of the ground ray above the ankle. |
| `ray_length` | 1.5 m | Length of the ground ray. |
| `plant` | `FOOT_PLANT_DEFAULT` | Contact timing and sole axes for retained contacts. |

`ground_ray` returns a downward ray from `ray_height` above the ankle. Cast it through physics or read a height field,
then call `place(hit, floor_height)` on a hit or `release()` on a miss. `floor_height` is the world height the clip's feet
were authored on, usually the character root's height. The target must not descend from the leg or the pelvis.

The target keeps the clip's ankle motion and moves it by the ground's offset from the floor under the ankle. On flat
ground at floor height the solve changes nothing, and a swinging foot keeps its arc. `align` tilts the ankle by the
rotation from world up to the ground normal, faded out over `lift_fade` as the ankle rises above `foot_height`.
`lower_pelvis` lowers the pelvis by the largest downhill offset of the grounded feet, each scaled by its leg's `weight`,
so the lower foot can reach its target, and returns the drop in metres. Stance feet are not locked: on a slope a planted foot follows the terrain height
under it as the body moves.

### Retained foot contacts

Retained contacts hold a stance anchor on a support that may move, yaw, tilt and scale. The application chooses the hit,
the support identity and the timing.

| Call | Effect |
| --- | --- |
| `begin_contact(hit, support, floor_height = 0)` | Capture a stance anchor and start acquiring it. |
| `update_contact(support, dt, floor_height = 0)` | Follow the support and advance the phase. |
| `end_contact(support, floor_height = 0)` | Blend into the fresh incoming swing pose. |
| `reset_contact()` | Clear the contact at once, for a caller-authorized reset such as a teleport. |
| `align_contact()` | Apply the requested ankle orientation after solving. |

`FootSupport` carries an opaque `identity` and a `Transform` that must be a proper rotation with finite positive uniform
scale. Static ground is a support whose frame does not move; like any support, its owner passes the current frame,
shifted after an origin rebase. `FootContactPhase` is `INACTIVE`, `ACQUIRING`, `PLANTED` or `RELEASING`.

- **Faults.** An invalid support, hit, plant setting or incoming pose returns `INVALID_ARGUMENT` and leaves the contact
  unchanged. So do a nonfinite or negative `dt` or `foot_height`, a nonfinite `floor_height` and, at `begin_contact`, a
  sole forward axis parallel to the hit normal. Changing the support identity requires an explicit new capture.
- **Plant settings.** `FootIk.plant` defaults to 0.12 s of acquisition, 0.20 s of release and ankle-local sole axes
  `+Y` up and `-Z` forward. Set the axes for the rig's authored ankle orientation. Settings and `foot_height` are
  captured at each begin. The height stays in scene metres while the support-local sole point follows changing scale.
- **Repeating `begin_contact`.** The same support, hit, settings and height while acquiring or planted keeps the
  current acquisition; any other replant captures the currently requested correction.
- **Time.** Zero `dt` freezes the transition clocks while external support movement still carries the contact.
- **One writer.** Start each update from the fresh animation pose and choose either retained contact or
  `place` and `release` for that update.

Order for a contact update: animation and a world refresh, `update_contact`, optional `lower_pelvis`, a world refresh,
dependent IK and the legs, a refresh, `align_contact`, a refresh. Reach clamps, limits and partial leg weight may leave
the ankle short of the requested target; the anchor is retained without stretching or automatic release.

A standalone `FootContact` offers the same lifecycle with an explicit incoming `Transform` and plant settings. During
origin rebasing, call `Scene.shift_foot_contacts` after the scene world refresh, or `FootContact.shift_origin` for
standalone states; each state has one shift owner ([Protocol](large_world.md#protocol)).

## Limits

`IkChain.limits[0]` and `limits[1]` bound the root and middle rotations relative to `reference`, a local rotation that is
usually the rest pose. Build them with `hinge_limit` and `cone_limit`.

| Kind | Behavior |
| --- | --- |
| `HINGE` | Keeps the rotation about `axis`, clamped to `[min_angle, max_angle]`, and drops the rest. A knee or elbow has one degree of freedom, so a pole off the hinge plane can leave the end short of the target. |
| `HINGE` with `twist_axis` | For rigs whose clips twist a joint about its bone axis (Rigify `DEF-shin`). `twist_axis` is a unit vector perpendicular to `axis`. The hinge splits the rotation into a swing and a twist about the bone, clamps the swing's angle about `axis` and keeps the twist unbounded. The kept twist equals the clip's twist when the solve's correction turns about an axis perpendicular to the bone, as a planar knee does. |
| `CONE` | Clamps the angle between the rotated `axis` and `axis` to `max_angle` and keeps the twist. |

Any clamped joint may leave the end short of the target, because the middle joint is solved against the unlimited root.
`limits[2]` is unused.

## Run the example

```bash
python3 scripts/build.py --example ik
```

`ik` shows two instances of the CC0 Quaternius mannequin on a moving support. Caller-authored cues acquire, plant, release
and replant each foot while the support translates, yaws, tilts and changes uniform scale, and the panel shows each
foot's contact phase. Contact mode uses unconstrained legs; `--limits` enables the authored knee hinges, and `--legacy`
selects height-field placement with those hinges. The spine, neck and head follow the camera and the right hand
reaches an orbiting sphere.

## See also

- [Animation](animation.md) for the update sequence that precedes IK.
- [Camera-relative rendering](large_world.md#protocol) for origin rebasing of contacts.
- [Scene](scene.md) for nodes and transform spaces.
