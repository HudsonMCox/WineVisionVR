#import <Foundation/Foundation.h>
#include "WindowsVRThreadDump.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

namespace {

constexpr int kMaxFrames = 24;
constexpr mach_msg_type_number_t kMaxThreads = 256;

struct ThreadSample {
    uint64_t index = 0;
    char name[64] = {};
    uint64_t pc = 0, lr = 0, sp = 0, fp = 0, x16 = 0, x0 = 0;
    int runState = 0, suspendCount = 0, flags = 0;
    char pthreadName[64] = {};
    int depth = 0;
    int stateKr = 0, cpuUsage = 0, sleepTime = 0;
    uint64_t threadId = 0;
    char exceptionPorts[160] = {};
    uint64_t frames[kMaxFrames] = {};
};

std::string describe(uint64_t address) {
    char buffer[320];
    Dl_info info{};
    if (address != 0 && dladdr(reinterpret_cast<const void *>(address), &info) && info.dli_fname) {
        const char *base = std::strrchr(info.dli_fname, '/');
        base = base ? base + 1 : info.dli_fname;
        const uint64_t imageOffset = address - reinterpret_cast<uint64_t>(info.dli_fbase);
        if (info.dli_sname) {
            const uint64_t symbolOffset = address - reinterpret_cast<uint64_t>(info.dli_saddr);
            std::snprintf(buffer, sizeof(buffer), "0x%llx %s+0x%llx %s+0x%llx", (unsigned long long)address, base,
                          (unsigned long long)imageOffset, info.dli_sname, (unsigned long long)symbolOffset);
        } else {
            std::snprintf(buffer, sizeof(buffer), "0x%llx %s+0x%llx", (unsigned long long)address, base,
                          (unsigned long long)imageOffset);
        }
    } else {
        std::snprintf(buffer, sizeof(buffer), "0x%llx", (unsigned long long)address);
    }
    return buffer;
}

bool readWord(uint64_t address, uint64_t *out) {
    if (address < 0x1000 || (address & 7) != 0) return false;
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), static_cast<vm_address_t>(address), sizeof(uint64_t),
                             reinterpret_cast<vm_address_t>(out), &got) == KERN_SUCCESS && got == sizeof(uint64_t);
}

} // namespace

