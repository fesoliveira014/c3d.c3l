# Scene serialization

Select c3d_serial explicitly beside c3d in the consumer's dependencies. Core does not register codecs or depend on this package.

This delivery provides the versioned binary container, ordinary scene-node round trips, explicit application component codecs, portable node/asset references, ownership projection and rollback. Core component codecs and ModelInstance reconstruction are not yet available. A component with no codec or transient policy returns c3d::UNSUPPORTED.

Register component stores and removal hooks on the destination Scene before reading. Register the matching serialization policies once during single-threaded setup. Codec names have static lifetime and remain stable across module/type renames.

Read [the contract and wire format](../../docs/serialization.md) before implementing a codec. Both write_subtree and read_subtree use caller-owned temporary scratch, so call them inside @pool(). The writer's returned buffer belongs to the allocator passed to it.

CPU tests:

~~~powershell
c3c test serial_test --path addons/c3d_serial.c3l
c3c test serial_order_forward --path addons/c3d_serial.c3l
c3c test serial_order_reverse --path addons/c3d_serial.c3l
~~~

The two registration-order targets run in separate processes and compare against the same specified wire bytes. scripts/build.py --test runs all three targets.
