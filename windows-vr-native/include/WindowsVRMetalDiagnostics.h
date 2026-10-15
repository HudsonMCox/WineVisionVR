#ifndef WINDOWS_VR_METAL_DIAGNOSTICS_H
#define WINDOWS_VR_METAL_DIAGNOSTICS_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Correct known DXMT AIR/container version mismatches. Capture is optional.
void wvr_metal_shader_compatibility_install(int capture);
// Opt-in submission/completion timing; does not change GPU scheduling.
void wvr_metal_gpu_statistics_install(void);
int wvr_metal_copy_gpu_statistics(char *buffer, uint32_t capacity);
// Copies the first fatal compiler-service error; zero means no recorded error.
int wvr_metal_copy_compiler_failure(char *buffer, uint32_t capacity);
#ifdef __cplusplus
}
#endif
#endif
