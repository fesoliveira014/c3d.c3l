module c3d::landscape @feat(C3D_LANDSCAPE_SERIAL);

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::describe;
import c3d::ecs;
import c3d::landscape::foliage @public;
import c3d::landscape::terrain @public;
import c3d::landscape::water @public;
import c3d::scene;
import c3d::serial;

const ulong TERRAIN_LAYOUT @private = 0x7638a7507fa65b33;
const ulong SCATTER_LAYOUT @private = 0x788326d1092caa6b;
const ulong SWAY_LAYOUT @private = 0x750cddc9cb008976;
const ulong FOLIAGE_LAYOUT @private = 0x20330122082bd780;
const ulong WAVE_LAYOUT @private = 0xb7ea583c7a255cb9;
const ulong WATER_LAYOUT @private = 0x74434d01389bb922;

struct FoliageAuthoring @private {
    GeometryId geometry;
    MaterialId material;
    LodDesc[] lod;
    Entity ground;
    float cell_size;
    ScatterRules rules;
    SwayTemplate sway;
    InstanceFade fade;
    bool cast_shadow;
    bool receive_shadow;
    bool trace;
}

<*
 Register landscape authoring codecs and generated-state ownership.
 @return? describe::DESCRIPTION_CONFLICT, describe::MISSING_DESCRIPTION
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn void? register_serial_codecs() {
    serial::register_core_value_types()!;
    register_value(TerrainDesc, TERRAIN_LAYOUT, &defaults_terrain)!;
    register_value(ScatterRules, SCATTER_LAYOUT, &defaults_scatter)!;
    register_value(SwayTemplate, SWAY_LAYOUT, &defaults_sway)!;
    register_value(FoliageAuthoring, FOLIAGE_LAYOUT, &defaults_foliage)!;
    register_value(Wave, WAVE_LAYOUT, &defaults_wave)!;
    register_value(WaterDesc, WATER_LAYOUT, &defaults_water)!;
    serial::register_described_owner(Terrain, TerrainDesc, {
        .name = "terrain",
        .phase = VALUE,
        .collect = &collect_terrain,
        .project = &project_terrain,
        .validate = &validate_terrain,
        .attach = &attach_terrain,
    })!;
    serial::register_described_owner(Foliage, FoliageAuthoring, {
        .name = "foliage",
        .phase = OWNER,
        .collect = &collect_foliage,
        .project = &project_foliage,
        .validate = &validate_foliage,
        .attach = &attach_foliage,
    })!;
    serial::register_described_owner(Water, WaterDesc, {
        .name = "water",
        .phase = VALUE,
        .collect = &collect_water,
        .project = &project_water,
        .validate = &validate_water,
        .attach = &attach_water,
    })!;
    serial::register_transient(TerrainRuntime, &collect_terrain_runtime)!;
    serial::register_transient(FoliageRuntime, &collect_foliage_runtime)!;
    serial::register_transient(foliage::FoliageCellOwner, &collect_foliage_cell)!;
    serial::register_transient(WaterRuntime, &collect_water_runtime)!;
    serial::register_transient(WaterMirror, &collect_water_mirror)!;
}

macro void? register_value($Type, ulong layout, serial::DefaultsFn defaults) @private {
    describe::register_reflected($Type)!;
    serial::register_described_type(
        $Type: $Type,
        version: 1,
        layout: layout,
        defaults: defaults,
    )!;
}

fn void defaults_terrain(void* value) @private => *(TerrainDesc*)value = terrain::default_terrain_desc();
fn void defaults_scatter(void* value) @private => *(ScatterRules*)value = foliage::default_foliage_desc().rules;
fn void defaults_sway(void* value) @private => *(SwayTemplate*)value = foliage::default_foliage_desc().sway;
fn void defaults_foliage(void* value) @private {
    *(FoliageAuthoring*)value = foliage_value(foliage::default_foliage_desc());
}
fn void defaults_wave(void* value) @private => *(Wave*)value = {};
fn void defaults_water(void* value) @private => *(WaterDesc*)value = water::default_water_desc();

fn FoliageAuthoring foliage_value(FoliageDesc desc) @private {
    return {
        .geometry = desc.geometry,
        .material = desc.material,
        .lod = desc.lod ? desc.lod[:1] : (LodDesc[]){},
        .ground = desc.ground,
        .cell_size = desc.cell_size,
        .rules = desc.rules,
        .sway = desc.sway,
        .fade = desc.fade,
        .cast_shadow = desc.cast_shadow,
        .receive_shadow = desc.receive_shadow,
        .trace = desc.trace,
    };
}

