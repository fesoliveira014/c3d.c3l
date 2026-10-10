module c3d::scene;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::maths;
import std::math;

<* Maximum mesh levels, including full detail. *>
const uint MAX_LOD_LEVELS = 5; // four alternatives; bounds draw-bin count

<* Relative growth required to return to finer detail. *>
const float LOD_HYSTERESIS = 0.1f; // ten percent; limits threshold oscillation

const Vec4 LOD_COLOR_DEFAULT @local = { 1, 1, 1, 1 };

<* Placement source for a whole-object group. *>
enum LodMode {
    SINGLE,
    INSTANCED,
}

<* Geometry and material placed within one object level. *>
struct LodPart {
    GeometryId geometry;
    MaterialId material;
    Mat4 local;
}

<* Part range and minimum projected height for one level. *>
struct LodLevel {
    uint first_part;
    uint part_count;
    float min_screen_size;
}

<* Rigid alternatives ordered from finest to coarsest. *>
struct LodDesc {
    LodLevel[] levels;
    LodPart[] parts;
    bool has_bounds_override;
    Aabb local_bounds;
}

<* Shared wind, fade and render participation of all parts. *>
struct LodEffects {
    InstanceSway sway;
    InstanceFade fade;
    bool cast_shadow;
    bool receive_shadow;
    bool trace;
}

<* One explicit representation of a level-zero logical model mesh. *>
struct AnimatedLodPart {
    LodPart draw;
    uint mesh_index;
    ModelSkin skin;
    float[] default_morph_weights;
}

<* Whole-model alternatives borrowing authored part data during attachment. *>
struct AnimatedLodDesc {
    LodLevel[] levels;
    AnimatedLodPart[] parts;
    bool has_bounds_override;
    Aabb local_bounds;
}

<* Admitted source mesh, skin and selected logical-weight correspondence. *>
struct AnimatedLodPartBinding {
    uint mesh_index;
    uint template_node;
    bool skinned;
    SkeletonId skeleton;
    SkeletonId source_skeleton;
    uint source_skeleton_revision;
    uint geometry_revision;
    uint skeleton_revision;
    uint weight_offset;
    uint weight_count;
}

<* Copied binding metadata; source components are reacquired through source_owner. *>
struct AnimatedLodBinding {
    Entity source_owner;
    ModelId source_model;
    uint model_revision;
    uint source_revision;
    AnimatedLodPartBinding[] parts;
    uint[] weight_indices;
    uint[] channel_offsets;
    String[] channel_names;
    float[] defaults;
    uint[] joint_nodes;
    Mat4[] inverse_bind;
}

<* Scene-owned group data; only placement elements are directly writable. *>
struct LodGroupState {
    LodDesc desc;
    AnimatedLodBinding* animated;
    Impostor impostor;
    float impostor_min_screen_size;
    uint descriptor_revision;
    bool has_impostor;
    LodMode mode;
    LodEffects effects;
    Transform[] transforms;
    Vec4[] colors;
    uint[] slot_generations;
    uint count;
    uint revision;
    ulong identity;
    ulong instance_epoch;
    uint[] geometry_revisions;
    Aabb object_bounds;
    Aabb aggregate_bounds;
    uint bounds_revision;
    uint aggregate_revision;
}

<* Scene-owned drawable with shared placement storage. *>
struct LodGroup {
    LodGroupState* state;
}

struct LodBlockCursor @local {
    char* base;
    usz offset;
}

ulong lod_identity_counter @local;

<*
 Add one rigid object with whole-object alternatives.
 @param [&in] assets : "Supplies referenced geometry and materials."
 @param desc : "Copied into scene-owned storage."
 @param [in] parent : "Null selects the scene root."
 @param name : "Copied into the scene allocator."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn Node*? Scene.add_lod_group(
    &self,
    AssetStore* assets,
    LodDesc desc,
    Node* parent = null,
    String name = "",
) {
    LodGroup group = create_lod_group(self.allocator, assets, desc)!;
    defer catch destroy_lod_group(self.allocator, &group);
    Node* node = self.add_node(parent, name)!;
    self.world.add(node.id, group);
    return node;
}

