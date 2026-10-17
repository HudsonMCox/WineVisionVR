#include "WindowsVRFrameSynthesis.h"
#include "WindowsVRReconstruction.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#import <simd/simd.h>

namespace {
// Depth is (positive view distance in metres, confidence). Flow is a backward
// residual in normalized UV after removing depth-derived camera movement.
static NSString *const source = @R"metal(
#include <metal_stdlib>
using namespace metal;
constexpr sampler linearSample(coord::normalized,address::clamp_to_edge,filter::linear);
struct P {float4x4 inverseProjection, otherClipFromView, otherViewFromView, stereoClipFromView;
 float4x4 displayInverseProjection,sourceViewFromDisplayView,sourceProjection;
 uint2 size,origin,region,depthOrigin,depthSize;float2 range;float horizon;uint stableCamera;uint displayWarp;float motionRatio;};
float luminance(float3 c){return dot(c,float3(.2126,.7152,.0722));}
float3 ray(float2 uv,constant P&p){float4 a=p.inverseProjection*float4(uv*float2(2,-2)+float2(-1,1),.5,1);return a.xyz/max(1e-8,-a.z);}
bool projected(float2 uv,float distance,constant P&p,thread float2&at,thread float&z){
 float4 v=float4(ray(uv,p)*distance,1),c=p.otherClipFromView*v,w=p.otherViewFromView*v;
 at=c.xy/c.w*float2(.5,-.5)+.5;z=-w.z;return c.w>0&&all(isfinite(at))&&all(at>0)&&all(at<1)&&z>0;}
kernel void reduce(texture2d<float> input[[texture(0)]],texture2d<float,access::write> output[[texture(1)]],constant P&p[[buffer(0)]],uint2 at[[thread_position_in_grid]]){
 if(any(at>=p.size))return;float2 uv=(float2(at)+.5)/float2(p.size);
 // Four stratified samples avoid single-point aliasing when shrinking an eye.
 float2 step=float2(p.region)/float2(p.size)*.25;float2 c=float2(p.origin)+uv*float2(p.region);
 float3 sum=0;for(int y=-1;y<=1;y+=2)for(int x=-1;x<=1;x+=2)sum+=input.sample(linearSample,(c+float2(x,y)*step)/float2(input.get_width(),input.get_height())).rgb;
 output.write(float4(sum*.25,1),at);
}
kernel void game_depth(depth2d<float,access::read> input[[texture(0)]],texture2d<float,access::write> output[[texture(1)]],constant P&p[[buffer(0)]],uint2 at[[thread_position_in_grid]]){
 if(any(at>=p.size))return;float2 uv=(float2(at)+.5)/float2(p.size);uint2 xy=min(uint2(uv*float2(p.depthSize)),p.depthSize-1)+p.depthOrigin;
 float d=input.read(xy);float4 v=p.inverseProjection*float4(uv*float2(2,-2)+float2(-1,1),(d-p.range.x)/(p.range.y-p.range.x),1);
 float z=-v.z/v.w;bool ok=isfinite(d)&&d>=p.range.x&&d<=p.range.y&&isfinite(z)&&z>.02&&z<1000;
 output.write(ok?float4(z,1,0,0):float4(0),at);
}
float patch(texture2d<float> a,texture2d<float> b,float2 uv,float2 other,float2 step){
 float error=0;for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++){
 float2 d=float2(x,y)*step;float av=luminance(a.sample(linearSample,uv+d).rgb),bv=luminance(b.sample(linearSample,other+d).rgb);error+=abs(av-bv);}
 return error/9;}
float variation(texture2d<float> t,float2 uv,float2 step){
 return abs(luminance(t.sample(linearSample,uv+float2(step.x,0)).rgb)-luminance(t.sample(linearSample,uv-float2(step.x,0)).rgb))+
 abs(luminance(t.sample(linearSample,uv+float2(0,step.y)).rgb)-luminance(t.sample(linearSample,uv-float2(0,step.y)).rgb));}
kernel void stereo_depth(texture2d<float> a[[texture(0)]],texture2d<float> b[[texture(1)]],texture2d<float,access::write> out[[texture(2)]],constant P&p[[buffer(0)]],uint2 at[[thread_position_in_grid]]){
 if(any(at>=p.size))return;float2 uv=(float2(at)+.5)/float2(p.size),step=1/float2(p.size);
 if(variation(a,uv,step)<.015){out.write(0,at);return;}
 float costs[32];float best=INFINITY;uint chosen=0;
 for(uint i=0;i<32;i++){float z=1/mix(1.f/50.f,1.f/.15f,float(i)/31);float2 other;float oz;
 costs[i]=projected(uv,z,p,other,oz)?patch(a,b,uv,other,step):INFINITY;if(costs[i]<best){best=costs[i];chosen=i;}}
 float second=INFINITY;for(uint i=0;i<32;i++)if(abs(int(i)-int(chosen))>1)second=min(second,costs[i]);
 float inv=mix(1.f/50.f,1.f/.15f,float(chosen)/31),initialInv=inv;
 for(int i=-2;i<=2;i++){float candidate=initialInv+float(i)*(1.f/.15f-1.f/50.f)/124; if(candidate<=0)continue;
 float2 other;float oz;if(projected(uv,1/candidate,p,other,oz)){float c=patch(a,b,uv,other,step);if(c<best){best=c;inv=candidate;}}}
 float confidence=best<.08&&second>best*1.08+.001?clamp(1-best/.08,0.f,1.f):0;
 out.write(float4(confidence>0?1/inv:0,confidence,0,0),at);
}
kernel void check_depth(texture2d<float> a[[texture(0)]],texture2d<float> b[[texture(1)]],texture2d<float,access::write> out[[texture(2)]],constant P&p[[buffer(0)]],uint2 at[[thread_position_in_grid]]){
 if(any(at>=p.size))return;float2 uv=(float2(at)+.5)/float2(p.size),d=a.read(at).rg;float2 other;float z;
 if(d.y<=0||!projected(uv,d.x,p,other,z)){out.write(0,at);return;}
 float2 reverse=b.sample(linearSample,other).rg;
 if(reverse.y<=0||abs(reverse.x-z)>max(.04,z*.12))d=0;
 out.write(float4(d,0,0),at);
}
float2x2 unpack_basis(float4 v){return float2x2(v.xy,v.zw);}
bool inverse_basis(float2x2 m,thread float2x2&inverse){float determinant=m[0].x*m[1].y-m[1].x*m[0].y;
 if(!isfinite(determinant)||abs(determinant)<1e-4){inverse=float2x2(1);return false;}
 inverse=float2x2(float2(m[1].y,-m[0].y),float2(-m[1].x,m[0].x))/determinant;return true;}
