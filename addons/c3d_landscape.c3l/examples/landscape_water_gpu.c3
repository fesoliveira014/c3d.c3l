module landscape_water_field;

import c3d;
import c3d::asset;
import c3d::landscape::water_gpu;
import c3d::render;
import c3d::scene;

const bool ENABLED = true;
const uint DISPATCHES_PER_BODY = water_gpu::DISPATCHES_PER_BODY;

fn void? update(Renderer* renderer, Scene* scene, AssetStore* assets) {
    return water_gpu::update(renderer, scene, assets);
}
