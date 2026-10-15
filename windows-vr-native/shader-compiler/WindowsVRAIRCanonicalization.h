// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/Pass.h"
#include "llvm/Transforms/Scalar.h"

// Finish DXMT's CFG cleanup before handing AIR to the Metal backend. In the
// captured failures, equivalent discard operations on both sides of a branch
// survived the default cleanup alongside a coverage-mask PHI. Common-instruction
// simplification preserves both the discard and the selected coverage value,
// while eliminating that redundant branch. Keep normal backend optimization.
// Use LLVM's legality checks rather than shader identities or custom IR edits.
inline void wvr_canonicalize_air(llvm::Module &module) {
  llvm::legacy::PassManager passes;
  passes.add(llvm::createCFGSimplificationPass(
      llvm::SimplifyCFGOptions().hoistCommonInsts(true).sinkCommonInsts(true)));
  passes.run(module);
}