<*
 Add fixed-capacity placements sharing whole-object alternatives.
 @param [&in] assets : "Supplies referenced geometry and materials."
 @param desc : "Copied into scene-owned storage."
 @param transforms : "Copied; determines the live count."
 @param colors : "Copied; omitted colours become white."
 @param [in] parent : "Null selects the scene root."
 @param name : "Copied into the scene allocator."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require capacity > 0
*>
fn Node*? Scene.add_instanced_lod_group(
    &self,
    AssetStore* assets,
    LodDesc desc,
    uint capacity,
    Transform[] transforms = {},
    Vec4[] colors = {},
    Node* parent = null,
    String name = "",
) {
    validate_lod_desc(assets, desc, LodMode.INSTANCED)!;
    if (transforms.len > capacity) return c3d::CAPACITY_EXCEEDED~;
    validate_lod_instances(transforms, colors)!;
    LodGroupState* state = copy_lod_group(self.allocator, desc, capacity)!;
    defer catch alloc::free(self.allocator, state);
    Node* node = self.add_node(parent, name)!;
    state.mode = LodMode.INSTANCED;
    fill_lod_instances(state, transforms, colors);
    self.world.add(node.id, (LodGroup){ .state = state });
    return node;
}

<*
 Replace live placements and reset their logical identities.
 @param [&in] node : "Carries an instanced group."
 @param transforms : "Copied into existing storage."
 @param colors : "Copied; omitted colours become white."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require self.has(node, LodGroup)
 @require self.get(node, LodGroup).state.mode == LodMode.INSTANCED
 @require !self.get(node, LodGroup).state.animated
*>
fn void? Scene.set_lod_instances(
    &self,
    Node* node,
    Transform[] transforms,
    Vec4[] colors = {},
) {
    LodGroupState* state = self.get(node, LodGroup).state;
    if (transforms.len > state.transforms.len) return c3d::CAPACITY_EXCEEDED~;
    validate_lod_instances(transforms, colors)!;
    fill_lod_instances(state, transforms, colors);
    self.publish_lod_instances(node, (uint)transforms.len);
}

<*
 Publish replacement placements, resetting their logical identities.
 @param [&in] node : "Carries valid transforms and colors through count."
 @require self.has(node, LodGroup)
 @require self.get(node, LodGroup).state.mode == LodMode.INSTANCED
 @require count <= self.get(node, LodGroup).state.transforms.len
 @require !self.get(node, LodGroup).state.animated
*>
fn void Scene.publish_lod_instances(&self, Node* node, uint count) {
    LodGroupState* state = self.get(node, LodGroup).state;
    state.count = count;
    state.instance_epoch++;
    advance_lod_revision(state);
}

<*
 Change live count, initializing newly exposed placements.
 @param [&in] node : "Carries an instanced group."
 @return? c3d::CAPACITY_EXCEEDED
 @require self.has(node, LodGroup)
 @require self.get(node, LodGroup).state.mode == LodMode.INSTANCED
 @require !self.get(node, LodGroup).state.animated
*>
fn void? Scene.resize_lod_instances(&self, Node* node, uint count) {
    LodGroupState* state = self.get(node, LodGroup).state;
    if (count > state.transforms.len) return c3d::CAPACITY_EXCEEDED~;
    for (uint index = state.count; index < count; index++) {
        state.transforms[index] = maths::TRANSFORM_IDENTITY;
        state.colors[index] = LOD_COLOR_DEFAULT;
        state.slot_generations[index]++;
    }
    state.count = count;
    advance_lod_revision(state);
}

<*
 Publish placement edits without changing logical identities.
 @param [&in] node : "Carries valid instanced group data."
 @require self.has(node, LodGroup)
 @require self.get(node, LodGroup).state.mode == LodMode.INSTANCED
