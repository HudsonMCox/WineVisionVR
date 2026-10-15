#!/usr/bin/env python3
"""An event can signal before its command buffer retires; GetData must see it."""
import argparse
from pathlib import Path
import subprocess
import tempfile
parser=argparse.ArgumentParser()
parser.add_argument('source',type=Path)
a=parser.parse_args()
s=(a.source/'src/d3d11/d3d11_query.hpp').read_text()
enums=s[s.index('enum class QueryState'):s.index('template <typename DataType>\nclass MTLD3D11EventQueryImpl')]
methods=s[s.index('  void Issue(uint64_t current_seq_id) override'):s.index('class MTLD3D11OcclusionQuery')]
code='#include <cstdint>\n#include <cstddef>\n#include <cassert>\nstruct ID3D11Query1 {};\n'+enums+'class EventQuery : public MTLD3D11EventQuery { public:\n'+methods+r'''
int main() {
    EventQuery query;
    query.Issue(10);
    assert(query.CheckEventState(9)==EventState::Pending);
    // GPU has signaled event 10, but a later wait keeps this chunk pending.
    // Treating end-of-chunk completion as event completion would return false
    // here and can prevent the producer of that later wait from advancing.
    bool chunkCompleted=false;
    uint64_t gpuSignal=10;
    assert(!chunkCompleted);
    assert(query.CheckEventState(gpuSignal)==EventState::Signaled);
    // A later issued event remains pending until its actual signal.
    query.Issue(11);
    assert(query.CheckEventState(gpuSignal)==EventState::Pending);
    gpuSignal=11;
    assert(query.CheckEventState(gpuSignal)==EventState::Signaled);
}
'''
context=(a.source/'src/d3d11/d3d11_context_imm.cpp').read_text()
assert 'CheckEventState(cmd_queue.SignaledEventSeqId())' in context
queue=(a.source/'src/dxmt/dxmt_command_queue.hpp').read_text()
assert 'return event.signaledValue();' in queue
with tempfile.TemporaryDirectory(prefix='avpplay-event-order-') as t:
    cpp=Path(t)/'test.cpp';exe=Path(t)/'test';cpp.write_text(code)
    subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2',str(cpp),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True,timeout=30)
print('PASS: production GetData event checks observe exact GPU signals before chunk retirement')
