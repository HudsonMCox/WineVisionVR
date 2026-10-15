#ifndef WINDOWS_VR_THREAD_DUMP_H
#define WINDOWS_VR_THREAD_DUMP_H
#ifdef __cplusplus
extern "C" {
#endif
/// Appends the program counter, link register and frame-pointer chain of every thread in this process to
/// `path`, symbolicated with dladdr where the address belongs to a loaded image. For a stuck startup, where no
/// debugger or crash report exists. Threads are suspended only long enough to copy their registers and stack
/// links; symbolication and file output happen after they are resumed.
void wvr_dump_thread_stacks_v1(const char *path, const char *reason);
#ifdef __cplusplus
}
#endif
#endif
