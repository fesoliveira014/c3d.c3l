module c3d::gui;

import c3d;
import c3d::asset;
import imgui;

<*
 Edit a Basic material color and advance its revision.
 @param [&inout] assets : "Live store; called during the current GUI frame."
 @return? c3d::INVALID_ID
*>
fn void? material_panel(AssetStore* assets, MaterialId material) {
    MaterialAsset* record = assets.materials.try_get(material)!;

    bool visible = imgui::begin("Material", null, {});
    defer imgui::end();
    if (!visible) return;

    if (imgui::color_edit3("Color", (float*)&record.data.basic.color, {})) {
        assets.mark_material_dirty(material);
    }
}
