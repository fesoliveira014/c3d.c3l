module c3d::job @feat(LINUX);

import c3d;
import std::io;
import std::io::file;
import std::thread::cpu;

const CInt CALLING_THREAD @private = 0; // pid 0 names the calling thread in sched_*affinity
const usz SYSTEM_FILE_BYTES @private = 4096; // /proc and /sys values; a file that fills it reads as malformed
const usz CGROUP_MAX_DEPTH @private = 32; // levels read per hierarchy; deeper ancestors are not read
const String PROC_SELF_CGROUP @private = "/proc/self/cgroup";
const String CGROUP_V2_ROOT @private = "/sys/fs/cgroup";
const String CGROUP_V1_CPU_ROOT @private = "/sys/fs/cgroup/cpu";
const String CGROUP_V1_CPU_CONTROLLER @private = "cpu";
const String PERFORMANCE_CORE_CPUS @private = "/sys/devices/cpu_core/cpus";
const String CPU_CAPACITY_FORMAT @private = "/sys/devices/system/cpu/cpu%d/cpu_capacity";

$assert CpuSet::size == 128 && !env::BIG_ENDIAN : "CpuSet is passed byte for byte as glibc's cpu_set_t.";

extern fn CInt sched_getaffinity(CInt pid, usz set_bytes, void* set) @cname("sched_getaffinity") @private;
extern fn CInt sched_setaffinity(CInt pid, usz set_bytes, void* set) @cname("sched_setaffinity") @private;

fn CpuSet native_thread_cpus() @private {
    CpuSet cpus;
    if (!sched_getaffinity(CALLING_THREAD, CpuSet::size, &cpus.data)) return cpus;
    // A kernel mask wider than CpuSet refuses the call; count the configured processors instead.
    sz configured = min((sz)cpu::native_cpu(), CPU_SET_BITS);
    for (sz index = 0; index < configured; index++) cpus.set(index);
    return cpus;
}

<*
 @return? c3d::UNSUPPORTED
*>
fn void? native_bind_thread(CpuSet cpus) @private {
    if (sched_setaffinity(CALLING_THREAD, CpuSet::size, &cpus.data)) return c3d::UNSUPPORTED~;
}

fn uint? native_cpu_quota() @private {
    uint? quota;
    @pool() {
        quota = read_cgroup_quota();
    };
    return quota;
}

fn CoreTypes native_core_types(CpuSet available) @private {
    uint[CPU_SET_BITS] ranks;
    @pool() {
        if (try performance = parse_cpu_list(read_system_file(PERFORMANCE_CORE_CPUS) ?? "")) {
            foreach (cpu, &rank : ranks) {
                if (performance.get(cpu)) *rank = 1;
            }
        } else {
            foreach (cpu, &rank : ranks) {
                if (!available.get(cpu)) continue;
                String capacity = read_system_file(string::tformat(CPU_CAPACITY_FORMAT, cpu)) ?? "";
                *rank = (uint)min(parse_count(capacity) ?? 0, (ulong)uint::max);
            }
        }
    };
    return core_types_from_ranks(&ranks, available);
}

<*
 Read a small system file into tmem; callers open the pool.
 @return? NOT_FOUND
*>
fn String? read_system_file(String path) @private {
    File? opened = file::open(path, "rb");
    if (catch opened) return NOT_FOUND~;
    defer (void)opened.close();
    char[] buffer = mem::temp_array(char, SYSTEM_FILE_BYTES);
    char[]? contents = io::read_buffer_to_end(&opened, buffer);
    if (catch contents) return NOT_FOUND~;
    if (contents.len == buffer.len) return NOT_FOUND~;
    return (String)contents;
}

fn usz read_cgroup_levels(
    CgroupLimit[] levels,
    usz depth,
    String root,
    String path,
    bool unified,
) @private {
    String level = path;
    while (depth < levels.len) {
        if (unified) {
            levels[depth].cpu_max = read_system_file(string::tformat("%s%s/cpu.max", root, level)) ?? "";
        } else {
            levels[depth].cfs_quota = read_system_file(string::tformat("%s%s/cpu.cfs_quota_us", root, level)) ?? "";
            levels[depth].cfs_period = read_system_file(string::tformat("%s%s/cpu.cfs_period_us", root, level)) ?? "";
        }
        depth++;
        String? parent = parent_cgroup(level);
        if (catch parent) break;
        level = parent;
    }
    return depth;
}

<*
 @return? NOT_FOUND
*>
fn uint? read_cgroup_quota() @private {
    String proc_cgroup = read_system_file(PROC_SELF_CGROUP)!;
    CgroupLimit[2 * CGROUP_MAX_DEPTH] levels;
    usz depth;
    if (try path = cgroup_path(proc_cgroup, "")) {
        depth = read_cgroup_levels(
            levels:  levels[:CGROUP_MAX_DEPTH],
            depth:   depth,
            root:    CGROUP_V2_ROOT,
            path:    path,
            unified: true,
        );
    }
    if (try path = cgroup_path(proc_cgroup, CGROUP_V1_CPU_CONTROLLER)) {
        depth = read_cgroup_levels(
            levels:  &levels,
            depth:   depth,
            root:    CGROUP_V1_CPU_ROOT,
            path:    path,
            unified: false,
        );
    }
    return tightest_quota(levels[:depth]);
}
