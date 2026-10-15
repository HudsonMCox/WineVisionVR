#!/usr/bin/env python3
"""Exercise actual patched DXMT query helpers across producer/consumer threads."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path, help='DXMT source with 0010 applied')
parser.add_argument('--tsan', action='store_true')
args = parser.parse_args()
source = (args.source / 'src/dxmt/dxmt_occlusion_query.hpp').read_text()
visibility = source.split('class VisibilityResultQuery {', 1)[1].split('class VisibilityResultReadback', 1)[0]
timestamp = source.split('class TimestampQuery {', 1)[1].split('using TimestampQueryList', 1)[0]
readback = source.split('class VisibilityResultReadback {', 1)[1].split('/**', 1)[0]
code = '''#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <thread>
#include <vector>
''' + 'class VisibilityResultQuery {' + visibility + 'class TimestampQuery {' + timestamp
# Only the Metal allocation boundary is stubbed. The query, readback destructor
# and flush factory are the actual production code.
code += r'''
struct WVRTestMemory {void* pointer=nullptr;void set(void* p){pointer=p;}void* get(){return pointer;}};
constexpr unsigned WMTResourceHazardTrackingModeUntracked=0;
struct WMTBufferInfo {unsigned options=0;WVRTestMemory memory;uint64_t length=0;};
namespace WMT {
struct Buffer {};
template<typename T> using Reference=std::shared_ptr<T>;
struct Device {Reference<Buffer> newBuffer(WMTBufferInfo&){std::abort();}};
}
template<typename T> using Rc=std::shared_ptr<T>;
''' + 'class VisibilityResultReadback {' + readback
code += r'''
int main() {
  VisibilityResultQuery empty;
  uint64_t value = 999;
  assert(!empty.getValue(&value));
  empty.begin(1, 3); empty.end(1, 3);
  assert(empty.getValue(&value) && value == 0);
  empty.reset(); assert(!empty.getValue(&value));
  // A real drawing chunk followed by an empty query-end chunk must retain
  // its actual samples and complete only when the tail retires.
  VisibilityResultQuery spanning;
  const uint64_t samples[] = {41, 2, 3};
  spanning.begin(20, 1); spanning.end(21, 0);
  spanning.issue(20, samples, 3);
  assert(!spanning.getValue(&value));
  spanning.issue(21, nullptr, 0);
  assert(spanning.getValue(&value) && value == 5);
  auto finalTail = std::make_shared<VisibilityResultQuery>();
  finalTail->begin(30, 1); finalTail->end(31, 0); finalTail->issue(30, samples, 3);
  std::vector<Rc<VisibilityResultQuery>> pending{finalTail};
  auto readback = FlushVisibilityQueries(WMT::Device{}, 31, 0, pending);
  assert(readback && pending.empty());
  assert(!finalTail->getValue(&value)); // Neither allocated nor completed early.
  readback.reset(); // Ordered finish-thread retirement after real GPU completion.
  assert(finalTail->getValue(&value) && value == 5);
  constexpr unsigned count = 2000;
  std::vector<std::unique_ptr<TimestampQuery>> timestamps;
  std::vector<std::unique_ptr<VisibilityResultQuery>> queries;
  for (unsigned n = 0; n < count; ++n) {
    timestamps.push_back(std::make_unique<TimestampQuery>());
    queries.push_back(std::make_unique<VisibilityResultQuery>());
    queries.back()->begin(10, 1); queries.back()->end(11, 2);
    assert(!timestamps.back()->getValue(&value));
    assert(!queries.back()->getValue(&value));
  }
  std::thread finish([&] {
    const uint64_t first[] = {91, 2, 3}, second[] = {5, 7, 93};
    for (unsigned n = 0; n < count; ++n) {
      queries[n]->issue(10, first, 3);
      queries[n]->issue(11, second, 3);
      timestamps[n]->issue(n * 1000);
    }
  });
  for (unsigned n = 0; n < count; ++n) {
    while (!timestamps[n]->getValue(&value)) std::this_thread::yield();
    assert(value == n * 1000);
    while (!queries[n]->getValue(&value)) std::this_thread::yield();
    assert(value == 17); // Exact GPU readback sums, including both chunk boundaries.
  }
  finish.join();
  for (auto& q : queries) { q->reset(); assert(!q->getValue(&value)); }
  puts("PASS: real query publication, cross-thread results, offsets, empty queries and reset");
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-query-') as directory:
    work = Path(directory)
    cpp = work / 'query.cpp'
    cpp.write_text(code)
    exe = work / 'query'
    flags = ['-fsanitize=thread', '-g'] if args.tsan else []
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-O2', *flags, str(cpp), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True, timeout=30)