*>
fn void Scene.mark_lod_instances_dirty(&self, Node* node) {
    advance_lod_revision(self.get(node, LodGroup).state);
}

<*
 Apply common wind, fade and render participation.
 @param [&in] node : "Carries a group."
 @require self.has(node, LodGroup)
 @require instance_effects_valid(effects.sway, effects.fade)
 @require !self.get(node, LodGroup).state.has_impostor || effects.sway.amplitude == 0 || effects.sway.weight == SwayWeight.HEIGHT
*>
fn void Scene.set_lod_effects(&self, Node* node, LodEffects effects) {
    LodGroupState* state = self.get(node, LodGroup).state;
    state.effects = effects;
}

<*
 Bound every level before placement; refreshes retained geometry revisions.
 @param [&in] assets : "Resolves every referenced geometry."
*>
fn Aabb LodGroupState.local_bounds(&self, AssetStore* assets) {
    bool stale = !self.bounds_revision;
    foreach (index, part : self.desc.parts) {
        uint revision = assets.geometry(part.geometry).header.revision;
        stale |= self.geometry_revisions[index] != revision;
        self.geometry_revisions[index] = revision;
    }
    if (!stale) return self.object_bounds;
    if (self.desc.has_bounds_override) {
        self.object_bounds = self.desc.local_bounds;
    } else {
        foreach (index, part : self.desc.parts) {
            Aabb bounds = maths::aabb_transform(assets.geometry(part.geometry).data.bounds, part.local);
            self.object_bounds = index ? maths::aabb_merge(self.object_bounds, bounds) : bounds;
        }
    }
    if (self.has_impostor) {
        Vec3 radius = { self.impostor.bounds.radius, self.impostor.bounds.radius, self.impostor.bounds.radius };
        self.object_bounds = maths::aabb_merge(self.object_bounds, {
            .min = self.impostor.bounds.center - radius,
            .max = self.impostor.bounds.center + radius,
        });
    }
    self.bounds_revision++;
    if (!self.bounds_revision) self.bounds_revision = 1;
    self.aggregate_revision = 0;
    return self.object_bounds;
}

<*
 Bound live placements before the owner transform and sway.
 @param [&in] assets : "Resolves every referenced geometry."
 @require self.count > 0
*>
fn Aabb LodGroupState.placement_bounds(&self, AssetStore* assets) {
    Aabb bounds = self.local_bounds(assets);
    if (self.mode == LodMode.SINGLE) return bounds;
    if (self.aggregate_revision == self.revision) return self.aggregate_bounds;
    foreach (index, transform : self.transforms[:self.count]) {
        Aabb placed = maths::aabb_transform(bounds, transform.to_mat4());
        self.aggregate_bounds = index ? maths::aabb_merge(self.aggregate_bounds, placed) : placed;
    }
    self.aggregate_revision = self.revision;
    return self.aggregate_bounds;
}

<*
 Create owned alternatives for transfer into a scene component.
 @param [&in] assets : "Supplies referenced geometry and materials."
 @param desc : "Copied into owned storage."
 @param capacity : "Zero selects ordinary mode; otherwise starts empty."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn LodGroup? create_lod_group(
    Allocator allocator,
    AssetStore* assets,
    LodDesc desc,
    uint capacity = 0,
) {
    LodMode mode = capacity ? LodMode.INSTANCED : LodMode.SINGLE;
    validate_lod_desc(assets, desc, mode)!;
    LodGroupState* state = copy_lod_group(allocator, desc, capacity)!;
    state.mode = mode;
    state.count = capacity ? 0 : 1;
    return { .state = state };
}

<*
 Release a group whose ownership has not transferred to a scene.
 @param [&inout] group : "Cleared; zero is accepted."
*>
fn void destroy_lod_group(Allocator allocator, LodGroup* group) {
    alloc::free(allocator, group.state);
    *group = {};
}

<*
 Choose a level with optional hysteresis history.
 @param screen_size : "Sphere diameter divided by viewport height."
 @require min_screen_sizes.len > 0
 @require screen_size >= 0
 @require !history_valid || previous < min_screen_sizes.len
 @pure
