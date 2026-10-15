#ifndef WINDOWS_VR_THREAD_TRACE_H
#define WINDOWS_VR_THREAD_TRACE_H
#ifdef __cplusplus
extern "C" {
#endif
/// Rebinds the `pthread_create` import of every loaded image whose path contains `imageNameFragment` so each
/// thread that image starts is logged to `path`: the start routine, the stack it was given and what the kernel
/// maps there, the creation result, and when the thread first runs. A thread that has not run after a few
/// seconds is reported with its register state. For a runtime that is only available prebuilt: it shows where
/// startup stops without rebuilding it. Safe to call more than once; returns the number of imports rebound.
int wvr_trace_thread_creation_v1(const char *imageNameFragment, const char *path);
#ifdef __cplusplus
}
#endif
#endif
