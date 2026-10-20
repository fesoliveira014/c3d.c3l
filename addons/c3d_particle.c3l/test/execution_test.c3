module c3d_particle_test;

import c3d;
import c3d::particle;
import c3d::scene;

fn Scene new_scene() @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    particle::register_particles(&scene)!!;
    return scene;
}

fn ParticleSystemDesc plain_desc(uint capacity = 16) @local {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = capacity;
    desc.lifetime = { .min = 5, .max = 5 };
    return desc;
}

fn uint root_children(Scene* scene) @local {
    uint count;
    for (Node* child = scene.root.first_child; child; child = child.next_sibling) count++;
    return count;
}

fn void test_gpu_execution_without_the_gpu_build_faults_unsupported() @test {
    Scene scene = new_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = plain_desc();
    desc.execution = ParticleExecution.GPU;
    uint before = root_children(&scene);
    assert(@catch(scene.add_particle_system(desc)) == c3d::UNSUPPORTED);
    assert(root_children(&scene) == before);
}
