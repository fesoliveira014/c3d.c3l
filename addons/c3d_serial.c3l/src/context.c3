module c3d::serial;

import c3d;
import c3d::asset;
import c3d::asset::custom;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::collections::list;
import std::collections::map;

<* Absent portable node or asset reference. *>
const uint INDEX_NONE = uint::max;

const uint OWNER_SLOT_SHIFT @local = 32;

struct NodeProjection @private {
    uint record;
    ComponentMask omitted_components;
    ulong node_owner;
    ulong local_owner;
    bool selected;
    Transform local;
}

struct ComponentClaim @private {
    uint node;
    uint slot;
    ulong owner;
}

struct WriteState @private {
    NodeProjection[] projection;
    Node*[] ordered;
    uint count;
    List{String} keys;
    HashMap{String, uint} key_index;
    List{ComponentClaim} claims;
    List{uint} payload_sizes;
    uint[ecs::MAX_COMPONENT_TYPES] slots;
    uint type_count;
    bool collecting;
    bool filling;
}

<* Borrowed scene inputs and export projection. *>
struct WriteContext {
    Scene* scene;
    AssetStore* assets;
    SerialDiagnostic* diagnostic;
    Node* node;
    uint slot;
    WriteState* state;
}

<* Borrowed destination and portable-reference tables. *>
struct ReadContext {
    Scene* scene;
    AssetStore* assets;
    Allocator allocator;
    SerialDiagnostic* diagnostic;
    Node*[] nodes;
    String[] keys;
    ComponentMask[] component_masks;
    Node* node;
    uint record;
    uint version;
}

<*
 Exclude an owner-generated node from the portable graph.
 @param [&in] node : "Generated node whose components are explicitly claimed."
 @return? c3d::INVALID_ARGUMENT
 @require self.state.collecting
*>
fn void? WriteContext.omit_node(&self, Node* node) {
    NodeProjection* projected = projection_of(self, node)!;
    ulong owner = owner_of(self);
    if (projected.node_owner && projected.node_owner != owner) return c3d::INVALID_ARGUMENT~;
    projected.node_owner = owner;
}

<*
 Exclude a component reconstructed by the current owner.
 @param [&in] node : "Node carrying the owned component."
 @return? c3d::INVALID_ARGUMENT
 @require self.state.collecting && slot < ecs::MAX_COMPONENT_TYPES
*>
fn void? WriteContext.omit_component(&self, Node* node, uint slot) {
    NodeProjection* projected = projection_of(self, node)!;
    ulong owner = owner_of(self);
    foreach (claim : self.state.claims.array_view()) {
        if (claim.node == node.id.index && claim.slot == slot) {
            if (claim.owner != owner) return c3d::INVALID_ARGUMENT~;
            return;
        }
    }
    self.state.claims.push({ .node = node.id.index, .slot = slot, .owner = owner });
    projected.omitted_components |= ecs::slot_bit(slot);
}

<*
 Project a retained node's captured authoring transform.
 @param [&in] node : "Node owned by the current composite."
 @return? c3d::INVALID_ARGUMENT
 @require self.state.collecting
*>
fn void? WriteContext.set_local(&self, Node* node, Transform local) {
    NodeProjection* projected = projection_of(self, node)!;
    ulong owner = owner_of(self);
    if (projected.local_owner && projected.local_owner != owner) return c3d::INVALID_ARGUMENT~;
    if (projected.local_owner && (projected.local.position != local.position
        || projected.local.rotation.v != local.rotation.v || projected.local.scale != local.scale)) {
        return c3d::INVALID_ARGUMENT~;
    }
    projected.local_owner = owner;
    projected.local = local;
}

<*
 Encode a same-subtree node reference.
 @param [&inout] writer : "Receives the portable record index."
 @param [in] node : "Null encodes an absent reference."
 @return? c3d::INVALID_ARGUMENT
 @require !self.state.collecting
