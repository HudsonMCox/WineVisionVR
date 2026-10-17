#!/usr/bin/env python3
"""Compile the production pass/shader gates; unsafe combinations must stay uniform."""
import argparse
from pathlib import Path
import subprocess
import tempfile
p=argparse.ArgumentParser();p.add_argument('source',type=Path);a=p.parse_args()
c=(a.source/'src/dxmt/dxmt_context.cpp').read_text()
gate=c.split('bool eligible = ',1)[1].split(';',1)[0]
s=(a.source/'src/d3d11/d3d11_context_impl.cpp').read_text()
shader=s.split('const bool foveationSafe = ',1)[1].split(';',1)[0]
loop=c[c.index('      for (unsigned i=1; i<data->render_target_count; ++i) {'):c.index('      // A failed early probe')]
code=r'''
#include <cassert>
struct Attachment { unsigned texture=1,store_action=1,resolve_texture=0,level=0,depth_plane=0; };
struct Info { Attachment colors[8],stencil,depth; unsigned default_raster_sample_count=1,render_target_array_length=1; Info(){stencil.texture=0;} };
struct Data { bool foveation_safe=true,last_pso=true,use_visibility_result=false,use_geometry=false,use_tessellation=false,use_emulated_so=false; unsigned render_target_count=1, foveation_draw_calls=1; };
constexpr unsigned WMTStoreActionStore=1;
bool eligible(Data *data,Info render_pass_info){const auto &color=render_pass_info.colors[0];bool eligible='''+gate+r''';'''+loop+r'''return eligible;}
struct Reflection { unsigned UAVSlotMask=0;struct { bool HasCoverageOutput=false; } PixelShader; };
struct Shader { bool safe=true; Reflection r;bool allowsFoveatedRaster(){return safe;} Reflection &reflection(){return r;} };
struct Desc { bool GeometryShader=false; };
bool safe(Shader *ps,Shader *vs,Desc pipelineDesc){return '''+shader+r''';}
int main(){
 Data d;Info i;assert(eligible(&d,i));
 for(unsigned n=0;n<6;++n){d={};bool *flags[]={&d.foveation_safe,&d.last_pso,&d.use_visibility_result,&d.use_geometry,&d.use_tessellation,&d.use_emulated_so};*flags[n]=!*flags[n];assert(!eligible(&d,i));}
 d={};d.foveation_draw_calls=0;assert(!eligible(&d,i));d={};d.render_target_count=2;assert(eligible(&d,i));d.render_target_count=8;assert(eligible(&d,i));d.render_target_count=9;assert(!eligible(&d,i));d={};
 for(unsigned n=0;n<11;++n){i={};unsigned *values[]={&i.stencil.level,&i.default_raster_sample_count,&i.render_target_array_length,&i.colors[0].texture,&i.colors[0].store_action,&i.colors[0].resolve_texture,&i.colors[0].level,&i.colors[0].depth_plane,&i.depth.level,&i.depth.depth_plane,&d.render_target_count};*values[n]=*values[n]?0:1;assert(!eligible(&d,i));}d={};
 Shader ps,vs;Desc desc;assert(safe(&ps,&vs,desc));assert(!safe(nullptr,&vs,desc));assert(!safe(&ps,nullptr,desc));
 ps.safe=false;assert(!safe(&ps,&vs,desc));ps.safe=true;ps.r.UAVSlotMask=1;assert(!safe(&ps,&vs,desc));ps.r.UAVSlotMask=0;
 vs.r.UAVSlotMask=1;assert(!safe(&ps,&vs,desc));vs.r.UAVSlotMask=0;ps.r.PixelShader.HasCoverageOutput=true;assert(!safe(&ps,&vs,desc));ps.r.PixelShader.HasCoverageOutput=false;desc.GeometryShader=true;assert(!safe(&ps,&vs,desc));
}
'''
# Complement executable gate coverage with invariants that span command encoding.
assert 'r1->foveation_draw_calls += r0->foveation_draw_calls;' in c
assert 'r1->foveation_safe = r0->foveation_safe && r1->foveation_safe' in c
begin=c.index('encoder.encodeCommands(&data->cmd_head);')
resolve=c.index('foveation.operation = 2;',begin)
assert begin<resolve<c.index('data->fence_update_vertex.forEach(',resolve)<c.index('encoder.endEncoding();',resolve)
cache=(a.source/'src/d3d11/d3d11_pipeline_cache.cpp').read_text()
assert 'parameters[i].SystemValue != microsoft::D3D10_SB_NAME_UNDEFINED' in cache
assert 'bool foveation_safe_ = false;' in cache
assert 'parameters[i].SystemValue != microsoft::D3D10_SB_NAME_POSITION' in cache
assert c.index('data->fence_wait.forEach(',c.index('WVRGuestFoveationPassV1 foveation')) < c.index('foveation.operation=4;') < c.index('std::array<wmtcmd_render_setbuffer, 7> setup',c.index('WVRGuestFoveationPassV1 foveation'))
with tempfile.TemporaryDirectory(prefix='winevision-foveation-gates-') as tmp:
 cpp=Path(tmp)/'probe.cpp';exe=Path(tmp)/'probe';cpp.write_text(code)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20',str(cpp),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
print('PASS: production eligibility/shader gates reject unsafe passes; merged safety and resolve-before-fence ordering retained')