*>
fn uint select_lod_level(
    float screen_size,
    float[] min_screen_sizes,
    uint previous,
    bool history_valid,
) {
    if (!math::is_finite(screen_size)) return 0;
    uint level = history_valid ? previous : 0;
    while (level < min_screen_sizes.len - 1 && screen_size < min_screen_sizes[level]) level++;
    if (history_valid) {
        while (level > 0 && screen_size > min_screen_sizes[level - 1] * (1 + LOD_HYSTERESIS)) level--;
    }
    return level;
}

<*
 Validate rigid alternatives and their referenced assets.
 @param [&in] assets : "Supplies referenced geometry, materials and shaders."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
*>
fn void? validate_lod_desc(AssetStore* assets, LodDesc desc, LodMode mode) {
    validate_lod_layout(desc)!;
    foreach (part : desc.parts) {
        if (!assets.geometries.is_live(part.geometry) || !assets.materials.is_live(part.material)) {
            return c3d::INVALID_ID~;
        }
    }
    foreach (part : desc.parts) {
        GeometryAsset* geometry = assets.geometry(part.geometry);
        if (geometry.target_count || geometry.skin_bounds.joints.len || geometry.data.joints.len) {
            return c3d::UNSUPPORTED~;
        }
        if (!valid_lod_bounds(maths::aabb_transform(geometry.data.bounds, part.local))) {
            return c3d::INVALID_ARGUMENT~;
        }
        Material* material = &assets.material(part.material).data;
        if (material.kind != MaterialKind.CUSTOM) continue;
        if (!assets.shaders.is_live(material.custom.shader)) return c3d::INVALID_ID~;
        CustomVertex* vertex = &assets.shader(material.custom.shader).desc.vertex;
        if (vertex.shaded.len && (!desc.has_bounds_override || (mode == LodMode.INSTANCED && !vertex.instanced_shaded.len))) {
            return c3d::UNSUPPORTED~;
        }
    }
}

<*
 Validate level partitions, thresholds and part transforms without assets.
 @return? c3d::INVALID_ARGUMENT
*>
fn void? validate_lod_layout(LodDesc desc) {
    if (!desc.levels.len || desc.levels.len > MAX_LOD_LEVELS || desc.parts.len > uint::max) {
        return c3d::INVALID_ARGUMENT~;
    }
    usz first;
    foreach (index, level : desc.levels) {
        if (level.first_part != first || !level.part_count || level.part_count > desc.parts.len - first) {
            return c3d::INVALID_ARGUMENT~;
        }
        if (!math::is_finite(level.min_screen_size) || level.min_screen_size < 0) return c3d::INVALID_ARGUMENT~;
        if (index + 1 == desc.levels.len) {
            if (level.min_screen_size != 0) return c3d::INVALID_ARGUMENT~;
        } else if (level.min_screen_size <= desc.levels[index + 1].min_screen_size) {
            return c3d::INVALID_ARGUMENT~;
        }
        first += level.part_count;
    }
    if (first != desc.parts.len) return c3d::INVALID_ARGUMENT~;
    if (desc.has_bounds_override && !valid_lod_bounds(desc.local_bounds)) return c3d::INVALID_ARGUMENT~;
    foreach (part : desc.parts) {
        if (!valid_lod_matrix(part.local)) return c3d::INVALID_ARGUMENT~;
    }
}

fn bool valid_lod_matrix(Mat4 model) @local {
    foreach (value : ((float*)&model)[:Mat4::size / float::size]) {
        if (!math::is_finite(value)) return false;
    }
    float determinant = model.determinant();
    return model.m30 == 0 && model.m31 == 0 && model.m32 == 0 && model.m33 == 1
      && determinant != 0 && math::is_finite(determinant);
}

