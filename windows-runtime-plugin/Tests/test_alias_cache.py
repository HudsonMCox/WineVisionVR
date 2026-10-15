#!/usr/bin/env python3
"""Execute the production AArch64 lookup assembly as a native arithmetic probe."""
from pathlib import Path
import re, subprocess, tempfile, sys
patched = Path(sys.argv[1]).read_text()
legacy = Path(sys.argv[2]).read_text()
def emit(source,name):
    start=source.index('ExitFunctionSuspendResumePoint:')
    start=source.index('  // ',start)
    end=source.index('ios_ec_xlate_done:',start)+len('ios_ec_xlate_done:')
    body=source[start:end]
    body=re.sub(r'\bios_ec_',name+'_',body)
    body=re.sub(r'adrp (x\d+), (IosAlias\w+)',r'adrp \1, _\2@PAGE',body)
    body=re.sub(r'#:lo12:(IosAlias\w+)',r'_\1@PAGEOFF',body)
    return f'.text\n.p2align 2\n.globl _{name}\n_{name}:\n stp x23, x30, [sp, #-16]!\n mov x9, x0\n'+body+f'\n mov x0, x9\n ldp x23, x30, [sp], #16\n ret\n'
cpp=r'''
#include <cstdint>
#include <cstdio>
#include <cassert>
#include <chrono>
#include <vector>
#include <thread>
extern "C" {
struct Entry {uint64_t pe,jit,size,padding;};
Entry IosAliasEntries[256]{};int IosAliasCount=180;
Entry* IosAliasLast=nullptr;
Entry* IosAliasForwardCache[256]{};Entry* IosAliasReverseCache[256]{};
uint64_t cachedLookup(uint64_t);uint64_t legacyLookup(uint64_t);
}
uint64_t expected(uint64_t address){for(int n=IosAliasCount-1;n>=0;--n){auto&e=IosAliasEntries[n];if(address-e.pe<e.size)return e.jit+(address-e.pe);}return address;}
void check(uint64_t address){assert(cachedLookup(address)==expected(address));}
int main(){
 for(int n=0;n<IosAliasCount;n++)IosAliasEntries[n]={0x7300000000ull+n*0x110000ull,0x7000000000ull+n*0x120000ull,0x100000,0};
 for(int pass=0;pass<3;pass++)for(int n=0;n<IosAliasCount;n++){auto&e=IosAliasEntries[n];check(e.pe);check(e.pe+e.size-1);check(e.pe+e.size);check(e.jit);check(e.jit+e.size-1);}
 check(0);check(0xffffffffffffffffull);check(0x123456789);
 // Retire a warmed entry, then reuse it at a different PE/JIT address.
 auto&e=IosAliasEntries[9];auto oldPe=e.pe,oldJit=e.jit;check(oldPe+16);check(oldJit+16);e.size=0;check(oldPe+16);check(oldJit+16);
 e.pe=0x7600000000ull;e.jit=0x7100000000ull;e.size=0x10000;check(oldPe+16);check(oldJit+16);check(e.pe+16);check(e.jit+16);
 std::vector<uint64_t> workload;
 for(int n=0;n<32;n++){auto&v=IosAliasEntries[n+30];workload.push_back(v.pe+0x1234);workload.push_back(v.jit+0x3456);}
 auto bench=[&](auto fn){auto begin=std::chrono::steady_clock::now();uint64_t result=0;for(int round=0;round<100000;round++)for(auto address:workload)result+=fn(address);auto ns=std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-begin).count();printf("checksum=%llu ",static_cast<unsigned long long>(result));return double(ns)/(100000*workload.size());};
 auto before=bench(legacyLookup);printf("legacy ns/lookup=%.2f\n",before);auto after=bench(cachedLookup);printf("cached ns/lookup=%.2f speedup=%.2fx\n",after,before/after);
 std::vector<std::thread> threads;for(int t=0;t<4;t++)threads.emplace_back([&]{for(int round=0;round<1000;round++)for(auto address:workload)check(address);});for(auto&t:threads)t.join();
 puts("PASS: production assembly boundaries, unknown targets, retirement/reuse, both address directions and concurrent immutable-table lookups");
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-alias-') as work:
    work=Path(work);(work/'lookup.S').write_text(emit(patched,'cachedLookup')+emit(legacy,'legacyLookup'));(work/'test.cpp').write_text(cpp)
    subprocess.run(['clang++','-O2','-std=c++20',str(work/'lookup.S'),str(work/'test.cpp'),'-o',str(work/'test')],check=True)
    subprocess.run([str(work/'test')],check=True)
