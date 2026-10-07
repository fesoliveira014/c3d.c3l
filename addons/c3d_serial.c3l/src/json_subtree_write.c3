module c3d::serial;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;

<*
 Write an authored subtree as JSONC text.
 @param [&in] scene : "Owns root; structure remains unchanged."
 @param [&in] assets : "Resolves stable asset keys."
 @param [&in] root : "Live subtree root."
 @return "Text owned by the supplied allocator."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED, describe::MISSING_DESCRIPTION
 @require scene.world.is_alive(root.id)
*>
fn String? write_subtree_text(
    Allocator allocator,
    Scene* scene,
    AssetStore* assets,
    Node* root,
    TextWriteOptions options = TEXT_WRITE_OPTIONS_DEFAULT,
) {
    if (options.diagnostic) clear_serial_diagnostic(options.diagnostic);
    if (options.omissions) clear_omission_report(options.omissions);
    String? text = write_subtree_json(
        allocator: allocator,
        scene: scene,
        assets: assets,
        root: root,
        options: options,
    );
    if (catch excuse = text) {
        if (options.diagnostic && !options.diagnostic.cause) options.diagnostic.cause = excuse;
        return excuse~;
    }
    return text;
}

fn String? write_subtree_json(
    Allocator allocator,
    Scene* scene,
    AssetStore* assets,
    Node* root,
    TextWriteOptions options,
) @local {
    if (!text_limits_valid(options.limits) || (options.omit_binary_only && !options.omissions)) {
        return c3d::INVALID_ARGUMENT~;
    }
    WriteState state = prepare_export(
        scene: scene,
        assets: assets,
        root: root,
        diagnostic: options.diagnostic,
    )!;
    WriteContext context = { .scene = scene, .assets = assets, .state = &state, .diagnostic = options.diagnostic };
    collect_text_omissions(&context, options)!;
    JsonOutput measured = { .writer = measuring_writer(), .limits = options.limits };
    emit_subtree_json(&context, &measured, options)!;
    char[] bytes = alloc::new_array_try(allocator, char, (sz)measured.writer.written()) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, bytes.ptr);
    JsonOutput output = { .writer = writer_over(bytes), .limits = options.limits };
    state.filling = true;
    emit_subtree_json(&context, &output, options)!;
    return (String)bytes;
}

fn void? collect_text_omissions(WriteContext* context, TextWriteOptions options) @local {
    uint count;
    foreach (record, node : context.state.ordered[:context.state.count]) {
        ComponentMask retained = context.scene.world.mask(node.id)
          & ~context.state.projection[node.id.index].omitted_components;
        foreach (slot : context.state.slots[:context.state.type_count]) {
            if (!(retained & ecs::slot_bit(slot)) || codecs[slot].described) continue;
            if (!options.omit_binary_only) {
                return component_diagnostic(
                    diagnostic: options.diagnostic,
                    record: (uint)record,
                    type_name: codecs[slot].codec.name,
                    cause: c3d::UNSUPPORTED,
                )~;
            }
            count++;
        }
    }
    if (!count) return;
    OmissionReport* report = options.omissions;
    report.components = alloc::new_array_try(report.allocator, OmittedComponent, count) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch clear_omission_report(report);
    uint index;
    foreach (record, node : context.state.ordered[:context.state.count]) {
        ComponentMask retained = context.scene.world.mask(node.id)
          & ~context.state.projection[node.id.index].omitted_components;
        foreach (slot : context.state.slots[:context.state.type_count]) {
            if (!(retained & ecs::slot_bit(slot)) || codecs[slot].described) continue;
            OmittedComponent* entry = &report.components[index++];
            entry.node_path = serial_node_path(report.allocator, (uint)record)!;
            entry.type_name = copy_serial_string(report.allocator, codecs[slot].codec.name)!;
        }
    }
}

fn void? emit_subtree_json(WriteContext* context, JsonOutput* output, TextWriteOptions options) @local {
    output.begin("", true)!;
    output.unsigned("version", SUBTREE_VERSION)!;
    output.begin("nodes", false)!;
    foreach (record, node : context.state.ordered[:context.state.count]) {
        NodeProjection* projection = &context.state.projection[node.id.index];
        context.node = node;
        output.begin("", true)!;
        output.unsigned("id", (ulong)record)!;
        if (record) {
            output.unsigned("parent", context.state.projection[node.parent.id.index].record)!;
        } else {
            output.literal("parent", "null")!;
        }
        output.string("name", node.name)!;
        output.begin("local", true)!;
        output.lanes(name: "position", values: (uint*)&projection.local.position, count: 3)!;
        output.lanes(name: "rotation", values: (uint*)&projection.local.rotation, count: 4)!;
        output.lanes(name: "scale", values: (uint*)&projection.local.scale, count: 3)!;
        output.end()!;
        output.string("transform_space", TransformSpace::names[node.transform_space.ordinal])!;
        output.unsigned("layers", node.layers)!;
        output.boolean("visible", node.visible)!;
        output.begin("components", true)!;
        ComponentMask retained = context.scene.world.mask(node.id) & ~projection.omitted_components;
        foreach (slot : context.state.slots[:context.state.type_count]) {
            if (!(retained & ecs::slot_bit(slot)) || !codecs[slot].described) continue;
            context.slot = slot;
            DescribedBinding* binding = codecs[slot].described;
            if (catch excuse = emit_component_json(context, output, binding)) {
                return component_diagnostic(
                    diagnostic: options.diagnostic,
                    record: (uint)record,
                    type_name: binding.codec.name,
                    cause: excuse,
                )~;
            }
        }
        output.end()!;
        output.end()!;
    }
    output.end()!;
    output.end()!;
}

fn void? emit_component_json(WriteContext* context, JsonOutput* output, DescribedBinding* binding) @local {
    output.begin(binding.codec.name, true)!;
    output.unsigned("version", binding.type.version)!;
    output.begin("value", true)!;
    Acquisitions owned = { .allocator = tmem };
    defer owned.release();
    void* value = owned.acquire(1, binding.type.descriptor.size, binding.type.descriptor.alignment)!;
    binding.codec.project(context.scene.world.component(context.node.id, context.slot), value, context)!;
    write_described_json(type: binding.type, output: output, context: context, value: value)!;
    output.end()!;
}
