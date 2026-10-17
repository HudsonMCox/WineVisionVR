#pragma once
#include <cstdint>
#include <vector>
// Compiled from immutable OpenXR binding paths; no string parsing during sampling.
struct WVRActionRolePlan {
  enum Source : uint8_t { Trigger, Grip, StickX, StickY, Button };
  struct Scalar { Source source; uint64_t button; };
  bool supported = false, trigger = false, grip = false, vector = false;
  uint64_t buttons = 0;
  std::vector<Scalar> scalars; // binding order preserves equal-magnitude tie behavior
};
