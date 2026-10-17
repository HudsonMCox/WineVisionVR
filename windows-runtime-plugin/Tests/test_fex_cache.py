#!/usr/bin/env python3
"""Exercise production FEX cache parsing and Windows argv quoting on the Mac."""
from pathlib import Path
import subprocess
import tempfile
import argparse
ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--fex', type=Path, default=ROOT/'.build-fex-cache/FEX')
args=parser.parse_args()
s=(args.fex/'FEXCore/Source/Interface/Core/CodeCache.cpp').read_text()
header=s[s.index('struct CodeCacheHeader {'):s.index('template<typename T>\nconcept OrderedContainer')]
# Execute the exact serialized format and bounds checker; mock only unrelated FEX types.
header=header[:header.index('// Full source bytes')] + header[header.index('// Validate the complete layout'):header.index('bool IsPersistentCacheCurrent')]
probe=r"""
#include <array>
#include <span>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>
#include <cassert>
#include <algorithm>
#define XXH_INLINE_ALL
#include <xxhash.h>
template<class T> T AlignUp(T V, size_t A) { return (V+A-1)&~(A-1); }
namespace CPU {
struct Relocation {
 struct __attribute__((packed)) { uint64_t Offset; uint32_t Type; } Header;
 union {
  uint32_t Payload[9];
  struct { uint32_t RegisterIndex; } NamedThunkMove;
 };
 // The production validator accesses union alternatives at offset zero.
};
}
"""
# Actual relocation definitions use an outer union; reproduce that ABI, not behavior.
probe=probe[:probe.index('namespace CPU {')]+r"""
namespace CPU {
struct __attribute__((packed)) RelocationHeader { uint64_t Offset; uint32_t Type; };
union Relocation {
 RelocationHeader Header;
 struct { RelocationHeader Header; uint32_t Symbol; uint32_t Pad[8]; } NamedSymbolLiteral;
 struct { RelocationHeader Header; uint32_t RegisterIndex; uint32_t Pad[8]; } NamedThunkMove;
 struct { RelocationHeader Header; uint8_t RegisterIndex; char Pad[3]; uint64_t GuestRIP; uint32_t Pad2[6]; } GuestRIP;
};
static_assert(sizeof(Relocation)==48);
}
"""
source_hash=s[s.index('static uint64_t SourceHash('):s.index('// Validate the complete layout')]
current=s[s.index('bool IsPersistentCacheCurrent('):s.index('template<typename T>\nconcept OrderedContainer')]
probe+='#include <fstream>\n#include <string>\nnamespace fextl { using string=std::string; template<class T> using vector=std::vector<T>; }\nstatic constexpr std::array<uint8_t,20> GIT_HASH {};\n'
image=(args.fex/'Source/Windows/Common/ImageTracker.cpp').read_text()
normalize=image[image.index('static fextl::string ToLower('):image.index('FEXCore::CodeMapFileId ComputeCodeMapId(')]
probe+='#include <cctype>\n'+normalize
probe+=header+source_hash+current+r"""
static std::vector<std::byte> Fixture() {
 std::vector<std::byte> File(8192+24);
 CodeCacheHeader H{}; H.NumBlocks=1; H.NumCodePages=1; H.CodeBufferSize=4096; H.NumRelocations=0;
 uint64_t Block[]={4096,0,1,4096}; memcpy(File.data()+sizeof(H),Block,sizeof(Block));
 uint64_t Page[]={4096,1,4096};memcpy(File.data()+8192,Page,sizeof(Page));
 H.padding=File.size(); H.PayloadHash=XXH3_64bits(File.data()+sizeof(H),File.size()-sizeof(H));
 memcpy(File.data(),&H,sizeof(H)); return File;
}
int main(int argc,char**argv) {
 assert(argc==2);
 assert(NormalizeCacheFilename("\\??\\C:\\Games\\Moss.exe")=="c:\\games\\moss.exe");
 std::string Source=std::string(argv[1])+".exe", Cache=std::string(argv[1])+".cache";
 {std::ofstream F(Source);F<<"original source";}
 auto File=Fixture(); CodeCacheHeader H;memcpy(&H,File.data(),sizeof(H));
 assert(ValidateCacheLayout(File,H));
 H.SourceHash=SourceHash(Source);memcpy(File.data(),&H,sizeof(H));
 {std::ofstream F(Cache,std::ios::binary);F.write(reinterpret_cast<const char*>(File.data()),File.size());}
 assert(IsPersistentCacheCurrent(Cache.c_str(),Source.c_str()));
 assert(SourceHash("\\??\\"+Source)==H.SourceHash);
 {std::ofstream F(Source);F<<"modified source";}
 assert(!IsPersistentCacheCurrent(Cache.c_str(),Source.c_str()));
 for (size_t N=0;N<File.size();++N) assert(!ValidateCacheLayout(std::span(File).first(N),H));
 auto M=H; M.FormatVersion=2;assert(!ValidateCacheLayout(File,M));
 M=H; M.NumBlocks=UINT32_MAX;assert(!ValidateCacheLayout(File,M));
 M=H; M.CodeBufferSize=UINT32_MAX;assert(!ValidateCacheLayout(File,M));
 M=H; M.NumRelocations=UINT32_MAX;assert(!ValidateCacheLayout(File,M));
 M=H; M.NumCodePages=UINT32_MAX;assert(!ValidateCacheLayout(File,M));
 M=H; M.PayloadHash^=1;assert(!ValidateCacheLayout(File,M));
 M=H; M.padding=UINT32_MAX;assert(!ValidateCacheLayout(File,M));
 // The real parser must also reject corruption in each payload byte.
 for(size_t I=sizeof(H);I<File.size();++I) {File[I]^=std::byte{1};assert(!ValidateCacheLayout(File,H));File[I]^=std::byte{1};}
}
"""
quote=r"""
#include <cassert>
#include "WindowsCommandLine.h"
int main() {
 assert(QuoteWindowsArgument(L"")==L"\"\"");
 assert(QuoteWindowsArgument(L"abc def")==L"\"abc def\"");
 assert(QuoteWindowsArgument(L"C:\\game\\")==L"\"C:\\game\\\\\"");
 assert(QuoteWindowsArgument(L"a\"b")==L"\"a\\\"b\"");
 assert(QuoteWindowsArgument(L"a\\\"b")==L"\"a\\\\\\\"b\"");
 assert(QuoteWindowsArgument(L"Möss")==L"\"Möss\"");
}
"""
h=(args.fex/'FEXCore/include/FEXCore/Core/CodeCache.h').read_text()
types=h[h.index('using CodeMapFileId ='):h.index('class AbstractCodeCache;')]
implementation=s[s.index('fextl::map<CodeMapFileId, CodeMap::ParsedContents> CodeMap::ParseCodeMap'):s.index('} // namespace FEXCore\n\nnamespace FEXCore::Context')]
codemap=r"""
#include <atomic>
#include <algorithm>
#include <span>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>
#include <set>
#include <map>
#include <optional>
#include <mutex>
#include <shared_mutex>
#include <fstream>
#include <string>
#include <cassert>
#include <fcntl.h>
#include <unistd.h>
#include <cstdlib>
#define FEX_PACKED __attribute__((packed))
#define ERROR_AND_DIE_FMT(...) abort()
namespace LogMan::Msg {template<class... T> void EFmt(T...) {} template<class... T> void DFmt(T...) {}}
namespace fextl {using string=std::string;template<class T> using vector=std::vector<T>;template<class T> using set=std::set<T>;template<class K,class V> using map=std::map<K,V>;}
template<class T> T AlignUp(T V, size_t A) { return (V+A-1)&~(A-1); }
namespace FEXCore {
struct ExecutableFileInfo {uint64_t FileId; std::string Filename;};
struct ExecutableFileSectionInfo {const ExecutableFileInfo& FileInfo;uint64_t FileStartVA,BeginVA,EndVA;};
namespace Utils::SpinWaitLock {template<class Pred,class T> void WaitPred(T* P,T V) {while(!Pred{}(*P,V)) {}}}
"""+types+implementation+r"""
}
struct Opener:FEXCore::CodeMapOpener {std::string Path;int OpenCodeMapFile() override{return open(Path.c_str(),O_CREAT|O_TRUNC|O_WRONLY,0600);}};
int main(int argc,char**argv) {
 assert(argc==2);Opener O;O.Path=argv[1];
 FEXCore::ExecutableFileInfo Main{1,"c:\\game.exe"};
 for(bool Warm: {false,true}) {
  {
   FEXCore::CodeMapWriter W(O,true);W.AppendSetMainExecutable(Main);W.AppendLibraryLoad(Main);
   for(uint64_t I=2;I<1002;++I) W.AppendLibraryLoad({I,"c:\\cached-module-"+std::to_string(I)+".dll"});
   if(!Warm) W.AppendBlock({Main,0,0,65536},4096);
  }
  std::ifstream F(O.Path,std::ios::binary);auto M=FEXCore::CodeMap::ParseCodeMap(F);
  assert(M.size()==1001);assert(M.at(1).IsExecutable);assert(M.at(1).Filename==Main.Filename);
  assert(M.at(1).Blocks.size()==(Warm?0:1));
  for(auto& [ID,E]:M) assert(!E.Filename.empty());
 }
}
"""
with tempfile.TemporaryDirectory(prefix='wvr-cache-test-') as name:
 w=Path(name)
 for label,code,includes in [('layout',probe,[args.fex/'External/xxhash']),('argv',quote,[ROOT/'windows-runtime-plugin/cache']),('codemap',codemap,[])]:
  src=w/(label+'.cpp');src.write_text(code);out=w/label
  command=['xcrun','clang++','-std=c++20','-O1','-g','-fsanitize=undefined,bounds',str(src),'-o',str(out)]
  for inc in includes:command+=['-I',str(inc)]
  subprocess.run(command,check=True);subprocess.run([str(out),str(w/"source-fixture")],check=True,timeout=30)
print('PASS: production cache layout, every truncation/payload corruption, oversized counts, source invalidation, format rejection, cold/warm codemap metadata (1000 dependencies) and Windows argument quoting (UBSan/bounds)')
