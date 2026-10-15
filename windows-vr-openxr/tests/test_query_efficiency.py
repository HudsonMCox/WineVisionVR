#!/usr/bin/env python3
"""Exercise production query lifecycles and benchmark readback/polling costs.

Only D3D device/COM plumbing and logging are stubbed. Rc and query methods are
production code. --baseline runs the same correctness suite against pre-0015
sources and reports its allocation cost without requiring the optimization.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path)
parser.add_argument('--baseline', action='store_true')
parser.add_argument('--tsan', action='store_true')
parser.add_argument('--asan', action='store_true')
args = parser.parse_args()
source = args.source.resolve()
header = (source / 'src/dxmt/dxmt_occlusion_query.hpp').read_text()
visibility = header.split('class VisibilityResultQuery {', 1)[1].split('class VisibilityResultReadback', 1)[0]
timestamp = header.split('class TimestampQuery {', 1)[1].split('using TimestampQueryList', 1)[0]
queries = (source / 'src/d3d11/d3d11_query.cpp').read_text()
occlusion = queries[queries.index('class OcclusionQuery :'):queries.index('\nHRESULT\nCreateOcclusionQuery')]
timestamp_impl = queries[queries.index('class MTLD3D11TimestampQueryImpl :'):queries.index('\nHRESULT\nCreateTimestampQuery')]
code = r'''
#include <atomic>
#include <cassert>
#include <chrono>
#include <concepts>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <new>
#include <thread>
#include <vector>
static std::atomic<uint64_t> allocations{0};
void* operator new(size_t size) {
  allocations.fetch_add(1, std::memory_order_relaxed);
  if (void* p = std::malloc(size ? size : 1)) return p;
  throw std::bad_alloc();
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, size_t) noexcept { std::free(p); }
#include "rc/util_rc_ptr.hpp"
using dxmt::Rc;
using UINT = unsigned;
using UINT64 = uint64_t;
using BOOL = int;
using HRESULT = int;
#define STDMETHODCALLTYPE
#define WARN(...) ((void)0)
constexpr HRESULT S_OK=0, S_FALSE=1, DXGI_ERROR_INVALID_CALL=-1;
constexpr unsigned D3D11_QUERY_OCCLUSION=1, D3D11_QUERY_OCCLUSION_PREDICATE=5;
struct D3D11_QUERY_DESC1 { unsigned Query; };
struct MTLD3D11Device {};
enum class QueryState {Building, Issued, Signaled, Undefined};
''' + 'class VisibilityResultQuery {' + visibility + 'class TimestampQuery {' + timestamp + r'''
struct MTLD3D11OcclusionQuery {
  virtual ~MTLD3D11OcclusionQuery() = default;
  virtual UINT GetDataSize()=0;
  virtual HRESULT GetData(void*)=0;
  virtual VisibilityResultQuery* Begin()=0;
  virtual VisibilityResultQuery* End()=0;
  virtual void DoDeferredQuery(VisibilityResultQuery*)=0;
};
struct MTLD3D11TimestampQuery {
  virtual ~MTLD3D11TimestampQuery() = default;
  virtual UINT GetDataSize()=0;
  virtual HRESULT GetData(void*)=0;
  virtual TimestampQuery* End()=0;
};
template<typename T> struct MTLD3DQueryBase : T {
  D3D11_QUERY_DESC1 desc_;
  MTLD3DQueryBase(MTLD3D11Device*, const D3D11_QUERY_DESC1* desc):desc_(*desc){}
};
''' + occlusion + timestamp_impl + r'''
static void checkOcclusion(unsigned type) {
  MTLD3D11Device device;
  D3D11_QUERY_DESC1 desc{type};
  OcclusionQuery object(&device, &desc);
  MTLD3D11OcclusionQuery& query=object;
  uint64_t result=99;
  auto read=[&] {
    if(type==D3D11_QUERY_OCCLUSION_PREDICATE) {
      BOOL predicate=-1; auto hr=query.GetData(&predicate);
      if(hr==S_OK) result=predicate;
      return hr;
    }
    return query.GetData(&result);
  };
  assert(read()==S_OK && result==0); // never issued
  auto sample=query.Begin(); assert(sample); sample->begin(10,0);
  assert(read()==DXGI_ERROR_INVALID_CALL);
  assert(query.End()==sample); sample->end(11,0);
  assert(read()==S_FALSE);
  const uint64_t values[]{7,11,13};
  sample->issue(10,values,3);
  assert(read()==S_FALSE); // first chunk does not complete final empty tail
  sample->issue(11,nullptr,0);
  assert(read()==S_OK && result==(type==D3D11_QUERY_OCCLUSION_PREDICATE ? 1u : 31u));
  // Cached reads preserve the result and do not allocate after completion.
  auto before=allocations.load();
  for(unsigned i=0;i<10000;++i) assert(read()==S_OK);
  auto extra=allocations.load()-before;
#ifndef BASELINE
  assert(extra==0);
#endif
  printf("occlusion type=%u cached-read allocations=%llu\n",type,(unsigned long long)extra);
  // The next issue is fresh and cannot observe the previous generation.
  auto next=query.Begin(); assert(next); next->begin(20,0);
  assert(query.End()==next); next->end(20,1);
  assert(read()==S_FALSE);
  const uint64_t zero[]{0}; next->issue(20,zero,1);
  assert(read()==S_OK && result==0);
  // Reissue before observing a result discards only that query's ownership;
  // the finish thread can still retire an old result through its retained Rc.
  Rc<VisibilityResultQuery> old=query.Begin(); old->begin(30,0);
  query.End()->end(30,1);
  auto replacement=query.Begin(); replacement->begin(31,0);
  query.End()->end(31,1);
  old->issue(30,values,1); assert(read()==S_FALSE);
  replacement->issue(31,zero,1); assert(read()==S_OK && result==0);
  // Deferred command lists publish their own retained result.
  Rc<VisibilityResultQuery> deferred=new VisibilityResultQuery();
  deferred->begin(40,1); deferred->end(40,3);
  query.DoDeferredQuery(deferred.ptr()); assert(read()==S_FALSE);
  deferred->issue(40,values,3);
  assert(read()==S_OK && result==(type==D3D11_QUERY_OCCLUSION_PREDICATE ? 1u : 24u));
}
int main() {
  checkOcclusion(D3D11_QUERY_OCCLUSION);
  checkOcclusion(D3D11_QUERY_OCCLUSION_PREDICATE);
  MTLD3D11Device device; D3D11_QUERY_DESC1 desc{};
  MTLD3D11TimestampQueryImpl object(&device,&desc);
  MTLD3D11TimestampQuery& query=object;
  uint64_t value=99;
  assert(query.GetData(&value)==S_OK && value==0);
  Rc<TimestampQuery> previous=query.End();
  assert(query.GetData(&value)==S_FALSE);
  previous->issue(123456); assert(query.GetData(&value)==S_OK && value==123456);
  auto before=allocations.load();
  for(unsigned i=0;i<10000;++i) assert(query.GetData(&value)==S_OK && value==123456);
  auto extra=allocations.load()-before;
#ifndef BASELINE
  assert(extra==0);
#endif
  printf("timestamp cached-read allocations=%llu\n",(unsigned long long)extra);
  previous=query.End(); assert(query.GetData(&value)==S_FALSE);
  Rc<TimestampQuery> latest=query.End();
  previous->issue(42); assert(query.GetData(&value)==S_FALSE);
  latest->issue(77); assert(query.GetData(&value)==S_OK && value==77);
  // Readback sum uses unsigned modulo arithmetic, exact crop offsets, empty
  // tails, and publication after all contributing chunks (also under TSAN).
  VisibilityResultQuery sum;
  const uint64_t overflow[]{99,UINT64_MAX,2,99};
  sum.begin(50,1); sum.end(50,3); sum.issue(50,overflow,4);
  assert(sum.getValue(&value) && value==1);
  sum.reset(); assert(!sum.getValue(&value));
  sum.begin(60,1); sum.end(61,2);
  const uint64_t first[]{99,2,3}, last[]{5,7,99};
  std::thread finish([&]{sum.issue(60,first,3);sum.issue(61,last,3);});
  while(!sum.getValue(&value)) std::this_thread::yield();
  assert(value==17); finish.join();
  // Microbenchmark real production issue/getValue; no Metal or FPS claim.
  std::vector<uint64_t> samples(65536,1);
  VisibilityResultQuery benchmark;
  auto start=std::chrono::steady_clock::now();
  for(unsigned i=0;i<256;++i) {
    benchmark.reset(); benchmark.begin(1,0); benchmark.end(1,samples.size());
    benchmark.issue(1,samples.data(),samples.size());
    assert(benchmark.getValue(&value) && value==samples.size());
  }
  auto elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
  printf("readback 256 x 65536 samples: %.3f ms (%.3f ns/sample)\n",elapsed,elapsed*1e6/(256*samples.size()));
  puts("PASS: cached results, reissue, predicates, deferred queries, retained old results, overflow and publication");
}
'''
with tempfile.TemporaryDirectory(prefix='winevision-query-efficiency-') as directory:
    work = Path(directory)
    cpp = work / 'query.cpp'
    cpp.write_text(code)
    exe = work / 'query'
    flags = ['-DBASELINE'] if args.baseline else []
    if args.tsan:
        flags += ['-fsanitize=thread', '-g']
    if args.asan:
        if args.tsan:
            parser.error('--asan and --tsan cannot be combined')
        flags += ['-fsanitize=address,undefined', '-g']
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-O2', *flags,
                    '-I', str(source / 'src/util'), str(cpp), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True, timeout=30)