extern "C" void wvr_dump_thread_stacks_v1(const char *path, const char *reason) {
    if (!path) return;
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return;
    if (count > kMaxThreads) count = kMaxThreads;
    const mach_port_t self = mach_thread_self();

    // Which handlers the task itself routes exceptions to. A thread stopped in exception delivery reports an
    // all-zero register state, and with no handler listening it would wait forever.
    char taskPorts[300] = {};
    {
        exception_mask_t masks[EXC_TYPES_COUNT]; mach_msg_type_number_t portCount = EXC_TYPES_COUNT;
        mach_port_t ports[EXC_TYPES_COUNT]; exception_behavior_t behaviors[EXC_TYPES_COUNT];
        thread_state_flavor_t flavors[EXC_TYPES_COUNT];
        const kern_return_t portKr = task_get_exception_ports(mach_task_self(), EXC_MASK_ALL, masks, &portCount, ports, behaviors, flavors);
        int len = std::snprintf(taskPorts, sizeof(taskPorts), "kr=%d n=%u", portKr, portKr == KERN_SUCCESS ? portCount : 0);
        for (mach_msg_type_number_t k = 0; portKr == KERN_SUCCESS && k < portCount && len < (int)sizeof(taskPorts) - 40; k++) {
            len += std::snprintf(taskPorts + len, sizeof(taskPorts) - len, " [m=0x%x p=%u b=0x%x]", masks[k], (unsigned)ports[k], behaviors[k]);
            if (MACH_PORT_VALID(ports[k])) mach_port_deallocate(mach_task_self(), ports[k]);
        }
    }

    // Phase 1: copy registers and the frame-pointer chain while the thread is stopped. Nothing here allocates,
    // takes a lock or calls into dyld, so a stopped thread holding one cannot block this.
    static ThreadSample samples[kMaxThreads];
    mach_msg_type_number_t sampled = 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        const thread_act_t thread = threads[i];
        if (thread == self) continue;
        if (thread_suspend(thread) != KERN_SUCCESS) continue;
        arm_thread_state64_t state{};
        mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
        const kern_return_t stateKr = thread_get_state(thread, ARM_THREAD_STATE64, reinterpret_cast<thread_state_t>(&state), &stateCount);
        // A thread whose state cannot be read is still reported, with the kernel's answer: that is the case a
        // stalled startup needs to distinguish (never started, exiting, or stopped in an exception).
        ThreadSample &sample = samples[sampled++];
        sample = ThreadSample{};
        sample.index = i;
        sample.stateKr = stateKr;
        uint64_t fp = 0;
        if (stateKr == KERN_SUCCESS) {
            sample.pc = arm_thread_state64_get_pc(state);
            sample.lr = arm_thread_state64_get_lr(state);
            sample.sp = arm_thread_state64_get_sp(state);
            fp = arm_thread_state64_get_fp(state);
            sample.fp = fp;
            sample.x0 = state.__x[0];
            sample.x16 = state.__x[16];
        }
        thread_basic_info_data_t basic{};
        mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
        if (thread_info(thread, THREAD_BASIC_INFO, reinterpret_cast<thread_info_t>(&basic), &basicCount) == KERN_SUCCESS) {
            sample.runState = basic.run_state;
            sample.suspendCount = basic.suspend_count - 1; // minus the suspend taken just above
            sample.flags = basic.flags;
            sample.cpuUsage = basic.cpu_usage;
            sample.sleepTime = basic.sleep_time;
        }
        thread_identifier_info_data_t ident{};
        mach_msg_type_number_t identCount = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(thread, THREAD_IDENTIFIER_INFO, reinterpret_cast<thread_info_t>(&ident), &identCount) == KERN_SUCCESS) {
            sample.threadId = ident.thread_id;
        }
        thread_extended_info_data_t extended{};
        mach_msg_type_number_t extendedCount = THREAD_EXTENDED_INFO_COUNT;
        if (thread_info(thread, THREAD_EXTENDED_INFO, reinterpret_cast<thread_info_t>(&extended), &extendedCount) == KERN_SUCCESS) {
            std::snprintf(sample.pthreadName, sizeof(sample.pthreadName), "%s", extended.pth_name);
        }
        {
            exception_mask_t masks[EXC_TYPES_COUNT];
            mach_msg_type_number_t portCount = EXC_TYPES_COUNT;
            mach_port_t ports[EXC_TYPES_COUNT];
            exception_behavior_t behaviors[EXC_TYPES_COUNT];
            thread_state_flavor_t flavors[EXC_TYPES_COUNT];
            const kern_return_t portKr = thread_get_exception_ports(thread, EXC_MASK_ALL, masks, &portCount, ports, behaviors, flavors);
            int len = std::snprintf(sample.exceptionPorts, sizeof(sample.exceptionPorts), "kr=%d n=%u", portKr, portKr == KERN_SUCCESS ? portCount : 0);
            if (portKr == KERN_SUCCESS) {
                for (mach_msg_type_number_t k = 0; k < portCount && len > 0 && len < (int)sizeof(sample.exceptionPorts) - 28; k++) {
                    len += std::snprintf(sample.exceptionPorts + len, sizeof(sample.exceptionPorts) - len, " [m=0x%x p=%u]",
                                         masks[k], (unsigned)ports[k]);
                    if (MACH_PORT_VALID(ports[k])) mach_port_deallocate(mach_task_self(), ports[k]);
                }
            }
        }
        for (int depth = 0; depth < kMaxFrames && fp; depth++) {
            uint64_t next = 0, returnAddress = 0;
            if (!readWord(fp, &next) || !readWord(fp + 8, &returnAddress) || returnAddress == 0) break;
            sample.frames[sample.depth++] = returnAddress;
            if (next <= fp) break;
            fp = next;
        }
        thread_resume(thread);
    }

    // Phase 2: everything that may allocate or take locks, with every thread running again.
    FILE *out = std::fopen(path, "a");
    if (out) {
        time_t now = time(nullptr);
        struct tm local{}; localtime_r(&now, &local);
        std::fprintf(out, "%02d:%02d:%02d [threads] %s: %u threads, %u sampled\n", local.tm_hour, local.tm_min,
                     local.tm_sec, reason ? reason : "", count, sampled);
        std::fprintf(out, "[threads] task exception ports: %s\n", taskPorts);
        for (mach_msg_type_number_t i = 0; i < sampled; i++) {
            const ThreadSample &sample = samples[i];
            std::fprintf(out, "[threads]  #%llu name='%s' state=%d suspend=%d flags=0x%x sp=0x%llx fp=0x%llx x0=0x%llx x16=0x%llx\n",
                         (unsigned long long)sample.index, sample.pthreadName, sample.runState, sample.suspendCount,
                         sample.flags, (unsigned long long)sample.sp, (unsigned long long)sample.fp,
                         (unsigned long long)sample.x0, (unsigned long long)sample.x16);
            std::fprintf(out, "[threads]       tid=%llu state_kr=%d cpu=%d sleep=%ds exc: %s\n", (unsigned long long)sample.threadId,
                         sample.stateKr, sample.cpuUsage, sample.sleepTime, sample.exceptionPorts);
            std::fprintf(out, "[threads]       pc=%s\n", describe(sample.pc).c_str());
            std::fprintf(out, "[threads]       lr=%s\n", describe(sample.lr).c_str());
            for (int depth = 0; depth < sample.depth; depth++) {
                std::fprintf(out, "[threads]       %2d %s\n", depth, describe(sample.frames[depth]).c_str());
            }
        }
        std::fclose(out);
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) mach_port_deallocate(mach_task_self(), threads[i]);
    mach_port_deallocate(mach_task_self(), self);
    vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads), count * sizeof(thread_act_t));
}
