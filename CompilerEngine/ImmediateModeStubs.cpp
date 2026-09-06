#include "swift/Immediate/Immediate.h"

// XTool Mobile is an AOT-only compiler engine. Swift 6.3.2's FrontendTool
// still contains references to immediate/JIT entry points even when
// SWIFT_BUILD_IMMEDIATE_MODE=OFF. We intentionally do not link swiftImmediate
// (which would pull the JIT stack into the iOS dylib), so provide fail-closed
// definitions for those two entry points instead.
//
// These functions are never expected to run in XTool Mobile because the app
// invokes normal frontend compilation actions, not ActionType::Immediate.

namespace swift {

int RunImmediately(CompilerInstance &,
                   const ProcessCmdLine &,
                   const IRGenOptions &,
                   const SILOptions &,
                   std::unique_ptr<SILModule> &&) {
  return 1;
}

int RunImmediatelyFromAST(CompilerInstance &) {
  return 1;
}

} // namespace swift
