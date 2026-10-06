module c3d_job_affinity_test;

import c3d;
import c3d::job @public;

const uint BOUND_WORKERS @local = 2; // shared workers; one background-only worker joins them
const uint HYBRID_PERFORMANCE_CPUS @local = 16; // the i9-14900K: eight P-cores with two threads each first
const uint HYBRID_CPUS @local = 32;
const uint[2] TWO_FULL_GROUPS @local = { 64, 64 };
const uint[2] UNEVEN_GROUPS @local = { 20, 12 };

fn uint first_available_cpu() @local {
    CpuSet available = job::available_cpus();
    for (uint cpu = 0; cpu < job::CPU_SET_BITS; cpu++) {
        if (available.get(cpu)) return cpu;
    }
    unreachable("the calling thread runs on no processor");
}

fn uint? first_unavailable_cpu() @local {
    CpuSet available = job::available_cpus();
    for (uint cpu = 0; cpu < job::CPU_SET_BITS; cpu++) {
        if (!available.get(cpu)) return cpu;
    }
    return NOT_FOUND~;
}

fn CpuSet cpu_range(uint first, uint end) @local {
    CpuSet cpus;
    for (uint cpu = first; cpu < end; cpu++) cpus.set(cpu);
    return cpus;
}

fn JobPoolDesc bound_desc(CpuSet worker_cpus, CpuSet background_cpus) @local {
    JobPoolDesc desc = job::default_job_pool_desc();
    desc.worker_count = BOUND_WORKERS;
    desc.background_workers = 1;
    desc.background_only_workers = 1;
    desc.worker_cpus = worker_cpus;
    desc.background_cpus = background_cpus;
    return desc;
}

macro void @assert_faults(#expression, expected) @local {
    bool faulted;
    if (catch excuse = #expression) {
        assert(excuse == expected);
        faulted = true;
    }
    assert(faulted, "Expression did not fault.");
}

