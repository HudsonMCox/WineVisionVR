#!/usr/bin/env python3
"""Exercise the production GPU-completion fence without running a game."""
import argparse
from pathlib import Path
import subprocess
import tempfile
parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path)
args = parser.parse_args()
h = (args.source / 'src/dxmt/dxmt_command_queue.hpp').read_text()
fence = h.split('class CompletedEventFence {', 1)[1].split('class CommandQueue;', 1)[0]
cpp = '#include <atomic>\n#include <cassert>\n#include <cstdint>\n#include <thread>\n#include <vector>\nclass CompletedEventFence {' + fence + r'''
int main() {
    CompletedEventFence fence;
    assert(fence.signaledValue() == 0);
    fence.retire(10, false); // scheduled or failed GPU buffer must not publish.
    assert(fence.signaledValue() == 0);
    fence.retire(10, true);
    assert(fence.signaledValue() == 10);
    fence.retire(20, false);
    assert(fence.signaledValue() == 10);
    constexpr unsigned n = 10000;
    std::vector<unsigned> results(n + 1);
    CompletedEventFence concurrent;
    std::thread finish([&]{
        for(unsigned i=1; i<=n; ++i) {
            results[i]=i*3;
            concurrent.retire(i, true);
        }
    });
    uint64_t previous=0;
    while(previous < n) {
        auto completed=concurrent.signaledValue();
        assert(completed >= previous);
        if(completed) assert(results[completed] == completed*3);
        previous=completed;
    }
    finish.join();
}
'''
queue = (args.source / 'src/dxmt/dxmt_command_queue.cpp').read_text()
context = (args.source / 'src/d3d11/d3d11_context_imm.cpp').read_text()
assert 'completed_event_fence.retire(chunk.chunk_event_id,\n        chunk.attached_cmdbuf.status() == WMTCommandBufferStatusCompleted)' in queue
assert 'CheckEventState(cmd_queue.CompletedEventSeqId())' in context
with tempfile.TemporaryDirectory(prefix='avpplay-event-cache-') as tmp:
    source = Path(tmp) / 'test.cpp'
    binary = Path(tmp) / 'test'
    source.write_text(cpp)
    subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2',str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=30)
print('PASS: production fence publishes only GPU-completed progress and preserves cross-thread result visibility')
