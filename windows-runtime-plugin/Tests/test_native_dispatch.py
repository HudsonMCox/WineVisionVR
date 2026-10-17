#!/usr/bin/env python3
"""Execute the actual native-dispatch assembly and alias helpers on ARM64 Mac."""
from pathlib import Path
import re,subprocess,tempfile,argparse
root=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--fex',type=Path,default=root/'.build-fex-cache/FEX');args=p.parse_args()
assembly=(args.fex/'Source/Windows/ARM64EC/Module.S').read_text()
source=(args.fex/'Source/Windows/ARM64EC/IosJitAlias.cpp').read_text()
baseline=(root/'third-party/madeira/FEX/Source/Windows/ARM64EC/IosJitAlias.cpp').read_text()
def function(text,name):
 a=text.index('uint64_t '+name+'(');b=text.index('{',a)+1;depth=1;end=b
 while depth:depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[a:end]
def apple(body,prefix):
 body=re.sub(r'\bios_ffs_',prefix+'_',body)
 body=re.sub(r'adrp (x\d+), (IosAlias\w+)',r'adrp \1, _\2@PAGE',body)
 return re.sub(r'#:lo12:(IosAlias\w+)',r'_\1@PAGEOFF',body)
a=assembly.index('  stp x4, x9, [sp, #-32]!',assembly.index('ExitToX64:'));b=assembly.index('ios_ffs_xlate_done:',a)+len('ios_ffs_xlate_done:')
c=assembly.index('ios_ffs_native_select:',b);d=assembly.index('  ldp x4, x9, [sp], #32',c)
assert 'tbz x16, #0, ios_ffs_reject' in assembly[b:c]
assert assembly.count('ldp x4, x9, [sp], #32')==2
code='.text\n.p2align 2\n.globl _ffsLookup\n_ffsLookup:\n stp x23, x30, [sp, #-16]!\n mov x17, x0\n'+apple(assembly[a:b]+assembly[c:d],'ffs')+'\n ldp x4, x9, [sp], #32\n mov x0, x17\n ldp x23, x30, [sp], #16\n ret\n'
legacy=function(baseline,'IosJitTranslate').replace('IosJitTranslate(', 'LegacyForward(')+'\n'+function(baseline,'IosJitReverseTranslate').replace('IosJitReverseTranslate(', 'LegacyReverse(')
fixture=r'''
#include <cstdint>
#include <cassert>
#include <cstdio>
#include <chrono>
#include <vector>
#include <random>
#include <thread>
extern "C" {
struct IosAliasEntry {uint64_t PeBase,JitBase,Size,Padding;};
IosAliasEntry IosAliasEntries[256]{};volatile int IosAliasCount=180;
IosAliasEntry* volatile IosAliasLast=nullptr;
IosAliasEntry* volatile IosAliasForwardCache[256]{};
IosAliasEntry* volatile IosAliasReverseCache[256]{};
uint64_t ffsLookup(uint64_t);
}
auto* g_Entries=IosAliasEntries;volatile int& g_EntryCount=IosAliasCount;
'''+function(source,'IosJitTranslate')+'\n'+function(source,'IosJitReverseTranslate')+'\n'+legacy+r'''
uint64_t reference(uint64_t a,bool reverse){for(int i=IosAliasCount;i-->0;){auto&e=IosAliasEntries[i];auto base=reverse?e.JitBase:e.PeBase;if(a-base<e.Size)return (reverse?e.PeBase:e.JitBase)+(a-base);}return a;}
uint64_t nativeReference(uint64_t a){if(reference(a,true)!=a)return a;return reference(a,false);}
void check(uint64_t a){assert(IosJitTranslate(a)==reference(a,false));assert(IosJitReverseTranslate(a)==reference(a,true));assert(ffsLookup(a)==nativeReference(a));}
int main(){
 for(int i=0;i<IosAliasCount;++i)IosAliasEntries[i]={0x7300000000ull+i*0x110000ull,0x7000000000ull+i*0x120000ull,0x100000,0};
 for(int pass=0;pass<3;++pass)for(auto&e:IosAliasEntries){check(e.PeBase);check(e.PeBase+e.Size-1);check(e.PeBase+e.Size);check(e.JitBase);check(e.JitBase+e.Size-1);}
 check(0);check(UINT64_MAX);check(0x123456789);
 auto&e=IosAliasEntries[9];auto oldPe=e.PeBase,oldJit=e.JitBase;check(oldPe+16);check(oldJit+16);e.Size=0;check(oldPe+16);check(oldJit+16);
 e.PeBase=0x7600000000ull;e.JitBase=0x7100000000ull;e.Size=0x10000;check(oldPe+16);check(oldJit+16);check(e.PeBase+16);check(e.JitBase+16);
 std::mt19937_64 random(14);for(int i=0;i<20000;++i){auto&e=IosAliasEntries[random()%180];check(e.PeBase+(random()%0x120000));check(e.JitBase+(random()%0x120000));}
 std::vector<uint64_t> workload;for(int i=30;i<62;++i){workload.push_back(IosAliasEntries[i].PeBase+0x1234);workload.push_back(IosAliasEntries[i].JitBase+0x3456);}
 auto bench=[&](auto fn){uint64_t sum=0;auto begin=std::chrono::steady_clock::now();for(int r=0;r<20000;++r)for(auto a:workload)sum+=fn(a);auto ns=std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-begin).count();printf("checksum=%llu ",(unsigned long long)sum);return double(ns)/(20000*workload.size());};
 auto before=bench(LegacyForward);printf("baseline native helper, mixed addresses %.2f ns/lookup\n",before);
 auto after=bench(IosJitTranslate);printf("cached native helper, mixed addresses %.2f ns/lookup (%.2fx microbenchmark)\n",after,before/after);
 auto all=workload;workload.clear();for(int i=30;i<62;++i)workload.push_back(IosAliasEntries[i].PeBase+0x1234);
 before=bench(LegacyForward);after=bench(IosJitTranslate);printf("mapped PE targets: baseline %.2f cached %.2f ns/lookup (%.2fx microbenchmark)\n",before,after,before/after);
 workload.clear();for(int i=30;i<62;++i)workload.push_back(IosAliasEntries[i].JitBase+0x3456);
 before=bench(LegacyReverse);after=bench(IosJitReverseTranslate);printf("mapped executable targets: baseline %.2f cached %.2f ns/lookup (%.2fx microbenchmark)\n",before,after,before/after);workload=all;
 std::vector<std::thread> threads;for(int i=0;i<4;++i)threads.emplace_back([&]{for(int r=0;r<100;++r)for(auto a:workload)check(a);});for(auto&t:threads)t.join();
 puts("PASS: production FFS normalization/branch selection and native helpers, boundaries, unknown targets, retirement/reuse, 40000 random probes and concurrent immutable lookups; EC bitmap validation remains before native selection");
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-dispatch-') as tmp:
 w=Path(tmp);(w/'lookup.S').write_text(code);(w/'probe.cpp').write_text(fixture)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2',str(w/'lookup.S'),str(w/'probe.cpp'),'-o',str(w/'probe')],check=True)
 subprocess.run([str(w/'probe')],check=True,timeout=30)
