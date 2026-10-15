#!/usr/bin/env python3
"""Exercise the production VR recording boundary with a command-queue harness."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path)
parser.add_argument('--tsan', action='store_true')
args = parser.parse_args()
source = (args.source / 'src/d3d11/d3d11_context_impl.cpp').read_text()
start = source.index('  void EmitWindowsVROperation(')
opening = source.index('{', start)
depth = 1
end = opening + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = 'template<typename cmd>\n' + source[start:end]
code = r'''
#include <cassert>
#include <functional>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>
struct Encoder {
  bool active = false;
  unsigned draws = 0, waits = 0, submissions = 0;
  void begin() { assert(!active); active = true; }
  void draw() { assert(active); ++draws; }
  void end() { assert(active); active = false; }
  void wait() { assert(!active); ++waits; }
  void submit() { assert(!active); ++submissions; }
};
struct Context {
  using mutex_t = std::mutex;
  mutex_t mutex;
  bool active = false;
  unsigned commits = 0;
  std::vector<std::function<void(Encoder&)>> commands;
  void InvalidateCurrentPass(bool defer) {
    assert(defer);
    if (active) { commands.emplace_back([](Encoder& e){ e.end(); }); active = false; }
  }
  template<typename F> void EmitOP(F&& f) { commands.emplace_back(std::forward<F>(f)); }
  void Commit() { assert(!active); ++commits; }
  void draw() {
    std::lock_guard<mutex_t> lock(mutex);
    if (!active) { commands.emplace_back([](Encoder& e){ e.begin(); }); active = true; }
    commands.emplace_back([](Encoder& e){ e.draw(); });
  }
''' + method + r'''
};
int main() {
  // A wait between two drawing passes must preserve both passes and keep
  // the standalone event outside a render encoder. Submission closes the
  // second pass before the command chunk is committed.
  Context c;
  c.draw();
  c.EmitWindowsVROperation([](Encoder& e){ e.wait(); }, false);
  assert(c.commits == 0);
  c.draw();
  c.EmitWindowsVROperation([](Encoder& e){ e.submit(); }, true);
  Encoder e;
  for (auto& op : c.commands) op(e);
  assert(!e.active && e.draws == 2 && e.waits == 1 && e.submissions == 1 && c.commits == 1);
  // An idle wait must not manufacture an endPass, and simultaneous callers
  // must not race the context's command storage or commit state.
  Context concurrent;
  std::thread a([&]{ for (int i=0;i<1000;++i) concurrent.EmitWindowsVROperation([](Encoder& e){e.wait();}, false); });
  std::thread b([&]{ for (int i=0;i<1000;++i) concurrent.EmitWindowsVROperation([](Encoder& e){e.submit();}, true); });
  a.join(); b.join();
  Encoder idle;
  for (auto& op : concurrent.commands) op(idle);
  assert(idle.waits == 1000 && idle.submissions == 1000 && concurrent.commits == 1000);
}
'''
# Verify both real extension entry points use the tested boundary.
assert 'ctx_->EmitWindowsVROperation([leftTexture' in source
assert 'ctx_->EmitWindowsVROperation([event = std::move(waitEvent)' in source
with tempfile.TemporaryDirectory(prefix='avpplay-encoder-contract-') as tmp:
    cpp = Path(tmp) / 'contract.cpp'
    exe = Path(tmp) / 'contract'
    cpp.write_text(code)
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-O2', *(['-fsanitize=thread'] if args.tsan else []), str(cpp), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True, timeout=30)
print('PASS: production VR boundaries preserve draws, order standalone waits, close before commit and serialize recording')
