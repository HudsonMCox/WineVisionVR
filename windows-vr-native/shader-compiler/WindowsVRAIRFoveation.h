// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "llvm/IR/Constants.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Module.h"
#include <string>

// Preserve D3D's logical SV_Position when the rasterizer writes a compressed
// image. Use Apple's own AIR intrinsic (the lowering of the documented MSL
// rasterization_rate_map_decoder), preserving z/w exactly. Uniform encoders
// bind an identity rate map to the same reserved fragment-only slot.
inline bool wvr_foveate_fragment_position(llvm::Module &module,
                                          std::string &error) {
  if (module.getNamedMetadata("wvr.foveation.position.v1"))
    return true;
  auto fragments = module.getNamedMetadata("air.fragment");
  if (!fragments)
    return true;
  auto &context = module.getContext();
  for (unsigned n = 0; n < fragments->getNumOperands(); ++n) {
    auto entry = fragments->getOperand(n);
    if (entry->getNumOperands() != 3) {
      error = "Invalid AIR fragment metadata";
      return false;
    }
    auto value = llvm::dyn_cast<llvm::ValueAsMetadata>(entry->getOperand(0));
    auto original =
        value ? llvm::dyn_cast<llvm::Function>(value->getValue()) : nullptr;
    auto inputs = llvm::dyn_cast<llvm::MDNode>(entry->getOperand(2));
    if (!original || !inputs) {
      error = "Invalid AIR fragment function";
      return false;
    }
    int position = -1;
    bool rootSignature = false, reservedBuffer = false;
    for (const auto &operand : inputs->operands()) {
      auto input = llvm::dyn_cast<llvm::MDNode>(operand);
      if (!input)
        continue;
      bool indirect = false, namedRoot = false, buffer = false;
      for (unsigned j = 1; j < input->getNumOperands(); ++j) {
        auto tag = llvm::dyn_cast<llvm::MDString>(input->getOperand(j));
        if (!tag)
          continue;
        indirect |= tag->getString() == "air.indirect_buffer";
        buffer |= tag->getString() == "air.buffer";
        if (tag->getString() == "air.arg_name" &&
            j + 1 < input->getNumOperands()) {
          auto name = llvm::dyn_cast<llvm::MDString>(input->getOperand(j + 1));
          namedRoot |= name && name->getString() == "rootsig";
        }
      }
      rootSignature |= indirect && namedRoot;
      for (unsigned i = 1; i < input->getNumOperands(); ++i) {
        auto tag = llvm::dyn_cast<llvm::MDString>(input->getOperand(i));
        if (!tag)
          continue;
        if (tag->getString() == "air.position") {
          auto index = llvm::mdconst::dyn_extract<llvm::ConstantInt>(
              input->getOperand(0));
          if (!index) {
            error = "Invalid AIR position index";
            return false;
          }
          position = int(index->getZExtValue());
        }
        if (tag->getString() == "air.location_index" &&
            i + 1 < input->getNumOperands()) {
          auto index = llvm::mdconst::dyn_extract<llvm::ConstantInt>(
              input->getOperand(i + 1));
          reservedBuffer |= buffer && index && index->getZExtValue() == 28;
        }
      }
    }
    // The pinned D3D12 compiler always supplies its authoritative rootsig
    // indirect-buffer argument, even for an empty root signature. Its encoder
    // path has no guest foveation transport yet: preserve that AIR unchanged.
    if (position < 0 || rootSignature)
      continue;
    if (reservedBuffer) {
      error = "Reserved foveation buffer 28 is already occupied";
      return false;
    }
    if (unsigned(position) >= original->arg_size() ||
        original->getArg(position)->getType() !=
            llvm::FixedVectorType::get(llvm::Type::getFloatTy(context), 4) ||
        !original->use_empty()) {
      error = "Unsupported AIR fragment position signature";
      return false;
    }
    auto mapType = llvm::PointerType::get(llvm::Type::getInt8Ty(context), 2);
    llvm::SmallVector<llvm::Type *, 16> types(
        original->getFunctionType()->param_begin(),
        original->getFunctionType()->param_end());
    types.push_back(mapType);
    const auto name = original->getName().str();
    original->setName(name + ".before_foveation");
    auto replacement = llvm::Function::Create(
        llvm::FunctionType::get(original->getReturnType(), types, false),
        original->getLinkage(), name, module);
    replacement->copyAttributesFrom(original);
    for (auto &arg : original->args())
      arg.replaceAllUsesWith(replacement->getArg(arg.getArgNo()));
    replacement->getBasicBlockList().splice(replacement->end(),
                                            original->getBasicBlockList());
    auto physical = replacement->getArg(position);
    llvm::SmallVector<llvm::User *, 16> users(physical->user_begin(),
                                              physical->user_end());
    llvm::IRBuilder<> builder(
        &*replacement->getEntryBlock().getFirstInsertionPt());
    auto xy = builder.CreateShuffleVector(physical, {0, 1});
    auto decoder = module.getOrInsertFunction(
        "air.map_physical_to_screen_coordinates.v2f32.p2i8.i32",
        llvm::FunctionType::get(xy->getType(),
                                {xy->getType(), mapType, builder.getInt32Ty()},
                                false));
    auto logical = builder.CreateCall(
        decoder,
        {xy, replacement->getArg(types.size() - 1), builder.getInt32(0)},
        "wvr.logical_position");
    llvm::Value *corrected = builder.CreateInsertElement(
        physical, builder.CreateExtractElement(logical, uint64_t(0)),
        uint64_t(0));
    corrected = builder.CreateInsertElement(
        corrected, builder.CreateExtractElement(logical, uint64_t(1)),
        uint64_t(1));
    for (auto user : users)
      user->replaceUsesOfWith(physical, corrected);
    replacement->removeFnAttr(llvm::Attribute::ReadNone);
    replacement->removeFnAttr(llvm::Attribute::ReadOnly);
    auto str = [&](const char *s) -> llvm::Metadata * {
      return llvm::MDString::get(context, s);
    };
    auto integer = [&](unsigned v) -> llvm::Metadata * {
      return llvm::ConstantAsMetadata::get(builder.getInt32(v));
    };
    llvm::SmallVector<llvm::Metadata *, 16> args;
    for (const auto &operand : inputs->operands())
      args.push_back(operand.get());
    args.push_back(llvm::MDNode::get(
        context,
        {integer(types.size() - 1), str("air.buffer"),
         str("air.location_index"), integer(28), integer(1), str("air.read"),
         str("air.address_space"), integer(2), str("air.arg_type_name"),
         str("metal::rasterization_rate_map_data"), str("air.arg_name"),
         str("wvr_rate_map")}));
    fragments->setOperand(
        n, llvm::MDNode::get(context, {llvm::ValueAsMetadata::get(replacement),
                                       entry->getOperand(1).get(),
                                       llvm::MDNode::get(context, args)}));
    original->eraseFromParent();
  }
  module.getOrInsertNamedMetadata("wvr.foveation.position.v1")
      ->addOperand(llvm::MDNode::get(context, {}));
  return true;
}
