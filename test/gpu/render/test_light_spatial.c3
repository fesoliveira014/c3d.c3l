module c3d::render::acceptance;

import c3d;
import c3d::light;
import c3d::render;
import c3d::scene;
import std::math::vector;

fn void test_light_spatial_probe_scenes_keep_their_own_finite_lights() @test {
    @pool() {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        ProbeRoom first = create_probe_room(&fixture, lamp: true)!!;
        defer scene::destroy_scene(&first.scene);
        ProbeRoom second = create_probe_room(&fixture, lamp: true)!!;
        defer scene::destroy_scene(&second.scene);
        first.scene.get(first.lamp, Light).color = { 1, 0, 0 };
        second.scene.get(second.lamp, Light).color = { 0, 1, 0 };
        first.scene.get(first.volume, ProbeVolume).update.hysteresis = 0;
        second.scene.get(second.volume, ProbeVolume).update.hysteresis = 0;
        ProbeView first_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
        defer destroy_probe_view(&fixture, &first_view);
        ProbeView second_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
        defer destroy_probe_view(&fixture, &second_view);
        for (uint frame = 0; frame < 8; frame++) {
            fixture.renderer.begin_frame()!!;
            fixture.renderer.render_view(&first.scene, first.camera, first_view.view)!!;
            fixture.renderer.finish_view(first_view.view)!!;
            fixture.renderer.render_view(&second.scene, second.camera, second_view.view)!!;
            fixture.renderer.finish_view(second_view.view)!!;
            fixture.renderer.end_frame()!!;
            assert(fixture.renderer.stats.probe_updates == 2);
        }
        Vec3 first_color = interior_channels(&fixture, &first);
        Vec3 second_color = interior_channels(&fixture, &second);
        assert(first_color.x > first_color.y + 0.02f);
        assert(second_color.y > second_color.x + 0.02f);
        check_validation(&fixture.renderer);
    };
}