bool image_basis(float2 uv,float distance,constant P&p,thread float2x2&basis){
 constexpr float epsilon=1.f/1024;
 float4 c=p.otherClipFromView*float4(ray(uv,p)*distance,1),x=p.otherClipFromView*float4(ray(uv+float2(epsilon,0),p)*distance,1),y=p.otherClipFromView*float4(ray(uv+float2(0,epsilon),p)*distance,1);
 if(min(c.w,min(x.w,y.w))<=0)return false;
 float2 center=c.xy/c.w;basis=float2x2((x.xy/x.w-center)*float2(.5,-.5)/epsilon,(y.xy/y.w-center)*float2(.5,-.5)/epsilon);
 return all(isfinite(basis[0]))&&all(isfinite(basis[1]));}
kernel void motion_basis(texture2d<float>depth[[texture(0)]],texture2d<float,access::write>out[[texture(1)]],constant P&p[[buffer(0)]],uint2 at[[thread_position_in_grid]]){
 if(any(at>=p.size))return;float2x2 basis=float2x2(1);float2 d=depth.read(at).rg;
 bool valid=d.y>.2?image_basis((float2(at)+.5)/float2(p.size),d.x,p,basis):p.stableCamera!=0;
 out.write(valid?float4(basis[0],basis[1]):float4(0),at);
}
float warped_patch(texture2d<float>a,texture2d<float>b,float2 uv,float2 other,float2 step,float2x2 basis){
 float error=0;for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++){float2 d=float2(x,y)*step;
 error+=abs(luminance(a.sample(linearSample,uv+d).rgb)-luminance(b.sample(linearSample,other+basis*d).rgb));}return error/9;
}
kernel void flow(texture2d<float> current[[texture(0)]],texture2d<float> previous[[texture(1)]],texture2d<float> depth[[texture(2)]],texture2d<float> previousDepth[[texture(3)]],texture2d<float> coarse[[texture(4)]],texture2d<float,access::write> out[[texture(5)]],texture2d<float>cameraBasis[[texture(6)]],constant P&p[[buffer(0)]],uint2 at[[thread_position_in_grid]]){
 if(any(at>=p.size))return;float2 uv=(float2(at)+.5)/float2(p.size),step=1/float2(p.size),d=depth.sample(linearSample,uv).rg,base=uv;float expected=0;
 bool hasDepth=d.y>.2&&projected(uv,d.x,p,base,expected);
 if(!hasDepth&&!p.stableCamera){out.write(0,at);return;}
 float2x2 basis=unpack_basis(cameraBasis.sample(linearSample,uv)),inverse=float2x2(1);
 if(!inverse_basis(basis,inverse)){out.write(0,at);return;}
 float2 guess=p.horizon>0?basis*coarse.sample(linearSample,uv).xy:float2(0);float best=INFINITY;float2 residual=0;
 for(int y=-2;y<=2;y++)for(int x=-2;x<=2;x++){float2 r=guess+float2(x,y)*step,atUV=base+r;
 if(any(atUV<step)||any(atUV>1-step))continue;float cost=warped_patch(current,previous,uv,atUV,step,basis);
 if(cost<best){best=cost;residual=r;}}
 float2 pd=previousDepth.sample(linearSample,base+residual).rg;
 bool compatible=!hasDepth||(pd.y>.2&&abs(pd.x-expected)<max(.05,expected*.2));
 float confidence=compatible&&variation(current,uv,step)>.01&&best<.1?clamp(1-best/.1,0.f,1.f):0;
 out.write(float4(inverse*residual,confidence,hasDepth?d.y:1),at);
}
bool display_to_source(float2 uv,texture2d<float> depth,constant P&p,thread float2&mapped){
 if(!p.displayWarp){mapped=uv;return true;}
 float4 ray=p.displayInverseProjection*float4(uv*float2(2,-2)+float2(-1,1),.5,1);
 float3 direction=(p.sourceViewFromDisplayView*float4(ray.xyz/max(1e-8,-ray.z),0)).xyz;
 float3 translation=p.sourceViewFromDisplayView[3].xyz;
 float4 farClip=p.sourceProjection*float4(direction,0);
 if(farClip.w<=0)return false;
 float2 rotationUV=farClip.xy/farClip.w*float2(.5,-.5)+.5;
 if(any(rotationUV<0)||any(rotationUV>1))return false;
 mapped=rotationUV;float2 last=mapped;
 // Solve the target ray against the source depth field. Uncertain or unstable
 // intersections retain rotational reprojection; hidden detail is not invented.
 for(uint i=0;i<3;i++){
  float2 d=depth.sample(linearSample,mapped).rg;
  if(d.y<.5||!isfinite(d.x)||d.x<=0||abs(direction.z)<1e-6){mapped=rotationUV;return true;}
  float distance=(-d.x-translation.z)/direction.z;
  if(distance<=0){mapped=rotationUV;return true;}
  float4 clip=p.sourceProjection*float4(direction*distance+translation,1);
  if(clip.w<=0){mapped=rotationUV;return true;}
  float2 candidate=clip.xy/clip.w*float2(.5,-.5)+.5;
  if(any(candidate<0)||any(candidate>1)){mapped=rotationUV;return true;}
  last=mapped;mapped=candidate;
 }
 if(length((mapped-last)*float2(depth.get_width(),depth.get_height()))>1.5)mapped=rotationUV;
 return true;
}
kernel void display_map(texture2d<float> depth[[texture(0)]],texture2d<float,access::write> output[[texture(1)]],constant P&p[[buffer(0)]],uint2 at[[thread_position_in_grid]]){
 if(any(at>=p.size))return;float2 uv=0;bool valid=display_to_source((float2(at)+.5)/float2(p.size),depth,p,uv);output.write(valid?float4(uv,1,0):float4(0),at);
}
kernel void reconstruct(texture2d<float> current[[texture(0)]],texture2d<float> previous[[texture(1)]],texture2d<float> backward[[texture(2)]],texture2d<float> forward[[texture(3)]],texture2d<float> depth[[texture(4)]],texture2d<float,access::write> out[[texture(5)]],texture2d<float> otherFlow[[texture(6)]],texture2d<float> previousMotion[[texture(7)]],texture2d<float> displayMap[[texture(8)]],texture2d<float>cameraBasis[[texture(9)]],texture2d<float>stereoBasis[[texture(10)]],constant P&p[[buffer(0)]],uint2 at[[thread_position_in_grid]]){
 if(any(at>=p.size))return;float2 uv;
 if(p.displayWarp==2){float4 mapped=displayMap.sample(linearSample,(float2(at)+.5)/float2(p.size));uv=mapped.rg;if(mapped.b<.999||any(uv<0)||any(uv>1)){out.write(float4(0,0,0,1),at);return;}}
 else if(!display_to_source((float2(at)+.5)/float2(p.size),depth,p,uv)){out.write(float4(0,0,0,1),at);return;}
 float2 sampleUV=uv;float4 f=backward.sample(linearSample,uv);float2 d=depth.sample(linearSample,uv).rg;
 float2 base=uv;float z=0;bool valid=f.z>.5&&f.w>.2;bool hasDepth=d.y>.2&&projected(uv,d.x,p,base,z);
 valid=valid&&(hasDepth||p.stableCamera);
 float2x2 basis=unpack_basis(cameraBasis.sample(linearSample,uv)),inverse=float2x2(1);
 valid=valid&&inverse_basis(basis,inverse);float2 previousOffset=basis*f.xy;
 float4 reverse=forward.sample(linearSample,base+previousOffset);
 valid=valid&&reverse.z>.5&&length((f.xy+inverse*reverse.xy)*float2(backward.get_width(),backward.get_height()))<1.5;
 if(valid&&hasDepth){float4 otherClip=p.stereoClipFromView*float4(ray(uv,p)*d.x,1);float2 otherUV=otherClip.xy/otherClip.w*float2(.5,-.5)+.5;
 float4 sibling=otherFlow.sample(linearSample,otherUV);float2x2 siblingInverse=float2x2(1);valid=valid&&inverse_basis(unpack_basis(stereoBasis.sample(linearSample,uv)),siblingInverse);valid=valid&&otherClip.w>0&&all(otherUV>0)&&all(otherUV<1)&&sibling.z>.5&&length((f.xy-siblingInverse*sibling.xy)*float2(backward.get_width(),backward.get_height()))<2.5;}
 float localHorizon=p.horizon*smoothstep(.5,.9,min(f.z,reverse.z));
 if(valid&&p.motionRatio>0){float4 prior=previousMotion.sample(linearSample,base+previousOffset);
  if(prior.z>.5){float change=length((f.xy-inverse*prior.xy*p.motionRatio)*float2(backward.get_width(),backward.get_height()));localHorizon/=1+change*.25;}}
 if(valid&&p.horizon>0){sampleUV=uv+f.xy*localHorizon;valid=all(sampleUV>=0)&&all(sampleUV<=1);}
 if(!valid)sampleUV=uv;
 float3 c=current.sample(linearSample,sampleUV).rgb;float2 step=1/float2(current.get_width(),current.get_height());
 float3 l=current.sample(linearSample,sampleUV-float2(step.x,0)).rgb,r=current.sample(linearSample,sampleUV+float2(step.x,0)).rgb;
 float3 t=current.sample(linearSample,sampleUV-float2(0,step.y)).rgb,b=current.sample(linearSample,sampleUV+float2(0,step.y)).rgb;
 // Bounded edge enhancement preserves local extrema rather than ringing around UI.
 float3 lo=min(c,min(min(l,r),min(t,b))),hi=max(c,max(max(l,r),max(t,b)));
 float3 spatial=clamp(c+(c-(l+r+t+b)*.25)*.15,lo,hi);
 if(valid&&p.horizon==0){float3 history=previous.sample(linearSample,base+previousOffset).rgb;spatial=mix(spatial,clamp(history,lo,hi),.15*f.z);}
 out.write(float4(spatial,1),at);
}
kernel void coverage_stats(texture2d<float,access::read> depth[[texture(0)]],texture2d<float> motion[[texture(1)]],device float2* result[[buffer(1)]],constant P&p[[buffer(0)]],uint2 at[[thread_position_in_grid]],uint tid[[thread_index_in_threadgroup]],uint2 tile[[threadgroup_position_in_grid]]){
 threadgroup uint depths[64],motions[64];bool inside=all(at<p.size);float2 uv=(float2(at)+.5)/float2(p.size);
 depths[tid]=inside&&depth.read(at).y>.2?1:0;motions[tid]=inside&&motion.sample(linearSample,uv).z>.5?1:0;
 threadgroup_barrier(mem_flags::mem_threadgroup);
 for(uint stride=32;stride;stride>>=1){if(tid<stride){depths[tid]+=depths[tid+stride];motions[tid]+=motions[tid+stride];}threadgroup_barrier(mem_flags::mem_threadgroup);}
 if(tid==0)result[tile.y*((p.size.x+7)/8)+tile.x]=float2(depths[0],motions[0]);
}
)metal";
struct P {
  simd_float4x4 inverseProjection, otherClipFromView, otherViewFromView,
      stereoClipFromView, displayInverseProjection, sourceViewFromDisplayView,
      sourceProjection;
  simd_uint2 size{}, origin{}, region{}, depthOrigin{}, depthSize{};
  simd_float2 range{};
  float horizon = 0;
  uint32_t stableCamera = 0, displayWarp = 0;
  float motionRatio = 0;
};
static_assert(sizeof(P) == 512);
struct Eye {
  __strong id<MTLTexture> color = nil, pyramid[3]{}, rawDepth = nil,
                          depth = nil, flow[2][3]{}, basis[3]{};
  WVRReconstructionEyeV1 geometry{};
};
struct Frame {
  Eye eyes[2];
  uint64_t id = 0, time = 0, generation = 0, interval = 0;
};
struct Slot {
  __strong id<MTLTexture> eyes[2]{}, mapping[2]{};
  std::shared_ptr<std::atomic<bool>> busy =
      std::make_shared<std::atomic<bool>>(false);
};
struct Stats {
  std::atomic<uint64_t> epoch{0}, coverageFrameID{0}, trackedPoseJobs{0};
  std::atomic<double> depthCoverage[2]{}, motionCoverage[2]{};
  std::atomic<uint64_t> frames{0}, gameDepth{0}, estimatedDepth{0},
      generated{0}, spatial{0}, resets{0}, busy{0}, failed{0};
  std::atomic<double> gpuMs{0};
};
struct Context {
  __strong id<MTLDevice> device;
  __strong id<MTLCommandQueue> queue = nil;
  __strong id<MTLComputePipelineState> pipelines[9]{};
  Frame frames[2];
  Slot slots[3];
  __strong id<MTLTexture> outputs[2]{}, dummy = nil;
  unsigned latest = 0;
  bool ready = false;
  uint32_t mode;
  std::mutex mutex;
  std::shared_ptr<Stats> stats = std::make_shared<Stats>();
  Context(id<MTLDevice> d, uint32_t m) : device(d), mode(m) {}
};
simd_float4x4 matrix(const float *m) {
  simd_float4x4 r;
  memcpy(&r, m, sizeof(r));
  return r;
}
id<MTLTexture> make(id<MTLDevice> d, MTLPixelFormat f, unsigned w, unsigned h,
                    MTLTextureUsage use = MTLTextureUsageShaderRead |
                                          MTLTextureUsageShaderWrite) {
  auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f
                                                                 width:w
                                                                height:h
                                                             mipmapped:NO];
  desc.storageMode = MTLStorageModePrivate;
  desc.usage = use;
  return [d newTextureWithDescriptor:desc];
}
bool ensure(id<MTLDevice> d, id<MTLTexture> __strong &t, MTLPixelFormat f,
            unsigned w, unsigned h,
            MTLTextureUsage use = MTLTextureUsageShaderRead |
                                  MTLTextureUsageShaderWrite) {
  if (!t || t.width != w || t.height != h || t.pixelFormat != f)
    t = make(d, f, w, h, use);
  return t != nil;
}
id<MTLTexture> view(id<MTLTexture> t, unsigned slice) {
  if (t.textureType == MTLTextureType2D)
    return slice ? nil : t;
  if (t.textureType != MTLTextureType2DArray || slice >= t.arrayLength)
    return nil;
  return [t newTextureViewWithPixelFormat:t.pixelFormat
                              textureType:MTLTextureType2D
                                   levels:NSMakeRange(0, 1)
                                   slices:NSMakeRange(slice, 1)];
}
bool region(id<MTLTexture> t, unsigned slice, unsigned x, unsigned y,
            unsigned w, unsigned h, id<MTLDevice> d) {
  return t && t.device == d && t.sampleCount == 1 && slice < t.arrayLength &&
         w && h && w <= 8192 && h <= 8192 && uint64_t(w) * h <= 16777216 &&
         x <= t.width && y <= t.height && w <= t.width - x && h <= t.height - y;
}
P params(const WVRReconstructionEyeV1 &from, const WVRReconstructionEyeV1 &to) {
  P p{};
  p.inverseProjection = simd_inverse(matrix(from.projection));
  p.otherViewFromView = simd_mul(simd_inverse(matrix(to.originFromEye)),
                                 matrix(from.originFromEye));
  p.otherClipFromView = simd_mul(matrix(to.projection), p.otherViewFromView);
  float difference = 0;
  for (unsigned c = 0; c < 4; c++)
    for (unsigned r = 0; r < 4; r++)
      difference +=
          std::fabs(p.otherViewFromView.columns[c][r] - (c == r ? 1.f : 0.f));
  p.stableCamera = difference < .0001f;
  return p;
}
void dispatch(Context &c, id<MTLComputeCommandEncoder> e, unsigned pipeline,
              const P &p, std::initializer_list<id<MTLTexture>> textures) {
  [e setComputePipelineState:c.pipelines[pipeline]];
  [e setBytes:&p length:sizeof(p) atIndex:0];
  id<MTLTexture> __unsafe_unretained bindings[11]{};
  unsigned i = 0;
  for (auto texture : textures)
    bindings[i++] = texture;
  [e setTextures:bindings withRange:NSMakeRange(0, i)];
  [e dispatchThreads:MTLSizeMake(p.size.x, p.size.y, 1)
      threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
  [e memoryBarrierWithScope:MTLBarrierScopeTextures];
}
void reset(Context &c) {
  c.stats->epoch++;
  c.stats->coverageFrameID = 0;
  for (unsigned i = 0; i < 2; i++) {
    c.stats->depthCoverage[i] = 0;
    c.stats->motionCoverage[i] = 0;
  }
  c.ready = false;
  c.frames[0] = Frame{};
  c.frames[1] = Frame{};
  c.outputs[0] = c.outputs[1] = nil;
  c.stats->resets++;
}
} // namespace
extern "C" void *wvr_synthesis_create_v1(void *device, uint32_t mode) {
  @autoreleasepool {
    if (!device || mode < 1 || mode > 2)
      return nullptr;
    auto c = std::make_unique<Context>((__bridge id<MTLDevice>)device, mode);
    NSError *error = nil;
    auto lib = [c->device newLibraryWithSource:source options:nil error:&error];
    if (!lib) {
      NSLog(@"[synthesis] %@", error);
      return nullptr;
    }
    const char *names[] = {"reduce",         "game_depth",  "stereo_depth",
                           "check_depth",    "flow",        "reconstruct",
                           "coverage_stats", "display_map", "motion_basis"};
    for (unsigned i = 0; i < 9; i++) {
      auto f =
          [lib newFunctionWithName:[NSString stringWithUTF8String:names[i]]];
      c->pipelines[i] = [c->device newComputePipelineStateWithFunction:f
                                                                 error:&error];
      if (!c->pipelines[i])
        return nullptr;
    }
    auto dummyDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                     width:1
                                    height:1
                                 mipmapped:NO];
    dummyDesc.storageMode = MTLStorageModeShared;
    dummyDesc.usage = MTLTextureUsageShaderRead;
    c->dummy = [c->device newTextureWithDescriptor:dummyDesc];
    if (!c->dummy)
      return nullptr;
    uint16_t zero[4]{};
    [c->dummy replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                mipmapLevel:0
                  withBytes:zero
                bytesPerRow:8];
    // Never sample uninitialized dummy storage, even when a shader branch
    // disables motion.
    return c.release();
  }
}
extern "C" void wvr_synthesis_reset_v1(void *ctx) {
  if (!ctx)
    return;
  auto &c = *static_cast<Context *>(ctx);
  std::lock_guard lock(c.mutex);
  reset(c);
}
extern "C" void wvr_synthesis_destroy_v1(void *ctx) {
  delete static_cast<Context *>(ctx);
}
extern "C" int32_t
wvr_synthesis_ingest_v1(void *ctx, const WVRAcquiredStereoFrameV2 *input,
                        const WVRFrameTrackingV1 *tracking, uint64_t generation,
                        void *buffer) {
  @autoreleasepool {
    if (!ctx || !input || !tracking || !buffer)
      return -1;
    auto &c = *static_cast<Context *>(ctx);
    std::lock_guard lock(c.mutex);
    auto commands = (__bridge id<MTLCommandBuffer>)buffer;
    if (input->structSize != sizeof(*input) || input->abiVersion != 2 ||
        tracking->structSize != sizeof(*tracking) ||
        tracking->abiVersion != 1 || !input->lease || !generation ||
        !input->producerFrameID || !input->producerTimestampNanoseconds ||
        !input->producerReadyEvent || commands.device != c.device ||
        !commands.retainedReferences ||
        !(tracking->flags & WVRDevicePoseTracked)) {
      reset(c);
      return -1;
    }
    auto &old = c.frames[c.latest];
    bool discontinuity =
        !c.ready || c.queue != commands.commandQueue ||
        old.generation != generation || input->producerFrameID <= old.id ||
        input->producerTimestampNanoseconds <= old.time ||
        input->producerTimestampNanoseconds - old.time > 100000000 ||
        old.eyes[0].color.width != input->leftWidth ||
        old.eyes[0].color.height != input->leftHeight ||
        old.eyes[1].color.width != input->rightWidth ||
        old.eyes[1].color.height != input->rightHeight;
    if (discontinuity)
      reset(c);
    c.queue = commands.commandQueue;
    WVRReconstructionSubmitV1 geometry{};
    geometry.abiVersion = WVR_RECONSTRUCTION_ABI;
    geometry.structSize = sizeof(geometry);
    bool explicitDepth =
        wvr_compositor_copy_reconstruction_v1(input->lease, &geometry) == 0 &&
        geometry.frameID == input->producerFrameID &&
        geometry.targetGeneration == generation;
    const unsigned next = c.ready ? 1 - c.latest : c.latest;
    auto &frame = c.frames[next];
    const uint32_t slices[] = {input->leftSlice, input->rightSlice},
                   xs[] = {input->leftX, input->rightX},
                   ys[] = {input->leftY, input->rightY},
                   widths[] = {input->leftWidth, input->rightWidth},
                   heights[] = {input->leftHeight, input->rightHeight};
    void *colors[] = {input->leftTexture, input->rightTexture};
    for (unsigned i = 0; i < 2; i++) {
      auto color = (__bridge id<MTLTexture>)colors[i];
      if (!region(color, slices[i], xs[i], ys[i], widths[i], heights[i],
                  c.device)) {
        reset(c);
        return -1;
      }
      auto &e = frame.eyes[i];
      if (explicitDepth)
        e.geometry = geometry.eyes[i];
      else {
        e.geometry = {};
        auto pose = simd_mul(matrix(tracking->originFromDevice),
                             matrix(tracking->deviceFromEye[i]));
        memcpy(e.geometry.originFromEye, &pose, sizeof(pose));
        memcpy(e.geometry.projection, tracking->projection[i], 64);
      }
      for (unsigned k = 0; k < 16; k++)
        if (!std::isfinite(e.geometry.projection[k]) ||
            !std::isfinite(e.geometry.originFromEye[k])) {
          reset(c);
          return -1;
        }
      const float projectionDet =
          simd_determinant(matrix(e.geometry.projection));
      const float poseDet = simd_determinant(matrix(e.geometry.originFromEye));
      if (!std::isfinite(projectionDet) || !std::isfinite(poseDet) ||
          std::fabs(projectionDet) < 1e-12 || std::fabs(poseDet) < 1e-8) {
        reset(c);
        return -1;
      }
      if (!ensure(c.device, e.color, color.pixelFormat, widths[i], heights[i],
                  MTLTextureUsageShaderRead)) {
        reset(c);
        return -1;
      }
      if (c.mode == 2) {
        unsigned w = std::min(192u, widths[i]),
                 h = std::max(8u,
                              unsigned(uint64_t(heights[i]) * w / widths[i]));
        for (unsigned level = 0; level < 3; level++) {
          if (!ensure(c.device, e.pyramid[level], MTLPixelFormatRGBA16Float,
                      std::max(1u, w >> level), std::max(1u, h >> level))) {
            reset(c);
            return -1;
          }
          for (unsigned dir = 0; dir < 2; dir++)
            if (!ensure(c.device, e.flow[dir][level], MTLPixelFormatRGBA16Float,
                        std::max(1u, w >> level), std::max(1u, h >> level))) {
              reset(c);
              return -1;
            }
        }
        for (unsigned kind = 0; kind < 3; kind++)
          if (!ensure(c.device, e.basis[kind], MTLPixelFormatRGBA16Float, w,
                      h)) {
            reset(c);
            return -1;
          }
        if (!ensure(c.device, e.rawDepth, MTLPixelFormatRG32Float, w, h) ||
            !ensure(c.device, e.depth, MTLPixelFormatRG32Float, w, h)) {
          reset(c);
          return -1;
        }
      }
    }
    [commands encodeWaitForEvent:(__bridge id<MTLSharedEvent>)
                                     input->producerReadyEvent
                           value:input->producerReadyValue];
    auto blit = [commands blitCommandEncoder];
    if (!blit) {
      reset(c);
      return -1;
    }
    for (unsigned i = 0; i < 2; i++) {
      auto src = (__bridge id<MTLTexture>)colors[i];
      [blit copyFromTexture:src
                sourceSlice:slices[i]
                sourceLevel:0
               sourceOrigin:MTLOriginMake(xs[i], ys[i], 0)
                 sourceSize:MTLSizeMake(widths[i], heights[i], 1)
                  toTexture:frame.eyes[i].color
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    }
    [blit endEncoding];
    if (c.mode == 2) {
      auto enc = [commands computeCommandEncoder];
      if (!enc) {
        reset(c);
        return -1;
      }
      for (unsigned i = 0; i < 2; i++) {
        auto &e = frame.eyes[i];
        for (unsigned level = 0; level < 3; level++) {
          auto src = level ? e.pyramid[level - 1] : e.color;
          P p{};
          p.size = {(uint32_t)e.pyramid[level].width,
                    (uint32_t)e.pyramid[level].height};
          p.region = {(uint32_t)src.width, (uint32_t)src.height};
          dispatch(c, enc, 0, p, {src, e.pyramid[level]});
        }
      }
      for (unsigned i = 0; i < 2; i++) {
        auto &e = frame.eyes[i];
        P p = params(e.geometry, frame.eyes[1 - i].geometry);
        p.size = {(uint32_t)e.depth.width, (uint32_t)e.depth.height};
        if (explicitDepth) {
          auto &g = e.geometry;
          auto depth = view((__bridge id<MTLTexture>)(void *)g.depthTexture,
                            g.depthSlice);
          if (!depth) {
            [enc endEncoding];
            reset(c);
            return -1;
          }
          p.depthOrigin = {g.depthX, g.depthY};
          p.depthSize = {g.depthWidth, g.depthHeight};
          p.range = {g.minDepth, g.maxDepth};
          dispatch(c, enc, 1, p, {depth, e.depth});
        } else
          dispatch(c, enc, 2, p,
                   {e.pyramid[0], frame.eyes[1 - i].pyramid[0], e.rawDepth});
      }
      if (!explicitDepth)
        for (unsigned i = 0; i < 2; i++) {
          auto &e = frame.eyes[i];
          P p = params(e.geometry, frame.eyes[1 - i].geometry);
          p.size = {(uint32_t)e.depth.width, (uint32_t)e.depth.height};
          dispatch(c, enc, 3, p,
                   {e.rawDepth, frame.eyes[1 - i].rawDepth, e.depth});
        }
      for (unsigned i = 0; i < 2; i++)
        for (unsigned kind = 0; kind < 3; kind++) {
          auto &from = kind == 1 && c.ready ? old.eyes[i] : frame.eyes[i];
          auto &to = kind == 2
                         ? frame.eyes[1 - i]
                         : (kind == 0 && c.ready ? old.eyes[i] : frame.eyes[i]);
          P p = params(from.geometry, to.geometry);
          p.size = {(uint32_t)from.depth.width, (uint32_t)from.depth.height};
          dispatch(c, enc, 8, p, {from.depth, frame.eyes[i].basis[kind]});
        }
      if (c.ready)
        for (unsigned i = 0; i < 2; i++)
          for (unsigned direction = 0; direction < 2; direction++) {
            auto &current = direction ? old.eyes[i] : frame.eyes[i];
            auto &previous = direction ? frame.eyes[i] : old.eyes[i];
            // Store both directions in the new frame; previous-owned textures
            // stay immutable.
            P p = params(current.geometry, previous.geometry);
            for (int level = 2; level >= 0; level--) {
              p.size = {(uint32_t)current.pyramid[level].width,
                        (uint32_t)current.pyramid[level].height};
              p.horizon = level < 2 ? 1 : 0;
              dispatch(c, enc, 4, p,
                       {current.pyramid[level], previous.pyramid[level],
                        current.depth, previous.depth,
                        level < 2 ? frame.eyes[i].flow[direction][level + 1]
                                  : c.dummy,
                        frame.eyes[i].flow[direction][level],
                        frame.eyes[i].basis[direction]});
            }
          }
      // Sample coverage asynchronously, including source changes. This is not
      // a full-frame CPU readback and does not serialize gameplay with the GPU.
      if (c.stats->frames.load() % 60 == 0 || !c.ready ||
          explicitDepth != (old.eyes[0].geometry.depthTexture != 0)) {
        for (unsigned eye = 0; eye < 2; eye++) {
          auto &e = frame.eyes[eye];
          unsigned w = e.depth.width, h = e.depth.height, tx = (w + 7) / 8,
                   ty = (h + 7) / 8;
          auto metrics = [c.device
              newBufferWithLength:uint64_t(tx) * ty * sizeof(simd_float2)
                          options:MTLResourceStorageModeShared];
          if (!metrics)
            continue;
          P p{};
          p.size = {w, h};
          [enc setComputePipelineState:c.pipelines[6]];
          [enc setBytes:&p length:sizeof(p) atIndex:0];
          [enc setBuffer:metrics offset:0 atIndex:1];
          [enc setTexture:e.depth atIndex:0];
          [enc setTexture:c.ready ? e.flow[0][0] : c.dummy atIndex:1];
          [enc dispatchThreadgroups:MTLSizeMake(tx, ty, 1)
              threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
          auto stats = c.stats;
          const uint64_t epoch = stats->epoch.load(),
                         frameID = input->producerFrameID;
          [commands addCompletedHandler:^(id<MTLCommandBuffer> b) {
            if (b.status != MTLCommandBufferStatusCompleted ||
                stats->epoch.load() != epoch)
              return;
            auto values = static_cast<const simd_float2 *>(metrics.contents);
            double depthCount = 0, motionCount = 0;
            for (unsigned i = 0; i < tx * ty; i++) {
              depthCount += values[i].x;
              motionCount += values[i].y;
            }
            stats->depthCoverage[eye] = depthCount / (uint64_t(w) * h);
            stats->motionCoverage[eye] = motionCount / (uint64_t(w) * h);
            stats->coverageFrameID = frameID;
          }];
        }
      }
      [enc endEncoding];
      if (explicitDepth)
        c.stats->gameDepth++;
      else
        c.stats->estimatedDepth++;
    }
    frame.interval =
        c.ready ? input->producerTimestampNanoseconds - old.time : 0;
    frame.id = input->producerFrameID;
    frame.time = input->producerTimestampNanoseconds;
    frame.generation = generation;
    c.latest = next;
    c.ready = true;
    c.stats->frames++;
    return 0;
  }
}
static int32_t encode(void *ctx, uint64_t timestamp, uint32_t lw, uint32_t lh,
                      uint32_t rw, uint32_t rh, uint32_t extrapolate,
                      void *buffer, const WVRFrameSynthesisViewV1 *views) {
  @autoreleasepool {
    if (!ctx || !buffer)
      return -1;
    auto &c = *static_cast<Context *>(ctx);
    std::lock_guard lock(c.mutex);
    auto commands = (__bridge id<MTLCommandBuffer>)buffer;
    if (!c.ready || commands.device != c.device ||
        commands.commandQueue != c.queue || !commands.retainedReferences)
      return 1;
    auto &now = c.frames[c.latest];
    auto &previous = c.frames[1 - c.latest];
    if (timestamp < now.time || timestamp - now.time > 100000000) {
      c.outputs[0] = c.outputs[1] = nil;
      return 1;
    }
    const unsigned widths[] = {lw, rw}, heights[] = {lh, rh};
    for (unsigned i = 0; i < 2; i++)
      if (!widths[i] || !heights[i] ||
          uint64_t(widths[i]) * heights[i] > 16777216)
        return -1;
    if (views)
      for (unsigned i = 0; i < 2; i++) {
        for (unsigned k = 0; k < 16; k++)
          if (!std::isfinite(views[i].originFromEye[k]) ||
              !std::isfinite(views[i].projection[k]))
            return -1;
        const float pd = simd_determinant(matrix(views[i].projection)),
                    vd = simd_determinant(matrix(views[i].originFromEye));
        if (!std::isfinite(pd) || !std::isfinite(vd) || std::fabs(pd) < 1e-12 ||
            std::fabs(vd) < 1e-8)
          return -1;
      }
    Slot *slot = nullptr;
    for (auto &s : c.slots) {
      bool expected = false;
      if (s.busy->compare_exchange_strong(expected, true)) {
        slot = &s;
        break;
      }
    }
    if (!slot) {
      c.stats->busy++;
      return 1;
    }
    for (unsigned i = 0; i < 2; i++)
      if (!ensure(c.device, slot->eyes[i], MTLPixelFormatRGBA16Float, widths[i],
                  heights[i])) {
        *slot->busy = false;
        return -1;
      }
    bool history = c.mode == 2 && previous.id && previous.time < now.time;
    float horizon = history && extrapolate
                        ? std::min(1.f, float(timestamp - now.time) /
                                            float(now.time - previous.time))
                        : 0;
    auto enc = [commands computeCommandEncoder];
    if (!enc) {
      *slot->busy = false;
      return -1;
    }
    for (unsigned i = 0; i < 2; i++) {
      auto &e = now.eyes[i];
      P p =
          params(e.geometry, history ? previous.eyes[i].geometry : e.geometry);
      p.size = {widths[i], heights[i]};
      p.horizon = horizon;
      p.motionRatio = history && previous.interval
                          ? float(now.interval) / float(previous.interval)
                          : 0;
      if (views) {
        p.displayWarp = 1;
        p.displayInverseProjection = simd_inverse(matrix(views[i].projection));
        p.sourceViewFromDisplayView =
            simd_mul(simd_inverse(matrix(e.geometry.originFromEye)),
                     matrix(views[i].originFromEye));
        p.sourceProjection = matrix(e.geometry.projection);
      }

      p.stereoClipFromView =
          params(e.geometry, now.eyes[1 - i].geometry).otherClipFromView;
      if (views && c.mode == 2) {
        P map = p;
        map.size = {(uint32_t)e.depth.width, (uint32_t)e.depth.height};
        if (!ensure(c.device, slot->mapping[i], MTLPixelFormatRGBA32Float,
                    map.size.x, map.size.y)) {
          [enc endEncoding];
          auto busy = slot->busy;
          [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
            busy->store(false);
          }];
          return -1;
        }
        dispatch(c, enc, 7, map, {e.depth, slot->mapping[i]});
        p.displayWarp = 2;
      }
      // A zero confidence cleared dummy is required when no second frame
      // exists.
      if (!history) {
        p.stableCamera = 0;
        p.otherClipFromView = simd_float4x4{};
      }
      dispatch(
          c, enc, 5, p,
          {e.color, history ? previous.eyes[i].color : e.color,
           history ? e.flow[0][0] : c.dummy, history ? e.flow[1][0] : c.dummy,
           c.mode == 2 ? e.depth : c.dummy, slot->eyes[i],
           history ? now.eyes[1 - i].flow[0][0] : c.dummy,
           history && previous.interval ? previous.eyes[i].flow[0][0] : c.dummy,
           views && c.mode == 2 ? slot->mapping[i] : c.dummy,
           history ? e.basis[0] : c.dummy, history ? e.basis[2] : c.dummy});
      c.outputs[i] = slot->eyes[i];
    }
    [enc endEncoding];
    auto busy = slot->busy;
    auto stats = c.stats;
    [commands addCompletedHandler:^(id<MTLCommandBuffer> b) {
      if (b.status != MTLCommandBufferStatusCompleted)
        stats->failed++;
      else if (b.GPUEndTime > b.GPUStartTime)
        stats->gpuMs.store((b.GPUEndTime - b.GPUStartTime) * 1000);
      busy->store(false);
    }];
    if (views)
      c.stats->trackedPoseJobs++;
    if (horizon > 0)
      c.stats->generated++;
    else
      c.stats->spatial++;
    return 0;
  }
}
extern "C" int32_t wvr_synthesis_encode_v1(void *ctx, uint64_t timestamp,
                                           uint32_t lw, uint32_t lh,
                                           uint32_t rw, uint32_t rh,
                                           uint32_t extrapolate, void *buffer) {
  return encode(ctx, timestamp, lw, lh, rw, rh, extrapolate, buffer, nullptr);
}
extern "C" int32_t
wvr_synthesis_encode_display_v1(void *ctx, uint64_t timestamp,
                                const WVRFrameSynthesisViewV1 views[2],
                                uint32_t extrapolate, void *buffer) {
  if (!views)
    return -1;
  return encode(ctx, timestamp, views[0].width, views[0].height, views[1].width,
                views[1].height, extrapolate, buffer, views);
}
extern "C" void *wvr_synthesis_copy_source_v1(void *ctx, uint32_t eye) {
  if (!ctx || eye > 1)
    return nullptr;
  auto &c = *static_cast<Context *>(ctx);
  std::lock_guard lock(c.mutex);
  auto t = c.frames[c.latest].eyes[eye].color;
  return c.ready && t ? (__bridge_retained void *)t : nullptr;
}
extern "C" void *wvr_synthesis_copy_output_v1(void *ctx, uint32_t eye) {
  if (!ctx || eye > 1)
    return nullptr;
  auto &c = *static_cast<Context *>(ctx);
  std::lock_guard lock(c.mutex);
  return c.outputs[eye] ? (__bridge_retained void *)c.outputs[eye] : nullptr;
}
extern "C" void *wvr_synthesis_copy_motion_v1(void *ctx, uint32_t eye) {
  if (!ctx || eye > 1)
    return nullptr;
  auto &c = *static_cast<Context *>(ctx);
  std::lock_guard lock(c.mutex);
  auto t = c.frames[c.latest].eyes[eye].flow[0][0];
  return c.ready && c.frames[1 - c.latest].id && t ? (__bridge_retained void *)t
                                                   : nullptr;
}
extern "C" void *wvr_synthesis_copy_depth_v1(void *ctx, uint32_t eye) {
  if (!ctx || eye > 1)
    return nullptr;
  auto &c = *static_cast<Context *>(ctx);
  std::lock_guard lock(c.mutex);
  auto t = c.frames[c.latest].eyes[eye].depth;
  return c.ready && t ? (__bridge_retained void *)t : nullptr;
}
extern "C" int32_t wvr_synthesis_copy_stats_v1(void *ctx, char *buffer,
                                               uint32_t size) {
  if (!ctx || !buffer || !size)
    return 0;
  auto &c = *static_cast<Context *>(ctx);
  auto &s = *c.stats;
  snprintf(
      buffer, size,
      "synthesis backend=custom-metal mode=%u frames=%llu gameDepthFrames=%llu "
      "stereoEstimatedDepthFrames=%llu generatedDisplayJobs=%llu "
      "spatialJobs=%llu resets=%llu busyFallbacks=%llu gpuFailed=%llu "
      "commandBufferGPUms=%.3f motion=estimated-optical-flow "
      "coverageFrameID=%llu depthCoverageL=%.4f depthCoverageR=%.4f "
      "motionCoverageL=%.4f motionCoverageR=%.4f trackedPoseDisplayJobs=%llu",
      c.mode, (unsigned long long)s.frames.load(),
      (unsigned long long)s.gameDepth.load(),
      (unsigned long long)s.estimatedDepth.load(),
      (unsigned long long)s.generated.load(),
      (unsigned long long)s.spatial.load(), (unsigned long long)s.resets.load(),
      (unsigned long long)s.busy.load(), (unsigned long long)s.failed.load(),
      s.gpuMs.load(), (unsigned long long)s.coverageFrameID.load(),
      s.depthCoverage[0].load(), s.depthCoverage[1].load(),
      s.motionCoverage[0].load(), s.motionCoverage[1].load(),
      (unsigned long long)s.trackedPoseJobs.load());
  return 1;
}
