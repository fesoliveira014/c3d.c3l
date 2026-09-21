# Manual GPU submission acceptance

Build the repository once so `shaders/spv/` exists, then invoke this project
separately:

```bash
python3 scripts/build.py --target compute_textures
c3c test acceptance --path test/gpu/render
```

These tests create a real Vulkan device with validation enabled and read the
renderer's debug log for validation errors. They do not run in the root test
matrix or CI. On Windows, the build step places the shader compiler DLL beside
this project's executable in `build/render_acceptance`.

The workload is headless: one box whose material samples an empty storage
texture, two render targets (`RGBA16_FLOAT`, `RGBA8_UNORM`), a compute shader
that stores a root color into a storage texture and one that samples a
texture or target into a readback buffer.

What the four cases establish:

- `render_to` completes for `LINEAR_HDR` and `DISPLAY_LDR` and writes the
  target; a `render_to` that faults closes the frame and frees its view.
- A warm frame with only a fullscreen draw or only a compute dispatch submits;
  a frame with no recorded work is discarded without a fault.
- A storage texture uploaded, written and sampled in one frame, written twice
  in one frame, or written in a frame that is aborted before submission keeps
  a valid layout; the next frame's reads return the last submitted color.

- Two live scenes whose meshes share entity ids get distinct palette and
  morph blocks in one frame; a view's previous pose is published only by a
  submitted frame and dropped by an aborted one; an orthographic camera with
  motion blur leaves the background at the clear color under camera motion.

- Five boxes sharing one material resolve it once per view and look up one
  pipeline per draw item; a shadowed skinned and morphed box records its
  shadow layer with the pipeline prepared once.

What they cannot establish: window clear-only and GUI-only frames need a
window (run the `clear` and `cube_gui` examples with validation), and a
presentation failure after submission needs a hardware observation.
