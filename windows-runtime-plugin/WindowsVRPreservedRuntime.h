#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Additional exports of the preserved, source-patched Madeira runtime.
int wine_process_configure_launch(const char *executable, const char *directory,
                                 int argument_count, const char *const *arguments, int native_arm64);
bool fex_get_jit_pool_info(uint64_t *rx, uint64_t *rw, uint64_t *size);
#ifdef __cplusplus
}
#endif
