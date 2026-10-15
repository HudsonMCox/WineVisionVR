// SPDX-License-Identifier: GPL-3.0-or-later
#include "WindowsVRAIRWriter.h"
#include "WindowsVRAIRCanonicalization.h"
#include "WindowsVRAIRFoveation.h"
#include "wvr_metallib_platform.h"
#include "metallib_writer.hpp"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/MemoryBuffer.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static std::atomic<bool> foveationEnabled{false};

static uint64_t readLE(const uint8_t *p, unsigned bytes) {
  uint64_t result = 0;
  for (unsigned i = 0; i < bytes; ++i) result |= uint64_t(p[i]) << (8 * i);
  return result;
}

extern "C" int wvr_air_reemit(const uint8_t *input, size_t length,
    uint8_t **output, size_t *outputLength, char *error, size_t errorCapacity) {
  if (!output || !outputLength) return -1;
  *output = nullptr;
  *outputLength = 0;
  if (error && errorCapacity) error[0] = 0;
  // Restrict this adapter to the known DXMT xros single-module container.
  // Apple-authored and multi-function libraries pass through unchanged.
  if (!input || length < 88 || length > 8 * 1024 * 1024 ||
      std::memcmp(input, "MTLB", 4) || readLE(input + 4, 2) != 1 ||
      readLE(input + 6, 2) != 2 || readLE(input + 8, 2) != 7 || input[11] != 0x8b)
    return 0;
  auto fail = [&](const std::string &reason) {
    if (error && errorCapacity) std::snprintf(error, errorCapacity, "%s", reason.c_str());
    return -1;
  };
  const uint64_t functions = readLE(input + 24, 8);
  const uint64_t bitcodeOffset = readLE(input + 72, 8);
  const uint64_t bitcodeLength = readLE(input + 80, 8);
  if (readLE(input + 16, 8) != length || functions > length - 4 ||
      bitcodeOffset > length || bitcodeLength > length - bitcodeOffset || !bitcodeLength)
    return fail("DXMT library has invalid section bounds");
  if (readLE(input + functions, 4) != 1) return 0;
  llvm::LLVMContext context;
  llvm::StringRef bytes(reinterpret_cast<const char *>(input + bitcodeOffset), bitcodeLength);
  auto parsed = llvm::parseBitcodeFile(llvm::MemoryBufferRef(bytes, "DXMT captured AIR"), context);
  if (!parsed) return fail(llvm::toString(parsed.takeError()));
  auto module = std::move(*parsed);
  if (module->getSourceFileName() != "airconv_generated.metal") return 0;
  std::string diagnostics;
  llvm::raw_string_ostream diagnosticStream(diagnostics);
  if (llvm::verifyModule(*module, &diagnosticStream)) return fail(diagnosticStream.str());
  module->setTargetTriple("air64-apple-xros2.0");
  const uint32_t sdk[] = {WVR_METALLIB_SDK_MAJOR, WVR_METALLIB_SDK_MINOR};
  module->setModuleFlag(llvm::Module::Warning, "SDK Version",
      llvm::ConstantAsMetadata::get(llvm::ConstantDataArray::get(context, sdk)));
  if (foveationEnabled.load() && !wvr_foveate_fragment_position(*module, diagnostics)) return fail(diagnostics);
  wvr_canonicalize_air(*module);
  if (llvm::verifyModule(*module, &diagnosticStream)) return fail(diagnosticStream.str());
  llvm::SmallVector<char, 0> library;
  llvm::raw_svector_ostream stream(library);
  dxmt::metallib::MetallibWriter writer;
  std::string reason;
  if (!writer.Write(*module, stream, reason)) return fail(reason);
  void *storage = std::malloc(library.size());
  if (!storage) return fail("Not enough memory to prepare the DXMT shader library");
  std::memcpy(storage, library.data(), library.size());
  *output = static_cast<uint8_t *>(storage);
  *outputLength = library.size();
  return 1;
}

extern "C" unsigned wvr_air_foveation_abi_v1(void) { return 1; }
extern "C" void wvr_air_enable_foveation_v1(void) { foveationEnabled.store(true); }
