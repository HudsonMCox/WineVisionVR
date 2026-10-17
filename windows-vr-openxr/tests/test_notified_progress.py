#!/usr/bin/env python3
"""Compile the production queue getter; mirrored polls must make no native calls."""
import argparse
from pathlib import Path
import subprocess
import tempfile
p=argparse.ArgumentParser();p.add_argument('source',type=Path);a=p.parse_args()
s=(a.source/'src/dxmt/dxmt_command_queue.hpp').read_text()
start=s.index('  uint64_t\n  SignaledEventSeqId()');end=s.index('  obj_handle_t GetSharedEventListener()',start)
getter=s[start:end]
queue=(a.source/'src/dxmt/dxmt_command_queue.cpp').read_text()
retry=queue.split('CommandQueue::CommitCurrentChunk()',1)[1].split('auto &chunk =',1)[0]
assert 'progress.colorTexture = event.handle;' in retry
assert '!(progress.encoder & 7u) && progress.token' in retry
code=r'''
#include <atomic>
#include <cstdint>
#include <cassert>
#include <cstdio>
struct Queue {
 const std::atomic<uint64_t>* event_progress_page_=nullptr;
 struct Event {uint64_t signal=0,reads=0;uint64_t signaledValue(){++reads;return signal;}}event;
'''+getter+r'''
};
int main(){
 Queue queue;std::atomic<uint64_t> page{0};queue.event_progress_page_=&page;
 for(unsigned i=0;i<1000000;++i)assert(queue.SignaledEventSeqId()==0);
 assert(queue.event.reads==0);
 page.store(7,std::memory_order_release);assert(queue.SignaledEventSeqId()==7);
 page.store(12,std::memory_order_release);assert(queue.SignaledEventSeqId()==12);
 assert(queue.event.reads==0);
 queue.event_progress_page_=nullptr;queue.event.signal=19;
 assert(queue.SignaledEventSeqId()==19&&queue.event.reads==1);
 puts("PASS: 1,000,000 production queue polls make zero native calls; exact published progress and unsupported-host fallback retained");
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-query-progress-') as tmp:
 w=Path(tmp);(w/'probe.cpp').write_text(code)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2','-fsanitize=undefined',str(w/'probe.cpp'),'-o',str(w/'probe')],check=True)
 subprocess.run([str(w/'probe')],check=True)
