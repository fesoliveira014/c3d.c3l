module c3d::render;

import c3d::material;
import c3d::shader;

$assert shader::ENVIRONMENT_FACE_POSITIVE_X == (uint)material::CubeFace.POSITIVE_X.ordinal;
$assert shader::ENVIRONMENT_FACE_NEGATIVE_X == (uint)material::CubeFace.NEGATIVE_X.ordinal;
$assert shader::ENVIRONMENT_FACE_POSITIVE_Y == (uint)material::CubeFace.POSITIVE_Y.ordinal;
$assert shader::ENVIRONMENT_FACE_NEGATIVE_Y == (uint)material::CubeFace.NEGATIVE_Y.ordinal;
$assert shader::ENVIRONMENT_FACE_POSITIVE_Z == (uint)material::CubeFace.POSITIVE_Z.ordinal;
$assert shader::ENVIRONMENT_FACE_NEGATIVE_Z == (uint)material::CubeFace.NEGATIVE_Z.ordinal;
$assert shader::ENVIRONMENT_FACE_COUNT == material::CUBE_FACE_COUNT;
