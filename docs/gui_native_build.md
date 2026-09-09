# Building the GUI native archive

The c3imgui.c3l v0.1.1 release supplies prebuilt native archives. Its Linux archive references
`__isoc23_sscanf`; linking it on Ubuntu 22.04 with glibc 2.35 fails because that symbol is
absent. Building the matching native source on that host provides a compatible archive.

Initialize the c3d submodules first. Install a C++ compiler, Python's venv support, and the
SDL3/OpenGL development headers used by the project. The generator's Python dependencies are
installed in its own environment; c3d's build scripts remain standard-library-only.

From the c3d root:

```bash
git clone --branch v0.1.1 --recurse-submodules \
    https://github.com/fesoliveira014/c3imgui-build.git .deps/c3imgui-build
bash .deps/c3imgui-build/scripts/bootstrap.sh
bash .deps/c3imgui-build/scripts/generate.sh
OPTIONAL_BACKENDS='' bash .deps/c3imgui-build/scripts/build_linux_x64.sh
cp .deps/c3imgui-build/c3imgui.c3l/linked-libs/linux-x64/libdcimgui.a \
    lib/c3imgui.c3l/linked-libs/linux-x64/libdcimgui.a
python3 scripts/build.py --test
```

The build script uses `clang++` by default; `CXX` can select another compatible C++ compiler.
Its layout probe checks native structure sizes. The empty OPTIONAL_BACKENDS selection retains
the core SDL3/OpenGL backends needed by c3d without adding optional native link dependencies.

The build tag pins the same c3imgui package as c3d, ImGui v1.92.8-docking and its matching C
wrapper generator. Keep the C3 declarations from that package; do not patch symbols or edit
generated bindings to work around a libc mismatch.

The local archive and `.deps/` are ignored. Ordinary builds use that local archive;
`--init-deps` downloads the released archive again, so rebuild/copy it afterward on this host.
