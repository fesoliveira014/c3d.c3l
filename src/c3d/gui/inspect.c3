module c3d::gui::inspect <Type>;

import c3d::gui;

<*
 Draw one widget per supported member and report whether any changed.
 @param [&inout] component : "Points at a Type."
*>
fn bool inspect(void* component) {
    bool changed;
    $foreach $member : Type::members:
        changed = gui::@field_widget($member, component) || changed;
    $endforeach
    return changed;
}
