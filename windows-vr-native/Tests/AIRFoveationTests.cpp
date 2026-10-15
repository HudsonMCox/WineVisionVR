// Exercises the production transform with actual Metal-generated AIR.
#include "WindowsVRAIRFoveation.h"
#include "metallib_writer.hpp"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_ostream.h"
#include <cassert>
#include <fstream>
#include <string>
int main(int argc, char **argv) {
  assert(argc == 3);
  llvm::LLVMContext context;
  llvm::SMDiagnostic diagnostic;
  auto module = llvm::parseAssemblyFile(argv[1], diagnostic, context);
  if (!module) {
    diagnostic.print(argv[0], llvm::errs());
    return 1;
  }

  // Root-signature and reserved-binding fixtures exercise the ABI scope guard.
  for (bool rootSignature : {true, false}) {
    auto other = llvm::parseAssemblyFile(argv[1], diagnostic, context);
    assert(other);
    auto fragments = other->getNamedMetadata("air.fragment");
    auto metadata = fragments->getOperand(0);
    auto inputs = llvm::cast<llvm::MDNode>(metadata->getOperand(2));
    llvm::SmallVector<llvm::Metadata *, 8> args;
    for (auto &operand : inputs->operands())
      args.push_back(operand.get());
    auto str = [&](const char *s) -> llvm::Metadata * {
      return llvm::MDString::get(context, s);
    };
    auto integer = [&](unsigned v) -> llvm::Metadata * {
      return llvm::ConstantAsMetadata::get(
          llvm::ConstantInt::get(llvm::Type::getInt32Ty(context), v));
    };
    args.push_back(llvm::MDNode::get(
        context,
        {integer(0), str(rootSignature ? "air.indirect_buffer" : "air.buffer"),
         str("air.location_index"), integer(28), integer(1),
         str("air.arg_name"), str(rootSignature ? "rootsig" : "occupied")}));
    fragments->setOperand(
        0, llvm::MDNode::get(context, {metadata->getOperand(0).get(),
                                       metadata->getOperand(1).get(),
                                       llvm::MDNode::get(context, args)}));
    auto function = llvm::cast<llvm::Function>(
        llvm::cast<llvm::ValueAsMetadata>(metadata->getOperand(0))->getValue());
    auto count = function->arg_size();
    std::string why;
    assert(wvr_foveate_fragment_position(*other, why) == rootSignature);
    assert(function->arg_size() == count &&
           !other->getFunction(
               "air.map_physical_to_screen_coordinates.v2f32.p2i8.i32"));
  }
  auto before = module->getNamedMetadata("air.fragment")->getOperand(0);
  auto oldFn = llvm::cast<llvm::Function>(
      llvm::cast<llvm::ValueAsMetadata>(before->getOperand(0))->getValue());
  unsigned count = oldFn->arg_size();
  unsigned inputCount =
      llvm::cast<llvm::MDNode>(before->getOperand(2))->getNumOperands();
  std::string error;
  assert(wvr_foveate_fragment_position(*module, error));
  assert(!llvm::verifyModule(*module, &llvm::errs()));
  auto after = module->getNamedMetadata("air.fragment")->getOperand(0);
  auto fn = llvm::cast<llvm::Function>(
      llvm::cast<llvm::ValueAsMetadata>(after->getOperand(0))->getValue());
  assert(fn->arg_size() == count + 1);
  assert(module->getFunction(
      "air.map_physical_to_screen_coordinates.v2f32.p2i8.i32"));
  assert(wvr_foveate_fragment_position(*module, error));
  assert(fn->arg_size() == count + 1); // cache-safe/idempotent
  // Shader inputs preserve original semantic indices; only the reserved map
  // argument is appended.
  assert(llvm::cast<llvm::MDNode>(after->getOperand(2))->getNumOperands() ==
         inputCount + 1);
  llvm::SmallVector<char, 0> library;
  llvm::raw_svector_ostream stream(library);
  dxmt::metallib::MetallibWriter writer;
  if (!writer.Write(*module, stream, error)) {
    llvm::errs() << error << "\n";
    return 2;
  }
  std::ofstream output(argv[2], std::ios::binary);
  output.write(library.data(), library.size());
  llvm::outs()
      << "PASS: production AIR position rewrite verifies, preserves input "
         "indices, appends map binding once and emits a Metal library\n";
}
