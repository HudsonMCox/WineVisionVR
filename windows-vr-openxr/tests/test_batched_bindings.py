#!/usr/bin/env python3
"""Execute the production encoder setup list with the real wire structures."""
import argparse
from pathlib import Path
import subprocess,tempfile
p=argparse.ArgumentParser();p.add_argument('source',type=Path);a=p.parse_args()
s=(a.source/'src/dxmt/dxmt_context.cpp').read_text()
start=s.index('      std::array<wmtcmd_render_setbuffer, 7> setup{};')
end=s.index('      if (data->use_geometry || data->use_tessellation)',start)
setup=s[start:end]
code=r'''
#include "winemetal.h"
#include <array>
#include <cassert>
#include <cstdio>
constexpr uint8_t SM50_BINDING_INDEX_VERTEX_BUFFER=16,SM50_BINDING_INDEX_CONSTANT_BUFFER=17,SM50_BINDING_INDEX_ARGUMENT_TABLE=18,SM50_BINDING_INDEX_STREAM_OUTPUT0=19;
struct Data{bool use_emulated_so=false;};
struct Encoder{
 unsigned calls=0,count=0;bool identity=false;
 void encodeCommands(const wmtcmd_render_nop* head){
  ++calls;auto p=reinterpret_cast<const wmtcmd_render_setbuffer*>(head);
  while(p){assert(count<7);assert(p->offset==0);
   if(p->type==WMTRenderCommandSetFragmentBuffer&&p->index==28){assert(p->buffer==99);identity=true;}
   else assert(p->buffer==42);
   ++count;p=reinterpret_cast<const wmtcmd_render_setbuffer*>(([&]{auto next=p->next;return next.get();})());
  }
 }
};
void run(bool so,bool uniformPass,obj_handle_t uniformFoveationBuffer){
 Data d{so};Data*data=&d;obj_handle_t gpu_buffer_=42;Encoder encoder;
'''+setup+r'''
 assert(encoder.calls==1);assert(encoder.count==5+unsigned(so)+unsigned(uniformPass&&uniformFoveationBuffer));
 assert(encoder.identity==bool(uniformPass&&uniformFoveationBuffer));
}
int main(){for(bool so:{false,true})for(bool uniform:{false,true})for(obj_handle_t buffer:{0ull,99ull})run(so,uniform,buffer);
 puts("PASS: production binding batch uses one dispatch, fits seven commands, terminates links, preserves map/stream-output bindings and uniform/foveated/legacy cases");}
'''
with tempfile.TemporaryDirectory(prefix='wvr-bindings-') as tmp:
 w=Path(tmp);(w/'probe.cpp').write_text(code)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2','-fsanitize=address,undefined','-I',str(a.source/'src/winemetal'),str(w/'probe.cpp'),'-o',str(w/'probe')],check=True)
 subprocess.run([str(w/'probe')],check=True)
