module described_component;

import c3d;
import c3d::describe;
import std::math;

const float REJECTED_SPEED @local = 10;

<*
 Motion selected by the application after inspecting the component.
*>
enum MotionStyle : ushort {
    STILL,
    ORBIT,
    PULSE,
}

<*
 Described settings shared by inspection and portable consumer examples.
*>
struct DescribedComponent {
    bool enabled;
    float speed @tag("display", "Speed") @tag("range", { 0.0, 10.0 }) @tag("unit", "m/s");
    MotionStyle mode;
    Vec3 offset;
    Entity target;
    GeometryId geometry;
    float speed_squared @tag("transient", true);
}

<*
 Register the demonstration component for every description consumer.
 @return? c3d::describe::register_reflected_component!
*>
fn void? register_described_component() {
    describe::register_reflected_component(DescribedComponent, after: &rebuild_component)!;
}

fn void? rebuild_component(void* raw) @local {
    DescribedComponent* component = (DescribedComponent*)raw;
    if (component.speed == REJECTED_SPEED) return c3d::INVALID_ARGUMENT~;
    component.speed_squared = component.speed * component.speed;
}
