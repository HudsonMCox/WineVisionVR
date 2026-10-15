// SPDX-License-Identifier: GPL-3.0-or-later
// Offline compiler fixture: use the patched DXMT writer and its locked LLVM.
// This emits a library only; it never creates a GPU device or executes shaders.
#include "wvr_metallib_platform.h"
#include "llvm/Support/VersionTuple.h"
#include "metallib_writer.hpp"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Verifier.h"
#include "llvm/IR/Constants.h"
#include "../windows-vr-native/shader-compiler/WindowsVRAIRCanonicalization.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Support/Error.h"
int main(int argc, char **argv) {
  if (argc != 3) {
    llvm::errs() << "usage: reemit_captured_air input.air output.metallib\n";
    return 2;
  }
  llvm::LLVMContext context;
  auto buffer = llvm::MemoryBuffer::getFile(argv[1]);
  if (!buffer) { llvm::errs() << buffer.getError().message(); return 1; }
  auto parsed = llvm::parseBitcodeFile((*buffer)->getMemBufferRef(), context);
  if (!parsed) { llvm::errs() << llvm::toString(parsed.takeError()); return 1; }
  auto module = std::move(*parsed);
  if (llvm::verifyModule(*module, &llvm::errs())) return 1;
  module->setTargetTriple("air64-apple-xros2.0");
  // setSDKVersion appends a module flag; a captured module already has one.
  // Replace it so the re-emitted input does not retain the old macOS SDK flag.
  uint32_t sdk[] = {WVR_METALLIB_SDK_MAJOR, WVR_METALLIB_SDK_MINOR};
  module->setModuleFlag(llvm::Module::Warning, "SDK Version",
      llvm::ConstantAsMetadata::get(llvm::ConstantDataArray::get(context, sdk)));
  wvr_canonicalize_air(*module);
  if (llvm::verifyModule(*module, &llvm::errs())) return 1;
  std::error_code error;
  llvm::raw_fd_ostream output(argv[2], error, llvm::sys::fs::OF_None);
  if (error) { llvm::errs() << error.message(); return 1; }
  dxmt::metallib::MetallibWriter writer;
  std::string reason;
  if (!writer.Write(*module, output, reason)) { llvm::errs() << reason; return 1; }
  return 0;
}
