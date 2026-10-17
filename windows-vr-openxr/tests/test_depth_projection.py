#!/usr/bin/env python3
"""Execute the runtime's real projection helper against OpenXR depth conventions."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'windows-vr-openxr/src/WindowsVROpenXR.cpp').read_text()
a=s.index('bool ReconstructionProjection(');b=s.index('\nXrResult XRAPI_CALL EndFrame(',a)
code=r'''
#include <openxr/openxr.h>
#include <cmath>
#include <algorithm>
#include <cassert>
#include <limits>
#include <cstdio>
'''+s[a:b]+r'''
float depth(const float*m,float distance){return (-distance*m[10]+m[14])/distance;}
int main(){
 XrFovf f{-.8f,.7f,.9f,-.6f};float p[16];
 for(auto nearZ:{.01f,.1f,10.f})for(auto farZ:{.5f,100.f,1000.f}){
  assert(ReconstructionProjection(f,nearZ,farZ,p));assert(std::fabs(depth(p,nearZ))<.00001f);assert(std::fabs(depth(p,farZ)-1)<.00001f);
  float left=std::tan(f.angleLeft),right=std::tan(f.angleRight);
  assert(std::fabs(p[0]*left-p[8]+1)<.00001f);assert(std::fabs(p[0]*right-p[8]-1)<.00001f);
 }
 float infinity=std::numeric_limits<float>::infinity();
 assert(ReconstructionProjection(f,.1f,infinity,p)&&std::fabs(depth(p,.1f))<.00001f&&std::fabs(depth(p,1e9)-1)<.00001f);
 assert(ReconstructionProjection(f,infinity,.1f,p)&&std::fabs(depth(p,.1f)-1)<.00001f&&depth(p,1e9)<.00001f);
 assert(!ReconstructionProjection(f,0,100,p));assert(!ReconstructionProjection(f,.1f,.1f,p));assert(!ReconstructionProjection(f,infinity,infinity,p));assert(!ReconstructionProjection(f,NAN,1,p));
 f.angleLeft=f.angleRight;assert(!ReconstructionProjection(f,.1f,100,p));
 puts("PASS: production asymmetric projection, forward/reversed depth, near/far infinite planes, and malformed ranges");
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-depth-') as tmp:
 p=Path(tmp);(p/'probe.cpp').write_text(code)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2','-fsanitize=undefined,bounds','-I',str(root/'third-party/openxr/include'),str(p/'probe.cpp'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
