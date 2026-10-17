#pragma once
#include <cmath>
#include <limits>
// OpenVR's rectilinear right-handed D3D projection maps depth into [0,1].
// OpenXR nearZ/farZ are distances corresponding to minDepth/maxDepth, and may
// be reversed or infinite. Preserve that convention instead of sorting them.
struct WVRDepthProjection {
  float nearZ, farZ;
  float left, right, up, down;
};
inline bool WVRDecodeDepthProjection(const float m[4][4], const float bounds[4],
                                     float minDepth, float maxDepth,
                                     WVRDepthProjection &out) {
  for (unsigned y = 0; y < 4; y++)
    for (unsigned x = 0; x < 4; x++)
      if (!std::isfinite(m[y][x]))
        return false;
  for (unsigned i = 0; i < 4; i++)
    if (!std::isfinite(bounds[i]))
      return false;
  if (bounds[0] < 0 || bounds[1] < 0 || bounds[2] > 1 || bounds[3] > 1 ||
      bounds[0] >= bounds[2] || bounds[1] >= bounds[3] ||
      !std::isfinite(minDepth) || !std::isfinite(maxDepth) || minDepth < 0 ||
      maxDepth > 1 || minDepth >= maxDepth || m[0][0] <= 0 || m[1][1] <= 0 ||
      std::fabs(m[3][2] + 1.f) > .0001f ||
      std::fabs(m[0][1]) + std::fabs(m[0][3]) + std::fabs(m[1][0]) +
              std::fabs(m[1][3]) + std::fabs(m[2][0]) + std::fabs(m[2][1]) +
              std::fabs(m[3][0]) + std::fabs(m[3][1]) + std::fabs(m[3][3]) >
          .0001f)
    return false;
  const float infinity = std::numeric_limits<float>::infinity();
  out.nearZ = m[2][2] == 0 ? infinity : m[2][3] / m[2][2];
  out.farZ = m[2][2] + 1.f == 0 ? infinity : m[2][3] / (m[2][2] + 1.f);
  if (std::isnan(out.nearZ) || std::isnan(out.farZ) || out.nearZ <= 0 ||
      out.farZ <= 0 || out.nearZ == out.farZ)
    return false;
  // Bounds select the eye's rectangle within a texture/atlas. They do not
  // narrow the eye projection: side-by-side eyes commonly submit half an atlas.
  out.left = std::atan((-1 + m[0][2]) / m[0][0]);
  out.right = std::atan((1 + m[0][2]) / m[0][0]);
  out.up = std::atan((1 + m[1][2]) / m[1][1]);
  out.down = std::atan((-1 + m[1][2]) / m[1][1]);
  return out.left < out.right && out.down < out.up;
}
