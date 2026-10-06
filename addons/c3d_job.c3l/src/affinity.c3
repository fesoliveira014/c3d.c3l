module c3d::job;

import c3d;
import std::collections::bitset;

$assert env::LINUX || env::WIN32 : "c3d_job binds workers to processors on Linux and Windows only.";

const sz CPU_SET_BITS @private = 1024; // glibc's cpu_set_t; processors numbered from 1024 on are not represented
const sz GROUP_MASK_BITS @private = 64; // one Windows processor group fits one KAFFINITY word
const String CGROUP_UNLIMITED @private = "max";

<*
 Logical processors by index; Windows numbers processor groups consecutively.
*>
alias CpuSet = BitSet{CPU_SET_BITS};

<*
 Available processors split into the fastest core type and the rest.
*>
struct CoreTypes {
    CpuSet performance; // the fastest class; every available processor when types are uniform or unknown
    CpuSet efficiency;  // every other available processor
}

struct GroupMask @private {
    uint  group;
    ulong mask;
}

struct CgroupLimit @private {
    String cpu_max;    // cgroup v2 cpu.max; empty when absent
    String cfs_quota;  // cgroup v1 cpu.cfs_quota_us; empty when absent
    String cfs_period; // cgroup v1 cpu.cfs_period_us
}

<*
 Logical processors the calling thread may run on.
*>
fn CpuSet available_cpus() => native_thread_cpus();

<*
 Whole processors of the cgroup CPU quota, rounded up.
 @return? NOT_FOUND
*>
fn uint? cpu_quota() => native_cpu_quota();

<*
 Available processors split into the fastest core type and the rest.
*>
fn CoreTypes core_types() => native_core_types(available_cpus());

fn uint worker_count_for(sz available_count, uint quota_count) @private {
    sz usable = min(available_count, (sz)quota_count);
    return usable > 1 ? (uint)usable - 1 : 1;
}

fn CpuSet? bound_cpus(CpuSet requested, CpuSet available) @private {
    if (!requested.cardinality()) return requested;
    CpuSet bound = requested & available;
    if (!bound.cardinality()) return c3d::INVALID_ARGUMENT~;
    return bound;
}

<*
 @return? c3d::INVALID_ARGUMENT
*>
fn ulong? parse_count(String text) @private {
    ulong? count = text.trim().to_ulong();
    if (catch count) return c3d::INVALID_ARGUMENT~;
    return count;
}

fn uint? quota_cpus(ulong quota, ulong period) @private {
    if (!quota || !period) return NOT_FOUND~;
    return (uint)min((quota - 1) / period + 1, (ulong)uint::max);
}

fn uint? quota_from_cpu_max(String contents) @private {
    String text = contents.trim();
    sz? space = text.index_of_char(' ');
    if (catch space) return NOT_FOUND~;
    if (text[:space] == CGROUP_UNLIMITED) return NOT_FOUND~;
    return quota_cpus(parse_count(text[:space]) ?? 0, parse_count(text[space + 1..]) ?? 0);
}

fn uint? quota_from_cfs(String quota_contents, String period_contents) @private {
    long? quota = quota_contents.trim().to_long();
    if (catch quota) return NOT_FOUND~;
    if (quota <= 0) return NOT_FOUND~;
    return quota_cpus((ulong)quota, parse_count(period_contents) ?? 0);
}

fn uint? tightest_quota(CgroupLimit[] levels) @private {
    uint? tightest = NOT_FOUND~;
    foreach (level : levels) {
        uint? quota = level.cpu_max.len
            ? quota_from_cpu_max(level.cpu_max)
            : quota_from_cfs(level.cfs_quota, level.cfs_period);
        if (catch quota) continue;
        if (try current = tightest) {
            if (quota >= current) continue;
        }
        tightest = quota;
    }
    return tightest;
}

<*
 @param controller : "A cgroup v1 controller, or empty for the v2 hierarchy."
*>
fn String? cgroup_path(String proc_cgroup, String controller) @private {
    Splitter lines = proc_cgroup.tokenize("\n");
    while (try line = lines.next()) {
        sz? first_colon = line.index_of_char(':');
        if (catch first_colon) continue;
        sz? second_colon = line.index_of_char_from(':', first_colon + 1);
        if (catch second_colon) continue;
        String controllers = line[first_colon + 1 .. second_colon - 1];
        String path = line[second_colon + 1..].trim_right("/");
        if (!controller.len) {
            if (!controllers.len) return path;
            continue;
        }
        Splitter names = controllers.tokenize(",");
        while (try name = names.next()) {
            if (name == controller) return path;
        }
    }
    return NOT_FOUND~;
}

fn String? parent_cgroup(String path) @private {
    if (!path.len) return NOT_FOUND~;
    return path[:path.rindex_of_char('/') ?? 0];
}

<*
 @return? c3d::INVALID_ARGUMENT
*>
fn CpuSet? parse_cpu_list(String contents) @private {
    CpuSet cpus;
    Splitter ranges = contents.trim().tokenize(",");
    while (try range = ranges.next()) {
        sz? dash = range.index_of_char('-');
        ulong first = parse_count(range[:dash ?? (sz)range.len])!;
        ulong last = first;
        if (try dash) last = parse_count(range[dash + 1..])!;
        if (last < first) return c3d::INVALID_ARGUMENT~;
        for (ulong cpu = first; cpu <= last && cpu < CPU_SET_BITS; cpu++) cpus.set((sz)cpu);
    }
    if (!cpus.cardinality()) return c3d::INVALID_ARGUMENT~;
    return cpus;
}

<*
 @require ranks.len == CPU_SET_BITS
*>
fn CoreTypes core_types_from_ranks(uint[] ranks, CpuSet available) @private {
    uint fastest;
    foreach (cpu, rank : ranks) {
        if (available.get(cpu) && rank > fastest) fastest = rank;
    }
    CoreTypes types;
    foreach (cpu, rank : ranks) {
        if (!available.get(cpu)) continue;
        if (rank == fastest) {
            types.performance.set(cpu);
        } else {
            types.efficiency.set(cpu);
        }
    }
    return types;
}

<*
 @require cpus.cardinality() > 0
*>
fn GroupMask? group_mask_of(CpuSet cpus, uint[] group_sizes) @private {
    sz base;
    foreach (uint group, size : group_sizes) {
        GroupMask target = { .group = group };
        sz inside;
        for (sz bit = 0; bit < size && base + bit < CPU_SET_BITS; bit++) {
            if (!cpus.get(base + bit)) continue;
            target.mask |= 1ul << (ulong)bit;
            inside++;
        }
        if (inside == cpus.cardinality()) return target;
        if (inside) return c3d::UNSUPPORTED~;
        base += size;
    }
    return c3d::UNSUPPORTED~;
}

<*
 @require group_mask.group < group_sizes.len
*>
fn CpuSet cpus_of_group_mask(GroupMask group_mask, uint[] group_sizes) @private {
    sz base;
    foreach (size : group_sizes[:group_mask.group]) base += size;
    CpuSet cpus;
    for (sz bit = 0; bit < GROUP_MASK_BITS && base + bit < CPU_SET_BITS; bit++) {
        if (group_mask.mask & (1ul << (ulong)bit)) cpus.set(base + bit);
    }
    return cpus;
}