fn FoliageDesc foliage_desc(FoliageAuthoring* value) @private {
    return {
        .geometry = value.geometry,
        .material = value.material,
        .lod = value.lod.len ? &value.lod[0] : null,
        .ground = value.ground,
        .cell_size = value.cell_size,
        .rules = value.rules,
        .sway = value.sway,
        .fade = value.fade,
        .cast_shadow = value.cast_shadow,
        .receive_shadow = value.receive_shadow,
        .trace = value.trace,
    };
}

fn void? project_terrain(void* component, void* value, serial::WriteContext* context) @private {
    *(TerrainDesc*)value = ((Terrain*)component).desc;
    terrain::check_terrain_desc(context.assets, (TerrainDesc*)value)!;
}

fn void? project_foliage(void* component, void* value, serial::WriteContext* context) @private {
    FoliageDesc desc = ((Foliage*)component).desc;
    foliage::check_authoring(context.scene, context.assets, &desc)!;
    *(FoliageAuthoring*)value = foliage_value(desc);
}

fn void? project_water(void* component, void* value, serial::WriteContext* context) @private {
    *(WaterDesc*)value = ((Water*)component).desc;
    water::check_desc(context.assets, (WaterDesc*)value)!;
}

fn void? validate_terrain(void* value, serial::ReadContext* context) @private {
    if (context.has_component(InstancedMesh)) return c3d::INVALID_ARGUMENT~;
    terrain::check_terrain_desc(context.assets, (TerrainDesc*)value)!;
}

fn void? validate_foliage(void* value, serial::ReadContext* context) @private {
    FoliageAuthoring* authoring = value;
    if (authoring.lod.len > 1) return c3d::INVALID_ARGUMENT~;
    FoliageDesc desc = foliage_desc(authoring);
    foliage::check_desc(&desc)!;
    if (!context.scene.world.is_alive(desc.ground)) return c3d::INVALID_ID~;
    bool terrain_present;
    uint terrain_slot = ecs::slot_of(Terrain)!;
    foreach (index, node : context.nodes) {
        if (c3d::same_id(node.id, desc.ground)) {
            terrain_present = (context.component_masks[index] & ecs::slot_bit(terrain_slot)) != 0;
        }
    }
    if (!terrain_present) return c3d::INVALID_ID~;
    if (desc.lod) {
        scene::validate_lod_desc(context.assets, *desc.lod, LodMode.INSTANCED)!;
    } else if (!context.assets.geometries.is_live(desc.geometry) || !context.assets.materials.is_live(desc.material)) {
        return c3d::INVALID_ID~;
    }
    TextureAsset* density = context.assets.textures.try_get(desc.rules.density_map)!;
    foliage::check_density_map(density)!;
}

fn void? validate_water(void* value, serial::ReadContext* context) @private {
    if (context.has_component(Mesh)) return c3d::INVALID_ARGUMENT~;
    water::check_desc(context.assets, (WaterDesc*)value)!;
}

fn void? attach_terrain(void* value, serial::ReadContext* context) @private {
    terrain::attach_terrain(
        scene: context.scene,
        assets: context.assets,
        node: context.node,
        desc: *(TerrainDesc*)value,
    )!;
}

fn void? attach_foliage(void* value, serial::ReadContext* context) @private {
    foliage::attach_foliage(
        scene: context.scene,
        assets: context.assets,
        node: context.node,
        desc: foliage_desc((FoliageAuthoring*)value),
    )!;
}

fn void? attach_water(void* value, serial::ReadContext* context) @private {
    water::attach_water(
        scene: context.scene,
        assets: context.assets,
        node: context.node,
        desc: *(WaterDesc*)value,
    )!;
}

fn void? collect_terrain(void* component, serial::WriteContext* context) @private {
    TerrainRuntime* runtime = context.scene.get(context.node, TerrainRuntime);
    if (!runtime) return;
    InstancedMesh* batch = context.scene.get(context.node, InstancedMesh);
    if (!batch || !c3d::same_id(batch.material, runtime.material)) return c3d::INVALID_ARGUMENT~;
    GeometryId grid = context.assets.find_geometry("c3d_landscape/terrain_grid") ?? c3d::INVALID_ARGUMENT~!;
    if (!c3d::same_id(batch.geometry, grid)) return c3d::INVALID_ARGUMENT~;
    context.omit_component(context.node, ecs::slot_of(InstancedMesh)!)!;
}

