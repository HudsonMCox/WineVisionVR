#!/usr/bin/env python3
"""Exercise production mixed-architecture selection and receipts without Wine."""
from pathlib import Path
import json,subprocess,tempfile,shutil,hashlib
root=Path(__file__).resolve().parents[2]
s=(root/'windows-runtime-plugin/WindowsVRRuntimePlugin.mm').read_text()
def function(signature):
 start=s.index(signature);brace=s.index('{',start);end=brace+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end].replace('[NSBundle mainBundle].resourceURL','testResources')
code='''#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <cassert>
static NSURL *testResources;
'''
for sig in ['bool IsContainedPath(', 'bool ReadPEInfo(', 'bool IsARM64ECPE(', 'bool IsX64PE(', 'bool SHA256File(', 'bool ValidateFEXCachePackage(', 'const char *SelectedGuestArchitecture(', 'bool ValidateGuestPackage(']:code+=function(sig)+'\n'
code+=r'''int main(int argc,char**argv){@autoreleasepool{
 assert(argc==3);testResources=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
 std::string arch,error;const std::string mode=argv[2];
 if(mode=="cache"){assert(ValidateFEXCachePackage(error));}
 if(mode=="cache-bad"){assert(!ValidateFEXCachePackage(error));}
 if(mode=="native"){unsetenv("WVR_GUEST_RUNTIME_ARCH");if(!ValidateGuestPackage(arch,error)||arch!="arm64ec"){fprintf(stderr,"native rejection: %s architecture=%s\n",error.c_str(),arch.c_str());return 1;}}
 if(mode=="x64"){setenv("WVR_GUEST_RUNTIME_ARCH","x64",1);assert(ValidateGuestPackage(arch,error)&&arch=="x64");}
 if(mode=="bad"){unsetenv("WVR_GUEST_RUNTIME_ARCH");assert(!ValidateGuestPackage(arch,error));assert(!error.empty());}
 if(mode=="invalid"){setenv("WVR_GUEST_RUNTIME_ARCH","other",1);assert(!ValidateGuestPackage(arch,error));}
}}'''
with tempfile.TemporaryDirectory(prefix='wvr-native-package-') as temp:
 w=Path(temp);(w/'probe.mm').write_text(code)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-fobjc-arc','-Wno-deprecated-declarations',str(w/'probe.mm'),'-framework','Foundation','-o',str(w/'probe')],check=True)
 stage=w/'Resources/WindowsVR/Guest';stage.mkdir(parents=True)
 for arch in ['x64','arm64ec']:
  original=root/'visionos-windows-vr/Resources/WindowsVR/Guest'/arch
  for rel in ['OpenComposite/bin/vrclient_x64.dll','wvr_openxr.dll']:
   dest=stage/arch/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(original/rel,dest)
 shutil.copyfile(root/'visionos-windows-vr/Resources/WindowsVR/Guest/arm64ec/AVPPLAY_LOCAL_BUILD_RECEIPT.json',stage/'arm64ec/AVPPLAY_LOCAL_BUILD_RECEIPT.json')
 def run(mode):subprocess.run([str(w/'probe'),str(w/'Resources'),mode],check=True)
 tools=w/'Resources/WindowsVR/CacheTools';tools.mkdir()
 original=root/'visionos-windows-vr/Resources/WindowsVR/CacheTools'
 for name in ['FEXOfflineCompiler64.exe','WindowsVRCacheLauncher.exe','AVPPLAY_FEX_CACHE_RECEIPT.json']:shutil.copyfile(original/name,tools/name)
 runtime=w/'Resources/Runtime/arm64ec-windows';runtime.mkdir(parents=True)
 shutil.copyfile(root/'visionos-windows-vr/Resources/Runtime/arm64ec-windows/xtajit64.dll',runtime/'xtajit64.dll')
 run('cache')
 cache_receipt=tools/'AVPPLAY_FEX_CACHE_RECEIPT.json';cache_before=cache_receipt.read_bytes();data=json.loads(cache_before);data['translatorSha256']='0'*64;cache_receipt.write_text(json.dumps(data));run('cache-bad');cache_receipt.write_bytes(cache_before)
 compiler=tools/'FEXOfflineCompiler64.exe';compiler_before=compiler.read_bytes();compiler.write_bytes((stage/'x64/wvr_openxr.dll').read_bytes());run('cache-bad');compiler.write_bytes(compiler_before)
 run('native');run('x64');run('invalid')
 receipt=stage/'arm64ec/AVPPLAY_LOCAL_BUILD_RECEIPT.json';before=receipt.read_bytes();data=json.loads(before);data['filesSha256']['wvr_openxr.dll']='0'*64;receipt.write_text(json.dumps(data));run('bad');receipt.write_bytes(before)
 dll=stage/'arm64ec/wvr_openxr.dll';before=dll.read_bytes();dll.write_bytes((stage/'x64/wvr_openxr.dll').read_bytes());run('bad');dll.write_bytes(before)
 receipt.unlink();run('bad')
 print('PASS: native mixed-architecture selection, explicit x64, invalid override, stale hash, wrong DLL architecture and missing receipt')
