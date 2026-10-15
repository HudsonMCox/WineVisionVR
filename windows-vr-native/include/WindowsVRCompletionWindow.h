#pragma once
#include <cassert>
#include <cstdint>

constexpr uint64_t kWVRCompletionWindowCapacity = 6;

// Submission limits the unretired ticket window to six entries. Each bit
// denotes a completed ticket relative to the last contiguous completion.
// Call under the bridge lock. Duplicates cannot advance the fence twice.
inline bool wvrCompleteTicket(uint64_t ticket, uint64_t &last, uint64_t &mask) {
    if (ticket <= last) return false;
    const uint64_t distance = ticket - last;
    assert(distance <= kWVRCompletionWindowCapacity);
    mask |= uint64_t{1} << (distance - 1);
    const uint64_t previous = last;
    while (mask & 1) {
        ++last;
        mask >>= 1;
    }
    return last != previous;
}
