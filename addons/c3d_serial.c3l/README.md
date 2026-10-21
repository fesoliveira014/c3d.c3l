# c3d_serial

Scene serialization for c3d. Module `c3d::serial`, package `c3d_serial`. It saves a scene subtree as a versioned binary blob or a JSONC document, restores it under any live parent, and exports a JSON schema of the registered components. Every component type has an explicit policy: an authored codec or a transient marker. See [Serialization](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization.md) for the model and common tasks, and the [reference](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization_reference.md) for the wire format, component versions and faults.

## Package and boundaries

- `c3d::serial` imports the standard library and `c3d`. It creates no GPU resource and no native system, and it imports no renderer or platform dependency.
- Core never imports it and has no serialization flag. Select `c3d_serial` beside `c3d` in the consumer's dependencies.
- Other add-ons import it only behind their own feature: `C3D_PHYSICS_SERIAL`, `C3D_NAV_SERIAL`, `C3D_CHARACTER_SERIAL`, `C3D_LANDSCAPE_SERIAL`, `C3D_PARTICLE_SERIAL` and `C3D_AUDIO_SERIAL`. A consumer that enables one selects `c3d_serial` and that add-on explicitly.
- A read never modifies the `AssetStore` and creates no GPU device, physics world or navigation system.

## Quick start

Register the codecs once during single-threaded setup. Both write and read need an enclosing `@pool()`.

```c3
import c3d;
import c3d::asset;
import c3d::scene;
import c3d::serial;

fn void? setup() {
    serial::register_core_codecs()!;
}

fn void? copy_subtree(Scene* scene, AssetStore* assets, Node* root) {
    @pool() {
        char[] bytes = serial::write_subtree(tmem, scene, assets, root)!;
        Node* copy = serial::read_subtree(scene, assets, bytes)!;
    };
}
```

A component with no codec or transient policy makes export fail with `c3d::UNSUPPORTED`. The destination scene must register the component stores and removal hooks the document names before a read.

## Targets

Run a test target with `c3c test <target> --path addons/c3d_serial.c3l`. `scripts/build.py --test` runs every test target below except `serial_lookup_bench`.

| Target | Covers |
| --- | --- |
| `serial_test` | Container layout, byte helpers, subtree round trips and diagnostics |
| `serial_order_forward`, `serial_order_reverse` | Identical wire bytes whatever the registration order; run in separate processes |
| `serial_text_test` | JSONC parser, limits, number spelling and text diagnostics |
| `serial_described_test` | Described values, core codecs, text import and schema export |
| `serial_core_policy_test` | Every assigned core component has exactly one expected policy |
| `serial_all_test` | Every adapter together, without a GPU device: the policy inventory and a scene holding every authored type through binary and JSONC |

`serial_all_test` selects every serialization feature and add-on, including `C3D_CHARACTER_NAV`.

Two CPU measurement targets stay outside `scripts/build.py --test`:

- `serial_lookup_bench` is a test target that times authored lookup on large JSONC documents. Print its timings with `c3c test serial_lookup_bench --path addons/c3d_serial.c3l -O3 --test-show-output`.
- `serial_claims_bench` is an executable that times export with ownership claims. It selects the same features as `serial_all_test`. Build it with `c3c build serial_claims_bench --path addons/c3d_serial.c3l -O3`, then run `addons/c3d_serial.c3l/build/serial_claims_bench --copies=N --run=M`, with `N` of 1, 10 or 100 scene copies and `M` the run number. Each run prints one CSV row: copies, run, live nodes, live components, retained nodes, serialized records, claims, bytes, then preparation, collection, component-write and total binary-export times in milliseconds. Neither target asserts a time.

The `serialize` example in the repository's `examples/` project round-trips a model scene through both encodings. See the [guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization.md#run-the-example) for its flags.
