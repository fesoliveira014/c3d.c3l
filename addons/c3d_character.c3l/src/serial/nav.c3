module c3d::character @feat(C3D_CHARACTER_SERIAL & C3D_CHARACTER_NAV);

import c3d;
import c3d::describe;
import c3d::nav @public;
import c3d::scene;
import c3d::serial;

struct NavDrivenAuthoring @private {
    char storage @tag("transient", true); // C3 requires storage for an otherwise empty marker.
}

fn void? register_nav_driven_codec() @private {
    nav::register_serial_codecs()!;
    describe::register_reflected(NavDrivenAuthoring)!;
    serial::register_described_type(
        $Type: NavDrivenAuthoring,
        version: 1,
        layout: 0xbd291be3131c829e,
        defaults: &defaults_nav_driven,
    )!;
    serial::register_described_owner(NavDriven, NavDrivenAuthoring, {
        .name = "nav_driven",
        .phase = OWNER,
        .project = &project_nav_driven,
        .validate = &validate_nav_driven,
        .attach = &attach_nav_driven,
    })!;
}

fn void defaults_nav_driven(void* value) @private => *(NavDrivenAuthoring*)value = {};

fn void? project_nav_driven(void* component, void* value, serial::WriteContext* context) @private {
    *(NavDrivenAuthoring*)value = {};
}

fn void? validate_nav_driven(void* value, serial::ReadContext* context) @private {
    if (!context.has_component(Character)) return c3d::INVALID_ARGUMENT~;
    if (!context.has_component(NavAgent)) return NO_NAV_AGENT~;
}

fn void? attach_nav_driven(void* value, serial::ReadContext* context) @private {
    context.scene.add_nav_driven(context.node)!;
}
