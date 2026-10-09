module c3d_serial_all_test;

import c3d;
import c3d::anim;
import c3d::anim::ik;
import c3d::asset;
import c3d::asset::gltf;
import c3d::audio @public;
import c3d::camera;
import c3d::character;
import c3d::ecs @public;
import c3d::geometry;
import c3d::landscape;
import c3d::landscape::terrain;
import c3d::landscape::foliage @public;
import c3d::landscape::water;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::nav;
import c3d::particle @public;
import c3d::physics;
import c3d::physics::cloth;
import c3d::scene;
import c3d::serial @public;
import std::io::path;
import std::math;

const uint AUTHORED_TYPES @private = 39;
const uint TRANSIENT_TYPES @private = 14;

fn uint[] policy_slots() @private {
    uint[] slots = alloc::new_array(tmem, uint, AUTHORED_TYPES + TRANSIENT_TYPES);
    slots[..] = ((uint[53]){
        ecs::assigned_slot(Mesh)!!, ecs::assigned_slot(Camera)!!, ecs::assigned_slot(Light)!!,
        ecs::assigned_slot(ProbeVolume)!!, ecs::assigned_slot(Atmosphere)!!, ecs::assigned_slot(HeightFog)!!,
        ecs::assigned_slot(ReflectionProbe)!!, ecs::assigned_slot(Decal)!!, ecs::assigned_slot(InstancedMesh)!!,
        ecs::assigned_slot(BillboardBatch)!!, ecs::assigned_slot(LodGroup)!!, ecs::assigned_slot(ModelInstance)!!,
        ecs::assigned_slot(Animator)!!, ecs::assigned_slot(AnimatedCrowd)!!, ecs::assigned_slot(SkinBinding)!!,
        ecs::assigned_slot(IkChain)!!, ecs::assigned_slot(FootIk)!!, ecs::assigned_slot(LookAt)!!,
        ecs::assigned_slot(PhysicsBody)!!, ecs::assigned_slot(PhysicsJoint)!!, ecs::assigned_slot(Wind)!!,
        ecs::assigned_slot(Force)!!, ecs::assigned_slot(Buoyancy)!!, ecs::assigned_slot(Cloth)!!,
        ecs::assigned_slot(Ragdoll)!!, ecs::assigned_slot(Breakable)!!, ecs::assigned_slot(NavSource)!!,
        ecs::assigned_slot(NavVolume)!!, ecs::assigned_slot(NavLink)!!, ecs::assigned_slot(NavObstacle)!!,
        ecs::assigned_slot(NavAgent)!!, ecs::assigned_slot(Character)!!, ecs::assigned_slot(NavDriven)!!,
        ecs::assigned_slot(Terrain)!!, ecs::assigned_slot(Foliage)!!, ecs::assigned_slot(Water)!!,
        ecs::assigned_slot(ParticleSystem)!!, ecs::assigned_slot(AudioEmitter)!!, ecs::assigned_slot(AudioListener)!!,
        ecs::assigned_slot(RigidBody)!!, ecs::assigned_slot(Joint)!!, ecs::assigned_slot(NavSourceRuntime)!!,
        ecs::assigned_slot(NavVolumeRuntime)!!, ecs::assigned_slot(NavLinkRuntime)!!,
        ecs::assigned_slot(NavObstacleRuntime)!!, ecs::assigned_slot(CrowdAgentRuntime)!!,
        ecs::assigned_slot(TerrainRuntime)!!, ecs::assigned_slot(FoliageRuntime)!!,
        ecs::assigned_slot(FoliageCellOwner)!!, ecs::assigned_slot(WaterRuntime)!!,
        ecs::assigned_slot(WaterMirror)!!, ecs::assigned_slot(ParticleDrawOwner)!!,
        ecs::assigned_slot(AudioVoiceLink)!!,
    })[..];
    return slots;
}

fn void assert_presence(Scene* scene, bool prepared) @private {
    ComponentMask observed;
    foreach (&node : scene.nodes) {
        if (scene.world.is_alive(node.id)) observed |= scene.world.mask(node.id);
    }
    ComponentMask expected;
    foreach (index, slot : policy_slots()) {
        expected |= ecs::slot_bit(slot);
        assert(((observed & ecs::slot_bit(slot)) != 0) == (index < AUTHORED_TYPES || prepared));
    }
    foreach (slot, store : scene.world.stores) {
        if (store) assert(expected & ecs::slot_bit((uint)slot));
    }
}

fn void test_all_component_policies_are_complete_and_registration_is_idempotent() @test {
    @pool() {
        register_codecs();
        uint[] expected = policy_slots();
        assert(ecs::registered_type_count == expected.len);
        ComponentMask mask;
        foreach (index, slot : expected) {
            assert(!(mask & ecs::slot_bit(slot)));
            mask |= ecs::slot_bit(slot);
            serial::CodecEntry entry = serial::codecs[slot];
            assert(entry.transient == (index >= AUTHORED_TYPES));
            assert((entry.described != null) == (index < AUTHORED_TYPES));
            assert((entry.codec.name.len != 0) == (index < AUTHORED_TYPES));
        }
        register_codecs();
        assert(expected == policy_slots() && ecs::registered_type_count == expected.len);
        uint count;
        foreach (slot, entry : serial::codecs) {
            if (!entry.transient && !entry.codec.name.len) continue;
            assert(mask & ecs::slot_bit((uint)slot));
            count++;
        }
        assert(count == AUTHORED_TYPES + TRANSIENT_TYPES);
    };
}
