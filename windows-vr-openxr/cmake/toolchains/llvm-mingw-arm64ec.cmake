# ARM64EC interoperability target, not a plain AArch64 Windows DLL.
set(_llvm_mingw_triple "arm64ec-w64-mingw32")
include("${CMAKE_CURRENT_LIST_DIR}/llvm-mingw-x64.cmake")
