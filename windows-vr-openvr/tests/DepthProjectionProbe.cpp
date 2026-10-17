#include "../include/WindowsVRDepthProjection.h"
#include <cassert>
#include <cstdio>
int main() {
  float p[4][4]{};
  p[0][0] = p[1][1] = 1;
  p[3][2] = -1;
  p[2][2] = -100.f / 99.9f;
  p[2][3] = -10.f / 99.9f;
  float crop[] = {0, 0, 1, 1};
  WVRDepthProjection d{};
  assert(WVRDecodeDepthProjection(p, crop, 0, 1, d));
  assert(std::fabs(d.nearZ - .1f) < 1e-6 && std::fabs(d.farZ - 100) < .01);
  p[2][2] = .1f / 99.9f;
  p[2][3] = 10.f / 99.9f;
  assert(WVRDecodeDepthProjection(p, crop, 0, 1, d) && d.nearZ > d.farZ);
  p[2][2] = -1;
  p[2][3] = -.1;
  assert(WVRDecodeDepthProjection(p, crop, 0, 1, d) && std::isinf(d.farZ));
  p[2][2] = 0;
  p[2][3] = .1;
  assert(WVRDecodeDepthProjection(p, crop, 0, 1, d) && std::isinf(d.nearZ));
  crop[0] = .25;
  crop[2] = .75;
  p[0][2] = .1;
  assert(WVRDecodeDepthProjection(p, crop, 0, 1, d));
  assert(std::fabs(std::tan(d.left) + .9) < 1e-6 &&
         std::fabs(std::tan(d.right) - 1.1) < 1e-6);
  p[2][3] = -.1;
  assert(!WVRDecodeDepthProjection(p, crop, 0, 1, d));
  p[2][3] = .1;
  p[0][1] = 1;
  assert(!WVRDecodeDepthProjection(p, crop, 0, 1, d));
  p[0][1] = 0;
  crop[0] = NAN;
  assert(!WVRDecodeDepthProjection(p, crop, 0, 1, d));
  crop[0] = .25;
  assert(!WVRDecodeDepthProjection(p, crop, 1, 0, d));
  puts("PASS: production OpenVR projection decoding: finite/reversed/infinite "
       "depth, asymmetric frustum and atlas bounds, invalid and oblique rejection");
}
