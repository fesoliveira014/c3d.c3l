# Serialization

`c3d_serial` saves a scene subtree as a portable binary blob or a JSONC document and restores it under any live parent. Every component type has an explicit policy: an authored codec, which writes versioned fields, or a transient marker, which keeps runtime state out of the stream. The package provides module `c3d::serial` and imports only the standard library and core. Core has no serialization import and no feature flag. Add-ons expose their codecs behind `C3D_<ADDON>_SERIAL` features.

A read creates no GPU resource, physics world or navigation system, and never changes the `AssetStore`. Owners that need runtime state restore as pending and finish through an explicit prepare call.

The wire layout, component versions, numeric domains and the JSONC profile are in the [reference](serialization_reference.md).

## Quick start

Select `c3d_serial` beside `c3d` in the target's dependencies. Register the codecs once during single-threaded setup, then save and load inside a `@pool()`.

```c3
import c3d;
import c3d::asset;
import c3d::scene;
import c3d::serial;

fn void? setup() {
    serial::register_core_codecs()!;
}

fn void? save_and_load(Scene* scene, AssetStore* assets, Node* root) {
    @pool() {
        char[] bytes = serial::write_subtree(tmem, scene, assets, root)!;
        Node* copy = serial::read_subtree(scene, assets, bytes)!;

        String text = serial::write_subtree_text(tmem, scene, assets, root)!;
        Node* from_text = serial::read_subtree_text(scene, assets, text)!;

        String schema = serial::write_schema(tmem)!;
    };
}
```

`read_subtree` and `read_subtree_text` create the restored root under `Scene.root`; pass `parent` to choose another live node. Output allocated with `tmem` lives until the enclosing pool ends. Allocate with a longer-lived allocator to keep a document.

## Concepts

### Documents

A document holds one subtree: the root, its descendants and their components. Each node saves its name, local transform, transform space, layers, visibility, hierarchy and sibling order. World matrices and effective visibility are derived on load, relative to a parent whose world matrix is current.