macro void @assert_no_quota(#quota) @local {
    @assert_faults(#quota, NOT_FOUND);
}

fn void test_workers_report_the_requested_cpu_set() @test {
    CpuSet requested;
    requested.set(first_available_cpu());
    JobPool pool = job::create_job_pool(mem, bound_desc(requested, requested))!!;
    defer job::destroy_job_pool(&pool);
    for (uint worker = 0; worker < BOUND_WORKERS + 1; worker++) {
        assert(pool.worker_cpus(worker).data == requested.data);
    }
}

fn void test_request_is_narrowed_to_the_available_cpus() @test {
    uint? outside = first_unavailable_cpu();
    if (catch outside) return;
    CpuSet expected;
    expected.set(first_available_cpu());
    CpuSet requested = expected;
    requested.set(outside);
    JobPool pool = job::create_job_pool(mem, bound_desc(requested, {}))!!;
    defer job::destroy_job_pool(&pool);
    for (uint worker = 0; worker < BOUND_WORKERS; worker++) {
        assert(pool.worker_cpus(worker).data == expected.data);
    }
}

fn void test_request_outside_the_available_cpus_is_invalid() @test {
    uint? outside = first_unavailable_cpu();
    if (catch outside) return;
    CpuSet requested;
    requested.set(outside);
    JobPoolDesc[2] descs = { bound_desc(requested, {}), bound_desc({}, requested) };
    foreach (desc : descs) {
        @assert_faults(job::create_job_pool(mem, desc), c3d::INVALID_ARGUMENT);
    }
}

fn void test_default_worker_count_follows_the_cpus_and_the_quota() @test {
    assert(job::worker_count_for(32, uint::max) == 31);
    assert(job::worker_count_for(4, uint::max) == 3);
    assert(job::worker_count_for(32, 3) == 2);
    assert(job::worker_count_for(1, uint::max) == 1);
    assert(job::worker_count_for(32, 1) == 1);
}

fn void test_cpu_quota_rounds_up_and_ignores_unlimited_or_malformed_files() @test {
    assert(job::quota_from_cpu_max("250000 100000\n")!! == 3);
    assert(job::quota_from_cpu_max("100000 100000")!! == 1);
    assert(job::quota_from_cfs("250000\n", "100000\n")!! == 3);
    @assert_no_quota(job::quota_from_cpu_max("max 100000\n"));
    @assert_no_quota(job::quota_from_cpu_max("0 100000\n"));
    @assert_no_quota(job::quota_from_cpu_max("250000\n"));
    @assert_no_quota(job::quota_from_cpu_max("many 100000\n"));
    @assert_no_quota(job::quota_from_cpu_max(""));
    @assert_no_quota(job::quota_from_cfs("-1\n", "100000\n"));
    @assert_no_quota(job::quota_from_cfs("250000\n", "\n"));
}

fn void test_the_tightest_ancestor_quota_wins() @test {
    CgroupLimit[3] nested = {
        { .cpu_max = "400000 100000\n" },
        { .cpu_max = "150000 100000\n" },
        { .cpu_max = "max 100000\n" },
    };
    assert(job::tightest_quota(&nested)!! == 2);
    CgroupLimit[2] hierarchies = {
        { .cpu_max = "max 100000\n" },
        { .cfs_quota = "50000\n", .cfs_period = "100000\n" },
    };
    assert(job::tightest_quota(&hierarchies)!! == 1);
    CgroupLimit[2] unlimited = {
        { .cpu_max = "max 100000\n" },
        { .cfs_quota = "-1\n", .cfs_period = "100000\n" },
    };
    @assert_no_quota(job::tightest_quota(&unlimited));
}

fn void test_cgroup_paths_walk_up_from_proc_self_cgroup() @test {
    assert(job::cgroup_path("0::/user.slice/app.scope\n", "")!! == "/user.slice/app.scope");
    String hybrid = "5:cpuacct:/elsewhere\n12:cpu,cpuacct:/docker/abc\n4:memory:/other\n0::/\n";
    assert(job::cgroup_path(hybrid, "cpu")!! == "/docker/abc");
    assert(job::cgroup_path(hybrid, "")!! == "");
    @assert_faults(job::cgroup_path("4:memory:/other\n", "cpu"), NOT_FOUND);
    assert(job::parent_cgroup("/docker/abc")!! == "/docker");
    assert(job::parent_cgroup("/docker")!! == "");
    @assert_faults(job::parent_cgroup(""), NOT_FOUND);
}

fn void test_cpu_lists_parse_ranges_and_single_processors() @test {
    CpuSet parsed = job::parse_cpu_list("0-3,8,10-11\n")!!;
    CpuSet expected = cpu_range(0, 4) | cpu_range(8, 9) | cpu_range(10, 12);
    assert(parsed.data == expected.data);
    String[4] malformed = { "", "3-1", "a", "2-x" };
    foreach (contents : malformed) {
        @assert_faults(job::parse_cpu_list(contents), c3d::INVALID_ARGUMENT);
    }
}

fn void test_core_types_split_off_the_fastest_rank() @test {
    uint[job::CPU_SET_BITS] ranks;
    for (uint cpu = 0; cpu < HYBRID_PERFORMANCE_CPUS; cpu++) ranks[cpu] = 1;
    CoreTypes hybrid = job::core_types_from_ranks(&ranks, cpu_range(0, HYBRID_CPUS));
    assert(hybrid.performance.data == cpu_range(0, HYBRID_PERFORMANCE_CPUS).data);
    assert(hybrid.efficiency.data == cpu_range(HYBRID_PERFORMANCE_CPUS, HYBRID_CPUS).data);

    CpuSet mixed = cpu_range(2, 3) | cpu_range(20, 21);
    CoreTypes narrowed = job::core_types_from_ranks(&ranks, mixed);
    assert(narrowed.performance.data == cpu_range(2, 3).data);
    assert(narrowed.efficiency.data == cpu_range(20, 21).data);

    CoreTypes efficient_only = job::core_types_from_ranks(&ranks, cpu_range(20, 22));
    assert(efficient_only.performance.data == cpu_range(20, 22).data);
    assert(!efficient_only.efficiency.cardinality());

    uint[job::CPU_SET_BITS] uniform;
    CoreTypes unknown = job::core_types_from_ranks(&uniform, cpu_range(0, HYBRID_CPUS));
    assert(unknown.performance.data == cpu_range(0, HYBRID_CPUS).data);
    assert(!unknown.efficiency.cardinality());
}

fn void test_group_masks_stay_within_one_group() @test {
    GroupMask low = job::group_mask_of(cpu_range(0, 2), &TWO_FULL_GROUPS)!!;
    assert(low.group == 0 && low.mask == 0b11);
    GroupMask high = job::group_mask_of(cpu_range(64, 66), &TWO_FULL_GROUPS)!!;
    assert(high.group == 1 && high.mask == 0b11);
    GroupMask full = job::group_mask_of(cpu_range(0, 64), &TWO_FULL_GROUPS)!!;
    assert(full.group == 0 && full.mask == ulong::max);
    CpuSet[2] refused = { cpu_range(63, 65), cpu_range(128, 129) };
    foreach (cpus : refused) {
        @assert_faults(job::group_mask_of(cpus, &TWO_FULL_GROUPS), c3d::UNSUPPORTED);
    }

    GroupMask second = job::group_mask_of(cpu_range(20, 21), &UNEVEN_GROUPS)!!;
    assert(second.group == 1 && second.mask == 0b1);
    CpuSet dense = job::cpus_of_group_mask({ .group = 1, .mask = 0b101 }, &UNEVEN_GROUPS);
    assert(dense.data == (cpu_range(20, 21) | cpu_range(22, 23)).data);
}
