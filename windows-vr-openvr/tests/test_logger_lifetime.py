#!/usr/bin/env python3
"""Exercise production logger storage/init/write during another TU's constructor."""
import argparse
from pathlib import Path
import subprocess
import tempfile
p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('--baseline',action='store_true');p.add_argument('--tsan',action='store_true');a=p.parse_args()
flags=['-fsanitize=thread','-g'] if a.tsan else []
s=(a.source/'OpenOVR/logging.cpp').read_text()
def function(signature):
 start=s.index(signature);brace=s.index('{',start);end=brace+1;depth=1
 while depth:
  depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
start=s.index('void wvr_log_construction_marker');state=s[start:s.index('#ifdef __GLIBCXX__',start)]
code='''#include <atomic>\n#include <fstream>\n#include <mutex>\n#include <string>\n#include <cstring>\n#include <cstdio>\nusing std::string;\nstatic string GetEnv(const char*){return "";}\nstatic bool makePath(const string&){return true;}\nstatic string format_time(){return "time";}\n'''+state+'\n'+function('static void init_stream()')+'\n'+function('void oovr_log_raw(const char*')
early='''extern void oovr_log_raw(const char*,long,const char*,const char*);\nstruct Early{Early(){oovr_log_raw(__FILE__,__LINE__,"global-config","early construction");}};\nEarly early;\n'''
main='''#include <thread>\n#include <vector>\nextern void oovr_log_raw(const char*,long,const char*,const char*);\nint main(){std::vector<std::thread> threads;for(int t=0;t<8;++t)threads.emplace_back([]{for(int n=0;n<1000;++n)oovr_log_raw(__FILE__,__LINE__,"worker","complete message");});for(auto& t:threads)t.join();}\n'''
with tempfile.TemporaryDirectory(prefix='winevision-logger-') as t:
 w=Path(t)
 for name,text in [('logger.cpp',code),('early.cpp',early),('main.cpp',main)]:
  (w/name).write_text(text)
  subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2','-pthread',*flags,'-c',str(w/name),'-o',str(w/(name+'.o'))],check=True)
 for n,order in enumerate([['early','logger','main'],['logger','early','main']]):
  exe=w/f'test{n}';subprocess.run(['xcrun','--sdk','macosx','clang++','-pthread',*flags,*[str(w/(x+'.cpp.o')) for x in order],'-o',str(exe)],check=True)
  result=subprocess.run([str(exe)],cwd=w,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=30)
  if a.baseline:
   if n==0:
    assert result.returncode!=0,'early global logging should reproduce the baseline defect'
    print('CONFIRMED: baseline logger fails when configuration constructs first')
   break
  if result.returncode:raise RuntimeError(result.stderr.decode(errors='replace'))
  lines=(w/'opencomposite.log').read_text().splitlines()
  assert len(lines)==8001,len(lines)
  assert sum('early construction' in x for x in lines)==1
  assert sum('complete message' in x for x in lines)==8000
 print('PASS: early global logging and 8 concurrent writers, both TU link orders' if not a.baseline else 'Baseline failure reproduced without launching a game')