Node transform values pass through unchanged, as a direct assignment to `node.local` does. The container does not reject non-finite values or a zero quaternion. Component codecs validate their own numeric domains (see [authored numeric domains](serialization_reference.md#authored-numeric-domains)).

Two writes of unchanged authored state, and save-load-save, produce identical bytes. Process identities and registration order never affect the output.

### Policies, names and versions

A type with no policy makes export fail with `UNSUPPORTED`; nothing is dropped silently. `is_serializable(Type)` reports whether a type has a policy.

An authored codec has a portable name, a version and a restore phase. The name and version are the wire identity. Module paths, type names and registration order never enter the stream. A described codec reads older versions through explicit compatibility readers (binary) and listed default versions (JSONC). A manual codec reads older layouts itself, by switching on `ReadContext.version`. Newer versions fault `UNSUPPORTED`. The [versions table](serialization_reference.md#versions-and-older-payloads) lists the current version of every built-in component and what older payloads read as.

A transient policy marks runtime state that no document carries. An owner regenerates it when it prepares.

### Restore phases

Every node of a document exists before any component restores. Components then restore in four phases, in this order:

| Phase | Restores | Examples |
| --- | --- | --- |
| `VALUE` | Self-contained values | `Mesh`, `Light`, batches, `PhysicsBody`, `Terrain`, `ParticleSystem` |
| `REFERENCES` | Components that resolve nodes, models or assets | `ModelInstance`, `SkinBinding`, `PhysicsJoint`, `NavSource`, `Character` |
| `OWNER` | Owners that read other restored authoring | `Animator`, `AnimatedCrowd`, `Cloth`, `Ragdoll`, `Breakable`, `Foliage`, `Water` |
| `BINDINGS` | Bindings over restored owners | `LodGroup`, `CrowdCloth` |

The application owns dependencies between its own codecs; the phase order is not a scheduler.

### References

Node and entity references save as record indices within the document. A reference to a node outside the saved subtree, to an omitted node or to a node of another scene faults `INVALID_ARGUMENT` on export.

Asset references save by key. The asset must be live and have a nonempty key; each distinct key is stored once. The destination `AssetStore` must already hold every key a document names. A missing key or a key of another kind faults `INVALID_ID`. Asset payloads never enter a document. Custom asset kinds (see [custom assets](custom_assets.md)) save by key too, once the kind is registered on the store.

### Generated state and pending owners

Owners create nodes and components when they prepare: draw children, foliage cells, water mirrors, native bodies. Export verifies the owning component and omits that state. Exporting a generated node on its own, or adding authored components to one, faults `INVALID_ARGUMENT`.

A read attaches owners such as cloth, terrain, water, particle systems, crowds and breakables as pending authoring. They draw and simulate nothing until the application prepares them. See [owner readiness](owner_readiness.md) for the calls and their order.

### Rollback

When a read faults after it creates nodes, the reader removes every new node and component through the owner hooks. Existing authored values, node and component counts, asset counts and revisions, and free node capacity stay unchanged. Entity generations, free-list order and borrowed component addresses are not rollback identities.

### Scratch memory

The write, read and schema calls use `tmem` scratch and require an enclosing `@pool()`. None opens an inner pool. Serialization is a load and save operation, not a per-frame system.

## Usage

### Register codecs

Register the destination's component stores and removal hooks through their owner APIs before reading. `create_scene` registers the built-in stores. An add-on registers its own, for example `physics::register_physics(scene)` or `nav::register_nav(scene)`. A document that names a component with no store in the destination faults `UNSUPPORTED`.

Each add-on installs its serialization policies behind a feature flag. Select `c3d_serial`, the add-on and the flag, then call the add-on's registration during setup.

| Owner | Feature | Registration |
| --- | --- | --- |
| Core | none | `serial::register_core_codecs()` |
| Physics | `C3D_PHYSICS_SERIAL` | `physics::register_serial_codecs()` |
| Navigation | `C3D_NAV_SERIAL` | `nav::register_serial_codecs()` |
| Character | `C3D_CHARACTER_SERIAL` and `C3D_PHYSICS_SERIAL` | `character::register_serial_codecs()` |
| Character with navigation | also `C3D_CHARACTER_NAV` and `C3D_NAV_SERIAL` | included in the character registration |
| Landscape | `C3D_LANDSCAPE_SERIAL` | `landscape::register_serial_codecs()` |
| Particles | `C3D_PARTICLE_SERIAL` | `particle::register_serial_codecs()` |
| Audio | `C3D_AUDIO_SERIAL` | `audio::register_serial_codecs()` |

Every registration is idempotent and installs its description and default prerequisites. A component type takes a process-wide slot when it registers, and the process holds at most 128 ([components](scene.md#components)); a file that names more fails `ASSET_FORMAT_ERROR`. Registering a codec assigns the slot and allocates no scene store. `ecs::assigned_slot(Type)` reads a type's zero-based slot without assigning one and faults `NOT_FOUND` when the type has none. `describe::register_core_components()` alone registers field descriptions for inspection without selecting serialization.

### Save and load a subtree

`write_subtree` allocates one exact-sized result that the caller frees with the same allocator. The scene and the store stay fixed for the call, and the root must be live. `read_subtree` copies persistent strings and arrays into owner storage with the scene allocator, so the blob can be released after success.

Pass a `SerialDiagnostic` to learn where a fault happened. The diagnostic keeps the component type and the `/nodes/<record>` path, plus the asset key or model details the owner supplies. It survives the rollback.

```c3
SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
defer serial::destroy_serial_diagnostic(&diagnostic);

ReadOptions options = serial::READ_OPTIONS_DEFAULT;
options.diagnostic = &diagnostic;
Node*? restored = serial::read_subtree(scene, assets, bytes, options: options);
if (catch excuse = restored) {
    io::printfn("%s in %s at %s", excuse, diagnostic.type_name, diagnostic.node_path);
}
```

Start every `ReadOptions` and `TextWriteOptions` value from its default constant (`READ_OPTIONS_DEFAULT`, `TEXT_WRITE_OPTIONS_DEFAULT`), as above. `WriteOptions` has no default constant; `{}` is its default. A struct literal for either text options type, such as `{ .diagnostic = &diagnostic }`, zeroes the text limits, and the text calls then fault `INVALID_ARGUMENT`.

### Export and import JSONC

The text calls use the same projections and policies as the binary calls. A document is one subtree object; the application manages files and extracts a document from a larger file. The reader accepts JSON with line and block comments.

Writers emit every field. A missing field takes its semantic default, and unknown fields and components fail unless `ReadOptions.skip_unknown` is set.

A component with a binary-only codec makes text export fail with `UNSUPPORTED`. To export the rest, set `omit_binary_only` and pass an initialized `OmissionReport`, which lists every omitted component by node path and type name.

```c3
OmissionReport report = serial::create_omission_report(mem);
defer serial::destroy_omission_report(&report);

TextWriteOptions options = serial::TEXT_WRITE_OPTIONS_DEFAULT;
options.omit_binary_only = true;
options.omissions = &report;
String text = serial::write_subtree_text(tmem, scene, assets, root, options)!;
foreach (omitted : report.components) io::printfn("omitted %s at %s", omitted.type_name, omitted.node_path);
```

The [text profile](serialization_reference.md#text-profile) defines limits, number spelling and import ordering.

### Export a schema

`write_schema(allocator)` writes the registered components and described types as JSON: names, versions, nested field layouts, kinds, array extents, enum names, units, ranges and semantic defaults. Binary-only codecs appear as `binary_only`. Editors and validators read the schema; the defaults are the ones text import applies.

### Add a described component

A described component declares its fields once. Binary, JSONC and schema output all derive from that description.

```c3
import c3d::describe;
import c3d::scene;
import c3d::serial;

const ulong SPINNER_LAYOUT = 0x684cfbbccbc7f2e2;

struct Spinner {
    float turns_per_second;
    uint axis;
}

fn void defaults_spinner(void* value) {
    *(Spinner*)value = { .turns_per_second = 1, .axis = 1 };
}

fn void? register_spinner(Scene* scene) {
    scene.register(Spinner)!;
    describe::register_reflected(Spinner)!;
    serial::register_described_type(
        $Type: Spinner,
        version: 1,
        layout: SPINNER_LAYOUT,
        defaults: &defaults_spinner,
    )!;
    serial::register_described(Spinner, { .name = "app.Spinner" })!;
}
```

1. Register the component store on every scene that reads or writes it.
2. Describe the type (see [type descriptions](type_descriptions.md)).
3. Pin its layout. `serial::description_layout(describe::get(Spinner)!)` computes the fingerprint to commit; a mismatch faults `INVALID_ARGUMENT`.
4. Bind the component with a portable name.

A type with strings or slices also needs an `attach` callback that copies them into the component and a remove hook that frees them. A changed layout needs a new version, a new pin and a `binary_compatibility` or `text_default_versions` entry for each older version still supported. `register_described_owner` binds a component through a separate authoring type. The [reference](serialization_reference.md#described-values) covers the full option set.

### Add a binary-only component

A manual codec writes its own bytes and has no text form.

```c3
struct Tag {
    uint id;
}

fn void? write_tag(void* component, Writer* writer, WriteContext* context) {
    writer.write_uint(((Tag*)component).id);
}

fn void? read_tag(Reader* reader, ReadContext* context) {
    context.scene.add(context.node, (Tag){ .id = reader.read_uint()! });
}

fn void? register_tag(Scene* scene) {
    scene.register(Tag)!;
    serial::register_codec(Tag, {
        .name = "app.Tag",
        .version = 1,
        .write = &write_tag,
        .read = &read_tag,
    })!;
}
```

A read callback must consume its whole payload, keep no pointer into the blob and free what it allocated if it fails. Use `register_transient(Type)` for runtime state that must not be saved.

### Mark generated nodes

An owner that generates nodes projects them out of the document in a `collect` callback: `omit_node` and `omit_component` claim verified generated state, and `set_local`, `set_transform`, `project_component` and `project_absent_component` substitute authored values. The [reference](serialization_reference.md#codec-api) lists the rules.

### Prepare owners after a load

A restored owner is pending. Call its prepare function, in the order the [owner readiness](owner_readiness.md) table gives, before the next update.

### Run the example

The `serialize` example loads the bundled Fox model and builds a cell of two instances (one animated), a 1,024-instance box batch and eight point lights. At startup it checks repeated writes and binary and JSONC read-write identity, removes the original subtree and shows a restored copy. The panel prints sizes, node and component counts and CPU write and read times. `R` or the button reloads the snapshot in the selected format. The camera, sun and scene settings stay outside the saved cell.

```bash
python3 scripts/build.py --example serialize
c3c build serialize --path examples -O3
./examples/build/serialize --cpu-only
./examples/build/serialize --cpu-only --export=cell
./examples/build/serialize --acceptance --frames=180
```

| Flag | Effect |
| --- | --- |
| `--cpu-only` | Runs the checks without a window or device |
| `--models=N` | Builds N model instances; the default and minimum is 2 |
| `--frames=N` | Exits after N frames |
| `--export=PREFIX` | Writes `PREFIX.bin`, `PREFIX.jsonc` and `PREFIX.schema.json` |
| `--original` | Keeps the authored cell on screen and runs the checks in a separate scene |
| `--acceptance` | Uses a fixed 1/60 s step and reloads JSONC at frame 60 and binary at frame 120 |

A direct `c3c build` that links shaderc needs its shared library next to the executable; the repository build script supplies it. Vulkan validation is on in windowed runs. Add `.exe` to the executable name on Windows.

## Limits

- Asset payloads, scene-wide ambient, background and environment settings, and cross-subtree references are outside the format. Saving `Scene.root` creates an ordinary new node on read and does not overwrite the destination scene's settings.
- Runtime state is not saved. Each owner's section in the [reference](serialization_reference.md#component-policies) lists what restarts.
- The container has one version. A newer container version faults `UNSUPPORTED`.
- Each binary write runs every codec twice, once to measure and once to fill. Both passes must emit identical bytes for the same scene state.
- Reader acquisitions that can fail return `CAPACITY_EXCEEDED` and release what they hold. Existing scene and owner allocations that cannot fail keep that contract; there is no blanket promise to survive out-of-memory.
- The index a read builds to find a component's authoring is sized by the document's node and component counts, never by the destination scene's capacity.

## See also

- [Serialization reference](serialization_reference.md): wire layout, API tables, component versions, numeric domains and text profile.
- [Owner readiness](owner_readiness.md): preparing pending owners after a load.
- [Type descriptions](type_descriptions.md): the field walk that described components use.
- [Custom assets](custom_assets.md): asset kinds that save by key.
- [Animation](animation.md), [models](models.md): the animation and model components a document restores.
- [Scene](scene.md#components): component stores and the slot limit.
- Add-on pages: [physics](../addons/c3d_physics.c3l/README.md), [navigation](../addons/c3d_nav.c3l/README.md), [character](../addons/c3d_character.c3l/README.md), [landscape](../addons/c3d_landscape.c3l/src/serial/README.md), [particles](../addons/c3d_particle.c3l/src/serial/README.md), [audio](audio.md).
