#!/usr/bin/env python3
"""Exercise production-generated vtable return shims without Wine or a game."""
import ast
import io
from pathlib import Path
import subprocess
import tempfile
import argparse
p=argparse.ArgumentParser();p.add_argument('source',type=Path);a=p.parse_args()
source=(a.source/'scripts/stubs/codegen.py').read_text()
tree=ast.parse(source)
ns={'InterfaceSpec':object,'InterfaceDef':object,'List':list}
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef)],type_ignores=[]),'codegen.py','exec'),ns)
class Arg:
 type='int';name='eye'
class Function:
 user_implemented=False
 def __init__(self,name,ret):self.name=name;self.return_type=ret;self.args=[Arg()]
 def args_str(self):return 'int eye'
 def args_names(self):return 'eye'
class Version:
 version='001'
 functions=[Function('MatrixValue','Matrix'),Function('SmallValue','Small'),Function('Scalar','int'),Function('Pointer','const char*'),Function('Nothing','void')]
 def proxy_class_name(self):return 'CVRFixture_001'
 def namespace(self):return 'vr'
 def basename(self):return 'BaseFixture'
 def varname(self):return 'Fixture'
 def getter_name(self):return 'Fixture'
class Spec:
 name='Fixture';versions=[Version()]
out=io.StringIO();ns['write_stubs'](out,Spec())
# The host uses a different native ABI. Force only the generated platform guard
# to exercise explicit (this,result,args) calls through the exported vtable.
generated='\n'.join(x for x in out.getvalue().splitlines() if not x.startswith('#include'))
generated=generated.replace('#if defined(__MINGW32__) && defined(__x86_64__)','#if 1')
code=r'''
#include <memory>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include "Win64ReturnABI.h"
#define OPENVR_FNTABLE_CALLTYPE
#define OOVR_LOG(...) ((void)0)
struct Config{bool LogAllOpenVRCalls(){return false;}}oovr_global_configuration;
struct Matrix{float m[12];};struct Small{uint64_t value;};
namespace vr {struct API{virtual Matrix MatrixValue(int)=0;virtual Small SmallValue(int)=0;virtual int Scalar(int)=0;virtual const char* Pointer(int)=0;virtual void Nothing(int)=0;};}
struct BaseFixture{
 Matrix MatrixValue(int eye){Matrix x;for(int i=0;i<12;++i)x.m[i]=float(100*eye+i);return x;}
 Small SmallValue(int eye){return {uint64_t(eye+7)};}int Scalar(int eye){return eye+3;}
 const char* Pointer(int){return "ok";}void Nothing(int){}
};
struct Common{virtual ~Common(){} virtual void** _GetStatFuncList()=0;virtual void Delete()=0;};
struct CVRFixture_001:vr::API,Common{
 const std::shared_ptr<BaseFixture> base;
 CVRFixture_001();void** _GetStatFuncList()override;void Delete()override;
 Matrix MatrixValue(int)override;Small SmallValue(int)override;int Scalar(int)override;const char* Pointer(int)override;void Nothing(int)override;
};
'''+generated+r'''
int main(){
 for(int eye=0;eye<2;++eye){
  auto* object=new CVRFixture_001();auto table=*reinterpret_cast<void***>(object);
  struct Guard{uint64_t before=0x123456789abcdef0;Matrix result;uint64_t after=0xfedcba9876543210;}guard;
  auto originalVtable=table;
  using MSVCReturn=Matrix*(*)(CVRFixture_001*,Matrix*,int);
  assert(reinterpret_cast<MSVCReturn>(table[0])(object,&guard.result,eye)==&guard.result);
  for(int i=0;i<12;++i)assert(guard.result.m[i]==float(eye*100+i));
  assert(guard.before==0x123456789abcdef0&&guard.after==0xfedcba9876543210);
  assert(*reinterpret_cast<void***>(object)==originalVtable);
  assert(object->SmallValue(eye).value==uint64_t(eye+7));assert(object->Scalar(eye)==eye+3);
  assert(object->Pointer(eye)[0]=='o');object->Nothing(eye);
  auto functions=object->_GetStatFuncList();auto value=reinterpret_cast<Matrix(*)(int)>(functions[0])(eye);
  assert(value.m[11]==float(100*eye+11));object->Delete();
 }
 puts("PASS: generated MSVC-order aggregate returns, canaries/vtable preserved, scalar/small/pointer/void ABI unchanged, native FnTable and deletion work");
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-openvr-abi-') as temp:
 w=Path(temp);(w/'probe.cpp').write_text(code)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O1','-g','-fsanitize=undefined','-fno-sanitize=function','-I',str(a.source/'OpenOVR/Misc'),str(w/'probe.cpp'),'-o',str(w/'probe')],check=True)
 subprocess.run([str(w/'probe')],check=True)