fn bool valid_lod_bounds(Aabb bounds) @local {
    for (uint axis = 0; axis < 3; axis++) {
        if (!math::is_finite(bounds.min[axis]) || !math::is_finite(bounds.max[axis])
          || bounds.min[axis] > bounds.max[axis]) return false;
    }
    return true;
}

fn void? validate_lod_instances(Transform[] transforms, Vec4[] colors) @local {
    if (colors.len > transforms.len) return c3d::INVALID_ARGUMENT~;
    foreach (transform : transforms) {
        if (!valid_lod_matrix(transform.to_mat4())) return c3d::INVALID_ARGUMENT~;
    }
}

fn void advance_lod_revision(LodGroupState* state) @local {
    state.revision++;
    if (!state.revision) state.revision = 1;
}

fn void fill_lod_instances(LodGroupState* state, Transform[] transforms, Vec4[] colors) @local {
    state.transforms[:transforms.len] = transforms[..];
    state.colors[:colors.len] = colors[..];
    state.colors[colors.len:transforms.len - colors.len] = LOD_COLOR_DEFAULT;
    state.count = (uint)transforms.len;
}

fn LodGroupState*? copy_lod_group(
    Allocator allocator,
    LodDesc desc,
    uint capacity,
    AnimatedLodBinding* binding = null,
) @local {
    LodBlockCursor measure;
    carve_lod_group(
        cursor: &measure,
        desc: desc,
        capacity: capacity,
        binding: binding,
    );
    char*? allocation = alloc::malloc_try(allocator, (sz)measure.offset);
    if (catch allocation) return c3d::CAPACITY_EXCEEDED~;
    LodBlockCursor fill = { .base = allocation };
    LodGroupState* state = carve_lod_group(
        cursor: &fill,
        desc: desc,
        capacity: capacity,
        binding: binding,
    );
    state.identity = ++lod_identity_counter;
    return state;
}

fn LodGroupState* carve_lod_group(
    LodBlockCursor* cursor,
    LodDesc desc,
    uint capacity,
    AnimatedLodBinding* binding = null,
) @local {
    LodGroupState[] states = carve_lod(cursor, LodGroupState, 1);
    LodLevel[] levels = carve_lod(cursor, LodLevel, desc.levels.len);
    LodPart[] parts = carve_lod(cursor, LodPart, desc.parts.len);
    uint[] geometry_revisions = carve_lod(cursor, uint, desc.parts.len);
    Transform[] transforms = carve_lod(cursor, Transform, binding ? 0 : capacity);
    Vec4[] colors = carve_lod(cursor, Vec4, binding ? 0 : capacity);
    uint[] generations = carve_lod(cursor, uint, capacity);
    AnimatedLodBinding* animated = carve_animated_lod(cursor, binding);
    if (cursor.base) {
        levels[..] = desc.levels[..];
        parts[..] = desc.parts[..];
        geometry_revisions[..] = 0;
        transforms[..] = maths::TRANSFORM_IDENTITY;
        colors[..] = LOD_COLOR_DEFAULT;
        generations[..] = 1;
        states[0] = {
            .desc = {
                .levels = levels,
                .parts = parts,
                .has_bounds_override = desc.has_bounds_override,
                .local_bounds = desc.local_bounds,
            },
            .animated = animated,
            .effects = { .cast_shadow = true, .receive_shadow = true, .trace = true },
            .transforms = transforms,
            .colors = colors,
            .slot_generations = generations,
            .revision = 1,
            .descriptor_revision = 1,
            .instance_epoch = 1,
            .geometry_revisions = geometry_revisions,
        };
    }
    return states.ptr;
}

macro carve_lod(LodBlockCursor* cursor, $Type, usz count) @local {
    cursor.offset = (usz)mem::aligned_offset((sz)cursor.offset, $Type::alignment);
    $Type[] slice;
    if (cursor.base) slice = (($Type*)(cursor.base + cursor.offset))[:count];
    cursor.offset += $Type::size * count;
    return slice;
}

fn void free_lod_group(Entity entity, void* component, void* user) @private {
    destroy_lod_group(*(Allocator*)user, (LodGroup*)component);
}

