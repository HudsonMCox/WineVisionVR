#!/usr/bin/env python3
"""Run production GetData and event-query methods with only device plumbing stubbed."""
import argparse
from pathlib import Path
import subprocess
import tempfile
p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('--baseline',action='store_true');p.add_argument('--completed-cache',action='store_true');a=p.parse_args()
s=(a.source/'src/d3d11/d3d11_query.hpp').read_text()
enums=s[s.index('enum class QueryState'):s.index('template <typename DataType>\nclass MTLD3D11EventQueryImpl')]
methods=s[s.index('  void Issue(uint64_t current_seq_id) override'):s.index('class MTLD3D11OcclusionQuery')]
c=(a.source/'src/d3d11/d3d11_context_imm.cpp').read_text()
start=c.index('  HRESULT\n  STDMETHODCALLTYPE\n  GetData(');brace=c.index('{',start);end=brace+1;depth=1
while depth:
 depth+=(c[end]=='{')-(c[end]=='}');end+=1
get_data=c[start:end].replace(" override", "").replace("std::this_thread::yield();", "++yieldCalls;")
code=r'''
#include <cstdint>
#include <cstddef>
#include <cassert>
#include <cstdio>
#include <thread>
static uint64_t yieldCalls=0;
using UINT=unsigned;using UINT64=uint64_t;using BOOL=int;using HRESULT=int;
#define STDMETHODCALLTYPE
#define WARN(...) ((void)0)
#define ERR(...) ((void)0)
constexpr HRESULT S_OK=0,S_FALSE=1,E_INVALIDARG=-1,E_FAIL=-2,DXGI_ERROR_INVALID_CALL=-3;
constexpr UINT D3D11_QUERY_EVENT=0,D3D11_QUERY_OCCLUSION=1,D3D11_QUERY_TIMESTAMP=2,D3D11_QUERY_TIMESTAMP_DISJOINT=3,D3D11_QUERY_PIPELINE_STATISTICS=4,D3D11_QUERY_OCCLUSION_PREDICATE=5;
constexpr UINT D3D11_ASYNC_GETDATA_DONOTFLUSH=1;constexpr BOOL FALSE=0;
struct D3D11_QUERY_DATA_PIPELINE_STATISTICS{UINT64 counters[11];};
struct D3D11_QUERY_DESC{UINT Query;};struct D3D11_QUERY_DATA_TIMESTAMP_DISJOINT{UINT64 Frequency;BOOL Disjoint;};
struct ID3D11Asynchronous{virtual UINT GetDataSize()=0;};
struct ID3D11Query:ID3D11Asynchronous{virtual void GetDesc(D3D11_QUERY_DESC*)=0;};
struct ID3D11Query1:ID3D11Query{};
''' + enums + r'''
class EventQuery:public MTLD3D11EventQuery{public:
 UINT type=D3D11_QUERY_EVENT;
 UINT GetDataSize()override{return type==D3D11_QUERY_TIMESTAMP_DISJOINT?sizeof(D3D11_QUERY_DATA_TIMESTAMP_DISJOINT):sizeof(BOOL);}
 void GetDesc(D3D11_QUERY_DESC* d)override{d->Query=type;}
''' + methods + r'''
struct MTLD3D11OcclusionQuery:ID3D11Query1{virtual HRESULT GetData(void*)=0;};
struct MTLD3D11TimestampQuery:ID3D11Query1{virtual HRESULT GetData(void*)=0;};
struct Context{struct Stats{uint64_t event_stall=0;};struct Queue{
 uint64_t signal=0,reads=0;Stats stats;
 uint64_t SignaledEventSeqId(){++reads;return signal;}
 Stats& CurrentFrameStatistics(){return stats;}
}cmd_queue;uint64_t flushes=0;void Flush(){++flushes;}
''' +get_data+r'''
};
int main(){
 EventQuery q;Context c;q.Issue(10);
 // The actual GetData body must still read exact GPU progress on every poll.
 for(unsigned n=0;n<250000;++n)assert(c.GetData(&q,nullptr,0,0)==S_FALSE);
 assert(c.cmd_queue.reads==250000);
 assert(yieldCalls==(BASELINE?0:7811));
 const uint64_t expected=BASELINE?250000:1;assert(c.flushes==expected);
 std::printf("pending polls=250000 exact GPU reads=%llu Flush calls=%llu\n",(unsigned long long)c.cmd_queue.reads,(unsigned long long)c.flushes);
 // Signal is observable before the containing command chunk completes.
 bool chunkCompleted=false;c.cmd_queue.signal=10;assert(!chunkCompleted);
 assert(c.GetData(&q,nullptr,0,0)==S_OK);assert(c.flushes==expected);
 // Once positively signaled, completed reads can reuse that exact answer.
 const auto completedReads=c.cmd_queue.reads;
 for(unsigned n=0;n<10000;++n)assert(c.GetData(&q,nullptr,0,0)==S_OK);
 assert(c.cmd_queue.reads==completedReads+(COMPLETED_CACHE?0:10000));
 std::printf("completed queries=10000 extra GPU reads=%llu\n",(unsigned long long)(c.cmd_queue.reads-completedReads));
 // A new issue must submit independently; no per-object permanent latch.
 q.Issue(11);assert(c.GetData(&q,nullptr,0,0)==S_FALSE);assert(c.flushes==expected+1);
 c.cmd_queue.signal=11;BOOL ready=0;assert(c.GetData(&q,&ready,sizeof ready,0)==S_OK&&ready);
 // DONOTFLUSH preserves the existing bounded stall/forced submission policy.
 EventQuery deferred;Context d;deferred.Issue(20);
 for(unsigned n=0;n<64;++n)assert(d.GetData(&deferred,nullptr,0,1)==S_FALSE);
 assert(d.flushes==0);assert(d.GetData(&deferred,nullptr,0,1)==S_FALSE);assert(d.flushes==1);
 for(unsigned n=0;n<100;++n)assert(d.GetData(&deferred,nullptr,0,1)==S_FALSE);
 assert(d.flushes==(BASELINE?101:1));
 // Timestamp-disjoint queries share the event submission lifecycle.
 EventQuery disjoint;disjoint.type=D3D11_QUERY_TIMESTAMP_DISJOINT;disjoint.Issue(30);Context t;
 for(unsigned n=0;n<10;++n)assert(t.GetData(&disjoint,nullptr,0,0)==S_FALSE);
 assert(t.flushes==(BASELINE?10:1));t.cmd_queue.signal=30;
 D3D11_QUERY_DATA_TIMESTAMP_DISJOINT out{};assert(t.GetData(&disjoint,&out,sizeof out,0)==S_OK);
 assert(out.Frequency==1000000000&&!out.Disjoint);
 EventQuery invalid;Context bad;assert(bad.GetData(&invalid,nullptr,0,0)==DXGI_ERROR_INVALID_CALL);assert(bad.flushes==0);
 std::puts("PASS: production GetData, per-issue flushes, reissue, DONOTFLUSH, disjoint queries and exact early signal progress");
}
'''
with tempfile.TemporaryDirectory(prefix='winevision-event-flush-') as t:
 cpp=Path(t)/'test.cpp';exe=Path(t)/'test';cpp.write_text(code)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2',f'-DBASELINE={int(a.baseline)}',f'-DCOMPLETED_CACHE={int(a.completed_cache)}',str(cpp),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True,timeout=30)
