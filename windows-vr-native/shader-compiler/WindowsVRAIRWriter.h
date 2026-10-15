// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// 0: unrelated library, 1: source-corrected library, -1: invalid generated AIR.
// On success the caller owns *output and releases it with free().
int wvr_air_reemit(const uint8_t *input, size_t length, uint8_t **output,
                  size_t *outputLength, char *error, size_t errorCapacity);
#ifdef __cplusplus
}
#endif
