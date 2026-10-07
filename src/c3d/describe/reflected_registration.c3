module c3d::describe;

import c3d::describe::reflected @public;

<*
 Register a struct's reflected fields and optional reconstruction hook.
 Rejects recursive raw descendants even when handwritten callbacks omit them.
 @param after : "Optional reconstruction callback for this type."
 @return? DESCRIPTION_CONFLICT
*>
macro void? register_reflected($Type, FinishFn after = null) {
    return register_type($Type, &reflected::fields{$Type}, after);
}

<*
 Register reflected fields and bind their process-wide component slot.
 Rejects recursive raw descendants even when handwritten callbacks omit them.
 @param after : "Optional reconstruction callback for this type."
 @return? DESCRIPTION_CONFLICT, c3d::CAPACITY_EXCEEDED
*>
macro void? register_reflected_component($Type, FinishFn after = null) {
    return register_component($Type, &reflected::fields{$Type}, after);
}