<* Copy admitted animated descriptors without owning the source model or playback. *>
fn LodGroup? create_animated_lod_group(
    Allocator allocator,
    LodDesc desc,
    AnimatedLodBinding binding,
    uint capacity,
) @private {
    LodGroupState* state = copy_lod_group(
        allocator: allocator,
        desc: desc,
        capacity: capacity,
        binding: &binding,
    )!;
    state.mode = capacity ? LodMode.INSTANCED : LodMode.SINGLE;
    state.count = capacity ? 0 : 1;
    state.effects.trace = false;
    return { .state = state };
}

<* Publish source edits without changing descriptor identity or selection history. *>
fn void publish_animated_lod_source(LodGroupState* state) @private {
    advance_lod_revision(state);
    state.aggregate_revision = 0;
}

fn AnimatedLodBinding* carve_animated_lod(
    LodBlockCursor* cursor,
    AnimatedLodBinding* source,
) @local {
    if (!source) return null;
    AnimatedLodBinding[] bindings = carve_lod(cursor, AnimatedLodBinding, 1);
    AnimatedLodPartBinding[] parts = carve_lod(cursor, AnimatedLodPartBinding, source.parts.len);
    uint[] indices = carve_lod(cursor, uint, source.weight_indices.len);
    uint[] offsets = carve_lod(cursor, uint, source.channel_offsets.len);
    String[] names = carve_lod(cursor, String, source.channel_names.len);
    float[] defaults = carve_lod(cursor, float, source.defaults.len);
    uint[] joints = carve_lod(cursor, uint, source.joint_nodes.len);
    Mat4[] inverse_bind = carve_lod(cursor, Mat4, source.inverse_bind.len);
    foreach (index, name : source.channel_names) {
        char[] text = carve_lod(cursor, char, name.len);
        if (cursor.base) {
            text[..] = name[..];
            names[index] = (String)text;
        }
    }
    if (!cursor.base) return null;

    parts[..] = source.parts[..];
    indices[..] = source.weight_indices[..];
    offsets[..] = source.channel_offsets[..];
    defaults[..] = source.defaults[..];
    joints[..] = source.joint_nodes[..];
    inverse_bind[..] = source.inverse_bind[..];
    bindings[0] = {
        .source_owner = source.source_owner,
        .source_model = source.source_model,
        .model_revision = source.model_revision,
        .source_revision = source.source_revision,
        .parts = parts,
        .weight_indices = indices,
        .channel_offsets = offsets,
        .channel_names = names,
        .defaults = defaults,
        .joint_nodes = joints,
        .inverse_bind = inverse_bind,
    };
    return bindings.ptr;
}

fn void publish_crowd_lod_owner(Scene* scene, Node* owner, AnimatedCrowd* crowd) @private {
    LodGroup* group = scene.get(owner, LodGroup);
    if (!group || !group.state.animated) return;
    if (group.state.transforms.ptr != crowd.placements.ptr) return;

    publish_crowd_lod_source(scene, group.state, crowd);
}

fn void publish_crowd_lod_source(Scene* scene, LodGroupState* state, AnimatedCrowd* crowd) @private {
    state.transforms = crowd.placements;
    state.colors = crowd.colors;

    uint count = crowd.is_prepared() ? crowd.count : 0;
    ulong epoch = crowd.playback ? crowd.playback.identity : 1;
    uint revision = crowd.parts.len ? scene.world.get(crowd.parts[0].batch, InstancedMesh).revision : 0;
    bool changed = state.count != count || state.instance_epoch != epoch
      || state.animated.source_revision != revision;

    state.animated.source_revision = revision;
    state.count = count;
    state.instance_epoch = epoch;

    if (crowd.playback) {
        foreach (index, slot : crowd.playback.slots) {
            changed |= state.slot_generations[index] != slot.generation;
            state.slot_generations[index] = slot.generation;
        }
    }

    if (changed) publish_animated_lod_source(state);
}
