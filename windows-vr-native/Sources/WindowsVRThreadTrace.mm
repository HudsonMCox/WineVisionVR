#import <Foundation/Foundation.h>
#include "WindowsVRThreadTrace.h"

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/vm_region.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <pthread.h>
#include <unistd.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime>

namespace {

using CreateFn = int (*)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
CreateFn g_realCreate = nullptr;
char g_logPath[1024] = {};
std::atomic<uint32_t> g_sequence{0};
std::atomic<bool> g_installed{false};
constexpr uint32_t kMaxTracked = 256;
std::atomic<bool> g_entered[kMaxTracked];

void logf(const char *format, ...) {
    char line[900];
    struct timespec now{}; clock_gettime(CLOCK_REALTIME, &now);
    struct tm local{}; time_t seconds = now.tv_sec; localtime_r(&seconds, &local);
    int length = std::snprintf(line, sizeof(line), "%02d:%02d:%02d.%03d [thread-trace] ", local.tm_hour, local.tm_min,
                               local.tm_sec, static_cast<int>(now.tv_nsec / 1000000));
    va_list args; va_start(args, format);
    length += std::vsnprintf(line + length, sizeof(line) - length - 2, format, args);
    va_end(args);
    if (length > static_cast<int>(sizeof(line)) - 2) length = sizeof(line) - 2;
    line[length++] = '\n';
    const int fd = open(g_logPath, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;
    (void)write(fd, line, static_cast<size_t>(length));
    close(fd);
}

const char *symbolFor(const void *address, char *buffer, size_t size) {
    Dl_info info{};
    if (address && dladdr(address, &info) && info.dli_sname) {
        std::snprintf(buffer, size, "%s+0x%lx", info.dli_sname,
                      (unsigned long)((const char *)address - (const char *)info.dli_saddr));
    } else {
        std::snprintf(buffer, size, "%p", address);
    }
    return buffer;
}

/// What the kernel maps at `address`: protection, extent and whether the first word is readable.
void describeMapping(const char *label, uint64_t address) {
    vm_address_t base = static_cast<vm_address_t>(address);
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const kern_return_t kr = vm_region_64(mach_task_self(), &base, &size, VM_REGION_BASIC_INFO_64,
                                            reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    uint64_t word = 0; vm_size_t got = 0;
    const kern_return_t readKr = vm_read_overwrite(mach_task_self(), static_cast<vm_address_t>(address & ~7ull), 8,
                                                   reinterpret_cast<vm_address_t>(&word), &got);
    logf("  %s 0x%llx: region kr=%d base=0x%llx size=0x%llx prot=%d/%d inherit=%d shared=%d read kr=%d",
         label, (unsigned long long)address, kr, (unsigned long long)base, (unsigned long long)size,
         kr == KERN_SUCCESS ? info.protection : -1, kr == KERN_SUCCESS ? info.max_protection : -1,
         kr == KERN_SUCCESS ? info.inheritance : -1, kr == KERN_SUCCESS ? info.shared : -1, readKr);
}

struct StartContext {
    void *(*routine)(void *);
    void *argument;
    uint32_t sequence;
};

void *startThunk(void *raw) {
    StartContext context = *static_cast<StartContext *>(raw);
    delete static_cast<StartContext *>(raw);
    if (context.sequence < kMaxTracked) g_entered[context.sequence].store(true);
    char symbol[200];
    uint64_t threadID = 0; pthread_threadid_np(nullptr, &threadID);
    logf("#%u entered %s on mach thread %u tid=%llu", context.sequence, symbolFor((const void *)context.routine, symbol, sizeof(symbol)),
         (unsigned)mach_thread_self(), (unsigned long long)threadID);
    void *result = context.routine(context.argument);
    logf("#%u routine returned normally", context.sequence);
    return result;
}

void reportIfNotEntered(uint32_t sequence, pthread_t thread, uint64_t stackBase, uint64_t stackSize) {
    if (sequence >= kMaxTracked || g_entered[sequence].load()) return;
    const mach_port_t port = pthread_mach_thread_np(thread);
    arm_thread_state64_t state{};
    mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
    const kern_return_t stateKr = thread_get_state(port, ARM_THREAD_STATE64, reinterpret_cast<thread_state_t>(&state), &stateCount);
    thread_basic_info_data_t basic{};
    mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
    const kern_return_t infoKr = thread_info(port, THREAD_BASIC_INFO, reinterpret_cast<thread_info_t>(&basic), &basicCount);
    logf("#%u NOT RUNNING after 3 s: mach=%u state kr=%d pc=0x%llx sp=0x%llx lr=0x%llx | info kr=%d run_state=%d flags=0x%x suspend=%d cpu=%d",
         sequence, (unsigned)port, stateKr, (unsigned long long)arm_thread_state64_get_pc(state),
         (unsigned long long)arm_thread_state64_get_sp(state), (unsigned long long)arm_thread_state64_get_lr(state), infoKr,
         basic.run_state, basic.flags, basic.suspend_count, basic.cpu_usage);
    describeMapping("stack base", stackBase);
    if (stackSize) describeMapping("stack top ", stackBase + stackSize - 16);
}

int tracedCreate(pthread_t *thread, const pthread_attr_t *attr, void *(*routine)(void *), void *argument) {
    const uint32_t sequence = g_sequence.fetch_add(1);
    char symbol[200];
    void *stackAddress = nullptr; size_t stackSize = 0;
    if (attr) pthread_attr_getstack(attr, &stackAddress, &stackSize);
    logf("#%u create %s stack=%p size=0x%zx custom=%d", sequence, symbolFor((const void *)routine, symbol, sizeof(symbol)),
         stackAddress, stackSize, attr != nullptr && stackAddress != nullptr);
    if (stackAddress && stackSize) {
        describeMapping("stack base", (uint64_t)stackAddress);
        describeMapping("stack top ", (uint64_t)stackAddress + stackSize - 16);
    }
    auto *context = new StartContext{routine, argument, sequence};
    pthread_t local = nullptr;
    const int result = g_realCreate(thread ? thread : &local, attr, startThunk, context);
    logf("#%u create returned %d", sequence, result);
    if (result != 0) { delete context; return result; }
    const pthread_t created = thread ? *thread : local;
    const uint64_t base = (uint64_t)stackAddress, size = stackSize;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ reportIfNotEntered(sequence, created, base, size); });
    return result;
}


/// Who ends threads or the process. A thread that vanishes without a word is the usual shape of startup failing
/// inside a runtime that cannot be rebuilt here, so every way out is recorded with the caller's frames.
void logCaller(const char *what, long detail) {
    uint64_t threadID = 0; pthread_threadid_np(nullptr, &threadID);
    char a[200], b[200], c[200];
    void *frames[3] = {__builtin_return_address(0), nullptr, nullptr};
    uint64_t *fp = static_cast<uint64_t *>(__builtin_frame_address(0));
    for (int i = 1; i < 3 && fp && ((uintptr_t)fp & 7) == 0 && (uintptr_t)fp > 0x1000; i++) {
        fp = reinterpret_cast<uint64_t *>(*fp);
        if (!fp || ((uintptr_t)fp & 7) != 0 || (uintptr_t)fp < 0x1000) break;
        frames[i] = reinterpret_cast<void *>(fp[1]);
    }
    logf("%s(%ld) on tid=%llu from %s <- %s <- %s", what, detail, (unsigned long long)threadID,
         symbolFor(frames[0], a, sizeof(a)), symbolFor(frames[1], b, sizeof(b)), symbolFor(frames[2], c, sizeof(c)));
}
using VoidIntFn = void (*)(int);
using PthreadExitFn = void (*)(void *);
using KillFn = int (*)(pthread_t, int);
using KillPidFn = int (*)(pid_t, int);
using TerminateFn = kern_return_t (*)(thread_act_t);
VoidIntFn g_realExit = nullptr, g_real_Exit = nullptr;
void (*g_realAbort)(void) = nullptr;
PthreadExitFn g_realPthreadExit = nullptr;
KillFn g_realPthreadKill = nullptr;
KillPidFn g_realKill = nullptr;
TerminateFn g_realThreadTerminate = nullptr;
__attribute__((noreturn)) void tracedExit(int code) { logCaller("exit", code); g_realExit(code); __builtin_unreachable(); }
__attribute__((noreturn)) void traced_Exit(int code) { logCaller("_exit", code); g_real_Exit(code); __builtin_unreachable(); }
__attribute__((noreturn)) void tracedAbort(void) { logCaller("abort", 0); g_realAbort(); __builtin_unreachable(); }
__attribute__((noreturn)) void tracedPthreadExit(void *value) { logCaller("pthread_exit", 0); g_realPthreadExit(value); __builtin_unreachable(); }
int tracedPthreadKill(pthread_t thread, int signal) {
    if (signal != 0) logCaller("pthread_kill", signal);
    return g_realPthreadKill(thread, signal);
}
int tracedKill(pid_t pid, int signal) { if (signal != 0) logCaller("kill", signal); return g_realKill(pid, signal); }
kern_return_t tracedThreadTerminate(thread_act_t thread) { logCaller("thread_terminate", (long)thread); return g_realThreadTerminate(thread); }

struct Hook { const char *name; void *replacement; void **real; };
Hook g_hooks[] = {
    {"_pthread_create", reinterpret_cast<void *>(tracedCreate), reinterpret_cast<void **>(&g_realCreate)},
    {"_exit", reinterpret_cast<void *>(tracedExit), reinterpret_cast<void **>(&g_realExit)},
    {"__exit", reinterpret_cast<void *>(traced_Exit), reinterpret_cast<void **>(&g_real_Exit)},
    {"_abort", reinterpret_cast<void *>(tracedAbort), reinterpret_cast<void **>(&g_realAbort)},
    {"_pthread_exit", reinterpret_cast<void *>(tracedPthreadExit), reinterpret_cast<void **>(&g_realPthreadExit)},
    {"_pthread_kill", reinterpret_cast<void *>(tracedPthreadKill), reinterpret_cast<void **>(&g_realPthreadKill)},
    {"_kill", reinterpret_cast<void *>(tracedKill), reinterpret_cast<void **>(&g_realKill)},
    {"_thread_terminate", reinterpret_cast<void *>(tracedThreadTerminate), reinterpret_cast<void **>(&g_realThreadTerminate)},
};

int rebindImage(const struct mach_header_64 *header, intptr_t slide) {
    const struct symtab_command *symtab = nullptr;
    const struct dysymtab_command *dysymtab = nullptr;
    const struct segment_command_64 *linkedit = nullptr;
    const uint8_t *cursor = reinterpret_cast<const uint8_t *>(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const auto *command = reinterpret_cast<const struct load_command *>(cursor);
        if (command->cmd == LC_SYMTAB) symtab = reinterpret_cast<const struct symtab_command *>(command);
        else if (command->cmd == LC_DYSYMTAB) dysymtab = reinterpret_cast<const struct dysymtab_command *>(command);
        else if (command->cmd == LC_SEGMENT_64) {
            const auto *segment = reinterpret_cast<const struct segment_command_64 *>(command);
            if (std::strcmp(segment->segname, SEG_LINKEDIT) == 0) linkedit = segment;
        }
        cursor += command->cmdsize;
    }
    if (!symtab || !dysymtab || !linkedit) return 0;
    const uintptr_t linkeditBase = static_cast<uintptr_t>(slide) + linkedit->vmaddr - linkedit->fileoff;
    const auto *symbols = reinterpret_cast<const struct nlist_64 *>(linkeditBase + symtab->symoff);
    const char *strings = reinterpret_cast<const char *>(linkeditBase + symtab->stroff);
    const auto *indirect = reinterpret_cast<const uint32_t *>(linkeditBase + dysymtab->indirectsymoff);
    int rebound = 0;
    cursor = reinterpret_cast<const uint8_t *>(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const auto *command = reinterpret_cast<const struct load_command *>(cursor);
        cursor += command->cmdsize;
        if (command->cmd != LC_SEGMENT_64) continue;
        const auto *segment = reinterpret_cast<const struct segment_command_64 *>(command);
        if (std::strcmp(segment->segname, SEG_DATA) != 0 && std::strcmp(segment->segname, "__DATA_CONST") != 0) continue;
        const auto *section = reinterpret_cast<const struct section_64 *>(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++, section++) {
            const uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            void **slots = reinterpret_cast<void **>(static_cast<uintptr_t>(slide) + section->addr);
            const uint32_t firstIndirect = section->reserved1;
            for (uint64_t k = 0; k < section->size / sizeof(void *); k++) {
                const uint32_t symbolIndex = indirect[firstIndirect + k];
                if (symbolIndex == INDIRECT_SYMBOL_ABS || symbolIndex == INDIRECT_SYMBOL_LOCAL) continue;
                const char *name = strings + symbols[symbolIndex].n_un.n_strx;
                Hook *hook = nullptr;
                for (Hook &candidate : g_hooks) if (std::strcmp(name, candidate.name) == 0) { hook = &candidate; break; }
                if (!hook) continue;
                if (slots[k] == hook->replacement) continue;
                if (!*hook->real) *hook->real = slots[k];
                // The GOT may live in read-only data; make a private writable copy of just this page.
                const vm_address_t page = reinterpret_cast<vm_address_t>(&slots[k]) & ~static_cast<vm_address_t>(0x3fff);
                vm_protect(mach_task_self(), page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                slots[k] = hook->replacement;
                rebound++;
            }
        }
    }
    return rebound;
}

} // namespace

extern "C" int wvr_trace_thread_creation_v1(const char *imageNameFragment, const char *path) {
    if (!imageNameFragment || !path) return 0;
    bool expected = false;
    if (g_installed.compare_exchange_strong(expected, true)) std::snprintf(g_logPath, sizeof(g_logPath), "%s", path);
    int total = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !std::strstr(name, imageNameFragment)) continue;
        const auto *header = reinterpret_cast<const struct mach_header_64 *>(_dyld_get_image_header(i));
        if (!header || header->magic != MH_MAGIC_64) continue;
        total += rebindImage(header, _dyld_get_image_vmaddr_slide(i));
    }
    logf("hook installed on '%s': %d import(s) rebound (pthread_create, exit, abort, pthread_exit, kill, thread_terminate)", imageNameFragment, total);
    return total;
}
