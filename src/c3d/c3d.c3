module c3d;

<*
 Version of the library, in major.minor.patch form.
*>
const String VERSION = "0.0.0";

<*
 Present when the consumer selected the C3D_GUI feature; the GUI declarations follow the same guard.
*>
const bool GUI_ENABLED @feat(C3D_GUI) = true;

<*
 Present when the consumer selected the C3D_FBX feature; the FBX importer follows the same guard.
*>
const bool FBX_ENABLED @feat(C3D_FBX) = true;

<*
 Present when the consumer selected the C3D_RAY_TRACING feature; the ray tracing declarations follow the same guard.
*>
const bool RAY_TRACING_ENABLED @feat(C3D_RAY_TRACING) = true;

<*
 Present when the consumer selected the C3D_STB_IMAGE feature; the image API and its decoder compile regardless.
*>
const bool STB_IMAGE_ENABLED @feat(C3D_STB_IMAGE) = true;