*>
fn void? WriteContext.write_node(&self, Writer* writer, Node* node) {
    if (!node) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    NodeProjection* projected = projection_of(self, node)!;
    if (projected.node_owner) return c3d::INVALID_ARGUMENT~;
    writer.write_uint(projected.record);
}

<*
 Encode a same-subtree entity reference.
 @param [&inout] writer : "Receives the portable record index."
 @return? c3d::INVALID_ARGUMENT
 @require !self.state.collecting
*>
fn void? WriteContext.write_entity(&self, Writer* writer, Entity entity) {
    if (!entity.index && !entity.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    if (!self.scene.world.is_alive(entity)) return c3d::INVALID_ARGUMENT~;
    self.write_node(writer, self.scene.node(entity))!;
}

<*
 Resolve a portable node reference.
 @param [&inout] reader : "Contains the next record reference."
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn Node*? ReadContext.read_node(&self, Reader* reader) {
    uint record = reader.read_uint()!;
    if (record == INDEX_NONE) return (Node*)null;
    if (record >= self.nodes.len) return c3d::ASSET_FORMAT_ERROR~;
    return self.nodes[record];
}

<*
 Resolve a portable entity reference.
 @param [&inout] reader : "Contains the next record reference."
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn Entity? ReadContext.read_entity(&self, Reader* reader) {
    Node* node = self.read_node(reader)!;
    return node ? node.id : (Entity){};
}

<*
 Whether the file independently restores a component on this node.
 @require self.scene.world.is_alive(self.node.id)
*>
macro bool ReadContext.has_component(&self, $Type) {
    if (try slot = ecs::assigned_slot($Type)) {
        return (self.component_masks[self.record] & ecs::slot_bit(slot)) != 0;
    }
    return false;
}

<*
 Encode a custom asset through its registered key.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
macro void? WriteContext.write_custom(
    &self,
    Writer* writer,
    $Type,
    id,
) {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    if (!self.assets.is_registered($Type)) return c3d::INVALID_ID~;
    String key = self.assets.pool($Type).try_get(id)!.header.key;
    write_key(self, writer, key)!;
}

<*
 Resolve a key of the selected custom asset kind.
 @param [&inout] reader : "Contains the next key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
macro ReadContext.read_custom(&self, Reader* reader, $Type) {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return (custom::CustomId{$Type}){};
    if (index >= self.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    if (!self.assets.is_registered($Type)) return c3d::INVALID_ID~;
    AssetRef reference = self.assets.find(self.keys[index]) ?? c3d::INVALID_ID~!;
    return asset::custom_id($Type, reference) ?? c3d::INVALID_ID~;
}

fn NodeProjection*? projection_of(WriteContext* context, Node* node) @private {
    if (node.id.index >= context.scene.nodes.len || &context.scene.nodes[node.id.index] != node
        || !context.scene.world.is_alive(node.id)) return c3d::INVALID_ARGUMENT~;
    NodeProjection* projected = &context.state.projection[node.id.index];
    if (!projected.selected) return c3d::INVALID_ARGUMENT~;
    return projected;
}

fn ulong owner_of(WriteContext* context) @local {
    return ((ulong)(context.node.id.index + 1) << OWNER_SLOT_SHIFT) | (ulong)(context.slot + 1);
}

fn void? write_key(WriteContext* context, Writer* writer, String key) @private {
    if (!key.len || !valid_utf8(key)) return c3d::INVALID_ARGUMENT~;
    if (try index = context.state.key_index.get(key)) {
        writer.write_uint(index);
        return;
    }
    if (context.state.filling) return c3d::INVALID_ARGUMENT~;
    if (context.state.keys.len() == uint::max) return c3d::CAPACITY_EXCEEDED~;
    uint index = (uint)context.state.keys.len();
    context.state.keys.push(key);
    context.state.key_index.set(key, index);
    writer.write_uint(index);
}
