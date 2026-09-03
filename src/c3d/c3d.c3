module c3d;

<*
 Version of the library, in major.minor.patch form.
*>
const String VERSION = "0.0.0";

<*
 True when the developer GUI is compiled in.
*>
const bool GUI_ENABLED @feat(C3D_GUI) = true;

<*
 True when physics is compiled in and box3d is linked.
*>
const bool PHYSICS_ENABLED @feat(C3D_PHYSICS) = true;

<*
 True when the FBX importer is compiled in.
*>
const bool FBX_ENABLED @feat(C3D_FBX) = true;

<*
 True when ray tracing is compiled in.
*>
const bool RAY_TRACING_ENABLED @feat(C3D_RAY_TRACING) = true;

<*
 True when image decoding is compiled in and stb_image is linked.
*>
const bool STB_IMAGE_ENABLED @feat(C3D_STB_IMAGE) = true;
