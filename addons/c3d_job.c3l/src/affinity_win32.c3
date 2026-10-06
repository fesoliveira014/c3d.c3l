module c3d::job @feat(WIN32);

import c3d;
import std::os::win32;

const usz MAX_PROCESSOR_GROUPS @private = CPU_SET_BITS / GROUP_MASK_BITS; // groups a dense index holds if each is full
const CInt RELATION_PROCESSOR_CORE @private = 0; // LOGICAL_PROCESSOR_RELATIONSHIP.RelationProcessorCore

struct GroupAffinity @private {
    Win32_ULONG_PTR mask;
    Win32_WORD      group;
    Win32_WORD[3]   reserved;
}

struct ProcessorRelationship @private {
    char             flags;
    char             efficiency_class; // higher is faster and less efficient; 0 on every core of a uniform processor
    char[20]         reserved;
    Win32_WORD       group_count;
    GroupAffinity[1] group_mask; // group_count entries follow in the record
}

struct LogicalProcessorInformation @private {
    CInt                  relationship;
    Win32_DWORD           size;
    ProcessorRelationship processor;
}

$assert GroupAffinity::size == 16;
$assert $reflect(ProcessorRelationship.group_count).offset == 22;
$assert $reflect(ProcessorRelationship.group_mask).offset == 24;
$assert $reflect(LogicalProcessorInformation.processor).offset == 8;

extern fn Win32_BOOL set_thread_group_affinity(
    Win32_HANDLE thread,
    GroupAffinity* affinity,
    GroupAffinity* previous,
) @cname("SetThreadGroupAffinity") @private;
extern fn Win32_BOOL get_thread_group_affinity(
    Win32_HANDLE thread,
    GroupAffinity* affinity,
) @cname("GetThreadGroupAffinity") @private;
extern fn Win32_DWORD get_active_processor_count(Win32_WORD group) @cname("GetActiveProcessorCount") @private;
extern fn Win32_WORD get_active_processor_group_count() @cname("GetActiveProcessorGroupCount") @private;
extern fn Win32_BOOL get_logical_processor_information_ex(
    CInt relationship,
    void* buffer,
    Win32_DWORD* length,
) @cname("GetLogicalProcessorInformationEx") @private;

fn usz processor_group_sizes(uint[] sizes) @private {
    usz groups = min((usz)get_active_processor_group_count(), (usz)sizes.len);
    for (usz group = 0; group < groups; group++) sizes[group] = get_active_processor_count((Win32_WORD)group);
    return groups;
}

fn CpuSet native_thread_cpus() @private {
    uint[MAX_PROCESSOR_GROUPS] sizes;
    usz groups = processor_group_sizes(&sizes);
    GroupAffinity affinity;
    if (!get_thread_group_affinity(win32::getCurrentThread(), &affinity)) {
        // An unreadable mask must not leave the available set empty; fall back to the first group, as Linux does.
        CpuSet first_group;
        for (sz index = 0; index < min((sz)sizes[0], CPU_SET_BITS); index++) first_group.set(index);
        return first_group;
    }
    if (affinity.group >= groups) return {};
    return cpus_of_group_mask({ .group = affinity.group, .mask = affinity.mask }, sizes[:groups]);
}

<*
 @return? c3d::UNSUPPORTED
*>
fn void? native_bind_thread(CpuSet cpus) @private {
    uint[MAX_PROCESSOR_GROUPS] sizes;
    usz groups = processor_group_sizes(&sizes);
    GroupMask target = group_mask_of(cpus, sizes[:groups])!;
    GroupAffinity affinity = {
        .mask  = (Win32_ULONG_PTR)target.mask,
        .group = (Win32_WORD)target.group,
    };
    if (!set_thread_group_affinity(win32::getCurrentThread(), &affinity, null)) return c3d::UNSUPPORTED~;
}

<*
 @return? NOT_FOUND
*>
fn uint? native_cpu_quota() @private => NOT_FOUND~;

fn CoreTypes native_core_types(CpuSet available) @private {
    uint[MAX_PROCESSOR_GROUPS] sizes;
    usz groups = processor_group_sizes(&sizes);
    uint[CPU_SET_BITS] ranks;
    Win32_DWORD length;
    get_logical_processor_information_ex(RELATION_PROCESSOR_CORE, null, &length);
    @pool() {
        char[] records = mem::temp_array(char, length);
        if (!get_logical_processor_information_ex(RELATION_PROCESSOR_CORE, records.ptr, &length)) length = 0;
        for (usz offset = 0; offset < length; ) {
            LogicalProcessorInformation* record = (LogicalProcessorInformation*)&records[offset];
            GroupAffinity* masks = &record.processor.group_mask[0];
            for (uint index = 0; index < record.processor.group_count; index++) {
                if (masks[index].group >= groups) continue;
                CpuSet core = cpus_of_group_mask(
                    { .group = masks[index].group, .mask = masks[index].mask },
                    sizes[:groups],
                );
                foreach (cpu, &rank : ranks) {
                    if (core.get(cpu)) *rank = record.processor.efficiency_class;
                }
            }
            offset += record.size;
        }
    };
    return core_types_from_ranks(&ranks, available);
}
