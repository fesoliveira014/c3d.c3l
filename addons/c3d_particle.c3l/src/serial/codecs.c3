module c3d::particle @feat(C3D_PARTICLE_SERIAL);

import c3d;
import c3d::describe;
import c3d::ecs;
import c3d::scene;
import c3d::serial;
import std::math;

const ulong RANGE_LAYOUT @private = 0xaf1f0c33b5e51627;
const ulong TABLE_LAYOUT @private = 0xe4c18077262a7a22;
const ulong COLOR_TABLE_LAYOUT @private = 0x4eacd1a988dfc1b2;
const ulong DESC_LAYOUT @private = 0x1a366da2bd207420;
const ulong AUTHORING_LAYOUT @private = 0xea58cb75a4a73416;

struct ParticleAuthoring @private {
    ParticleSystemDesc desc;
    bool emitting;
}

<*
 Register particle authoring codecs and generated draw ownership.
 @return? describe::DESCRIPTION_CONFLICT, describe::MISSING_DESCRIPTION
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn void? register_serial_codecs() {
    serial::register_core_value_types()!;
    register_value(ParticleRange, RANGE_LAYOUT, &defaults_range)!;
    register_value(LifetimeTable, TABLE_LAYOUT, &defaults_table)!;
    register_value(LifetimeColorTable, COLOR_TABLE_LAYOUT, &defaults_color_table)!;
    register_value(ParticleSystemDesc, DESC_LAYOUT, &defaults_desc)!;
    register_value(ParticleAuthoring, AUTHORING_LAYOUT, &defaults_authoring)!;
    serial::register_described_owner(ParticleSystem, ParticleAuthoring, {
        .name = "particle_system",
        .phase = VALUE,
        .collect = &collect_system,
        .project = &project_system,
        .validate = &validate_system,
        .attach = &attach_system,
    })!;
    serial::register_transient(ParticleDrawOwner, &collect_draw)!;
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

fn void defaults_range(void* value) @private => *(ParticleRange*)value = {};
fn void defaults_table(void* value) @private => ((LifetimeTable*)value).values[..] = 1;
fn void defaults_color_table(void* value) @private => ((LifetimeColorTable*)value).values[..] = (Vec4){ 1, 1, 1, 1 };
fn void defaults_desc(void* value) @private => *(ParticleSystemDesc*)value = default_particle_system_desc();
fn void defaults_authoring(void* value) @private {
    *(ParticleAuthoring*)value = { .desc = default_particle_system_desc(), .emitting = true };
}

fn void? project_system(void* component, void* value, serial::WriteContext* context) @private {
    ParticleSystem* system = component;
    check_particle_desc(&system.desc)!;
    *(ParticleAuthoring*)value = { .desc = system.desc, .emitting = system.emitting };
}

fn void? validate_system(void* value, serial::ReadContext* context) @private {
    check_particle_desc(&((ParticleAuthoring*)value).desc)!;
}

fn void? attach_system(void* value, serial::ReadContext* context) @private {
    ParticleAuthoring* authoring = value;
    context.scene.attach_particle_system(context.node, authoring.desc)!;
    context.scene.get(context.node, ParticleSystem).emitting = authoring.emitting;
}

fn void? collect_system(void* component, serial::WriteContext* context) @private {
    ParticleSystem* system = component;
    if (!system.is_prepared()) return;
    if (!context.scene.world.is_alive(system.draw_node)) return c3d::INVALID_ARGUMENT~;
    Node* draw = context.scene.node(system.draw_node);
    ParticleDrawOwner* owner = context.scene.get(draw, ParticleDrawOwner);
    if (!owner || !c3d::same_id(owner.emitter, context.node.id) || draw.parent != context.node) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (system.desc.render_mode == ParticleRenderMode.MESH) {
        if (!context.scene.has(draw, InstancedMesh)) return c3d::INVALID_ARGUMENT~;
        context.omit_component(draw, ecs::slot_of(InstancedMesh)!)!;
    } else {
        if (!context.scene.has(draw, BillboardBatch)) return c3d::INVALID_ARGUMENT~;
        context.omit_component(draw, ecs::slot_of(BillboardBatch)!)!;
    }
    context.omit_node(draw)!;
}

fn void? collect_draw(void* component, serial::WriteContext* context) @private {
    ParticleDrawOwner* owner = component;
    if (!context.scene.world.is_alive(owner.emitter)) return c3d::INVALID_ARGUMENT~;
    Node* emitter = context.scene.node(owner.emitter);
    if (!context.contains_node(emitter) || context.node.parent != emitter) return c3d::INVALID_ARGUMENT~;
    ParticleSystem* system = context.scene.get(emitter, ParticleSystem);
    if (!system || !system.is_prepared() || !c3d::same_id(system.draw_node, context.node.id)) {
        return c3d::INVALID_ARGUMENT~;
    }
}
