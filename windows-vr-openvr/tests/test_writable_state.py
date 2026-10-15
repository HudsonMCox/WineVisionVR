#!/usr/bin/env python3
"""Exercise production OpenComposite app-state code with a read-only DLL directory."""
import argparse
from pathlib import Path
import subprocess
import tempfile
p=argparse.ArgumentParser();p.add_argument('source',type=Path);a=p.parse_args()
s=(a.source/'OpenOVR/Reimpl/BaseClientCore.cpp').read_text()
def function(signature):
 start=s.index(signature);brace=s.index('{',start);end=brace+1;depth=1
 while depth:
  depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
code=r'''
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <stdexcept>
#include <cassert>
#include <cstdio>
#include <sys/stat.h>
#include "json/json.h"
using std::string;using std::wstring;
#define _WIN32 1
#define APISTR(x) (x)
#define OOVR_ABORTF(...) throw std::runtime_error("state write failed")
using DWORD=unsigned;struct SYSTEMTIME{};struct FILETIME{DWORD dwHighDateTime=0,dwLowDateTime=0;};
union ULARGE_INTEGER{struct{DWORD LowPart,HighPart;};uint64_t QuadPart;};
void GetSystemTime(SYSTEMTIME*){};void SystemTimeToFileTime(SYSTEMTIME*,FILETIME*){}
static std::filesystem::path base;
static wstring GetAppSettingsPath(){return (base/"profile").wstring();}
struct BaseClientCore{
 static bool CheckAppEnabled();void SetManifestPath(string);
 static wstring GetDllDir(){return (base/"bundle").wstring()+L"/";}
 static string GetAppPath(){return "C:/Games/Example.exe";}
};
'''+function('static bool ReadJson(')+'\n'+function('static void WriteJson(')+'\n'+function('static wstring GetOpenCompositeStatePath()')+s[s.index('enum Runtime {'):s.index('bool BaseClientCore::CheckAppEnabled()')]+function('bool BaseClientCore::CheckAppEnabled()')+'\n'+function('void BaseClientCore::SetManifestPath(')+r'''
int main(int argc,char**argv){
 base=argv[1];std::filesystem::create_directories(base/"bundle");
 {std::ofstream f(base/"bundle/apps-config.json");f<<R"({"***GlobalConfig":{"default_runtime":2}})";}
 chmod((base/"bundle").c_str(),0555);
 assert(!BaseClientCore::CheckAppEnabled()); // Existing bundled policy is honored.
 assert(std::filesystem::exists(base/"profile/OpenComposite/applist.json"));
 assert(!std::filesystem::exists(base/"bundle/applist.json"));
 BaseClientCore core;core.SetManifestPath("actions.json");
 Json::Value json;assert(ReadJson((base/"profile/OpenComposite/applist.json").wstring(),json));
 assert(json[BaseClientCore::GetAppPath()]["manifest"]=="actions.json");
 core.SetManifestPath("actions.json"); // Unchanged manifest is still preserved.
 assert(!BaseClientCore::CheckAppEnabled());
 chmod((base/"bundle").c_str(),0755);
 puts("PASS: read-only DLL directory, writable per-user discovery/manifest state, repeated startup and bundled runtime policy");
}
'''
jsonroot=a.source/'libs/openxr-sdk/src/external/jsoncpp'
with tempfile.TemporaryDirectory(prefix='winevision-state-') as t:
 w=Path(t);(w/'test.cpp').write_text(code)
 sources=[jsonroot/'src/lib_json'/n for n in ['json_reader.cpp','json_value.cpp','json_writer.cpp']]
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2','-I',str(jsonroot/'include'),str(w/'test.cpp'),*[str(x) for x in sources],'-o',str(w/'test')],check=True)
 subprocess.run([str(w/'test'),str(w/'data')],check=True,timeout=20)