fn void? collect_terrain_runtime(void* component, serial::WriteContext* context) @private {
    if (!context.scene.has(context.node, Terrain)) return c3d::INVALID_ARGUMENT~;
}

fn void? collect_foliage(void* component, serial::WriteContext* context) @private {
    FoliageRuntime* runtime = context.scene.get(context.node, FoliageRuntime);
    if (!runtime) return;
    foreach (uint cell_index, entity : runtime.cells) {
        if (!entity.generation) continue;
        if (!context.scene.world.is_alive(entity)) return c3d::INVALID_ARGUMENT~;
        Node* cell = context.scene.node(entity);
        foliage::FoliageCellOwner* owner = context.scene.get(cell, foliage::FoliageCellOwner);
        if (!owner || !c3d::same_id(owner.layer, context.node.id) || owner.cell_index != cell_index
            || cell.parent != context.node) {
            return c3d::INVALID_ARGUMENT~;
        }
        if (runtime.desc.lod) {
            if (!context.scene.has(cell, LodGroup)) return c3d::INVALID_ARGUMENT~;
            context.omit_component(cell, ecs::slot_of(LodGroup)!)!;
        } else {
            if (!context.scene.has(cell, InstancedMesh)) return c3d::INVALID_ARGUMENT~;
            context.omit_component(cell, ecs::slot_of(InstancedMesh)!)!;
        }
        context.omit_node(cell)!;
    }
}

fn void? collect_foliage_runtime(void* component, serial::WriteContext* context) @private {
    if (!context.scene.has(context.node, Foliage)) return c3d::INVALID_ARGUMENT~;
}

fn void? collect_foliage_cell(void* component, serial::WriteContext* context) @private {
    foliage::FoliageCellOwner* owner = component;
    if (!context.scene.world.is_alive(owner.layer)) return c3d::INVALID_ARGUMENT~;
    Node* layer = context.scene.node(owner.layer);
    if (!context.contains_node(layer) || context.node.parent != layer || !context.scene.has(layer, Foliage)) {
        return c3d::INVALID_ARGUMENT~;
    }
    FoliageRuntime* runtime = context.scene.get(layer, FoliageRuntime);
    if (!runtime || owner.cell_index >= runtime.cells.len
        || !c3d::same_id(runtime.cells[owner.cell_index], context.node.id)) return c3d::INVALID_ARGUMENT~;
}

fn void? collect_water(void* component, serial::WriteContext* context) @private {
    WaterRuntime* runtime = context.scene.get(context.node, WaterRuntime);
    if (!runtime) return;
    Mesh* mesh = context.scene.get(context.node, Mesh);
    if (!mesh || !c3d::same_id(mesh.material, runtime.material) || !c3d::same_id(mesh.geometry, runtime.grid)) {
        return c3d::INVALID_ARGUMENT~;
    }
    context.omit_component(context.node, ecs::slot_of(Mesh)!)!;
    if (!context.scene.world.is_alive(runtime.mirror)) return c3d::INVALID_ARGUMENT~;
    Node* mirror = context.scene.node(runtime.mirror);
    WaterMirror* owner = context.scene.get(mirror, WaterMirror);
    if (!owner || !c3d::same_id(owner.water, context.node.id) || mirror.parent != context.scene.root
        || !context.scene.has(mirror, Camera)) return c3d::INVALID_ARGUMENT~;
    if (context.contains_node(mirror)) {
        context.omit_component(mirror, ecs::slot_of(Camera)!)!;
        context.omit_node(mirror)!;
    }
}

fn void? collect_water_runtime(void* component, serial::WriteContext* context) @private {
    if (!context.scene.has(context.node, Water)) return c3d::INVALID_ARGUMENT~;
}

fn void? collect_water_mirror(void* component, serial::WriteContext* context) @private {
    WaterMirror* owner = component;
    if (!context.scene.world.is_alive(owner.water)) return c3d::INVALID_ARGUMENT~;
    Node* water_node = context.scene.node(owner.water);
    if (!context.contains_node(water_node) || !context.scene.has(water_node, Water)) return c3d::INVALID_ARGUMENT~;
    WaterRuntime* runtime = context.scene.get(water_node, WaterRuntime);
    if (!runtime || !c3d::same_id(runtime.mirror, context.node.id)) return c3d::INVALID_ARGUMENT~;
}
