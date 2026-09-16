#include "XToolCompilerEngine.h"

#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/FrontendTool/Utils.h"
#include "lld/Common/Driver.h"
#include "swift/Basic/InitializeSwiftModules.h"
#include "swift/FrontendTool/FrontendTool.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"

#include <atomic>
#include <cstddef>
#include <memory>
#include <mutex>

#ifndef XTOOL_COMPILER_ENGINE_VERSION
#define XTOOL_COMPILER_ENGINE_VERSION "swift-frontend-engine"
#endif

LLD_HAS_DRIVER(macho)

namespace {

void initializeClangTargetsOnce() {
    static std::once_flag once;
    std::call_once(once, [] {
        llvm::InitializeAllTargets();
        llvm::InitializeAllTargetMCs();
        llvm::InitializeAllAsmPrinters();
        llvm::InitializeAllAsmParsers();
    });
}

void initializeSwiftCompilerModulesOnce() {
    static std::once_flag once;
    std::call_once(once, [] {
        initializeSwiftModules();
    });
}

std::atomic<bool> gLLDCanRunAgain{true};

int32_t runMachOLLD(int32_t argc, const char *const *argv) {
    if (argc < 0 || (argc > 0 && argv == nullptr)) {
        return 64;
    }

    if (!gLLDCanRunAgain.load(std::memory_order_acquire)) {
        llvm::errs() << "xtool: embedded Mach-O LLD cannot safely be re-entered after the previous link\n";
        return 70;
    }

    llvm::SmallVector<const char *, 32> arguments;
    arguments.push_back("ld64.lld");
    if (argc > 0) {
        arguments.append(argv, argv + static_cast<size_t>(argc));
    }

    const lld::DriverDef drivers[] = {
        {lld::Darwin, &lld::macho::link}
    };
    const lld::Result result = lld::lldMain(
        arguments,
        llvm::outs(),
        llvm::errs(),
        drivers
    );

    if (!result.canRunAgain) {
        gLLDCanRunAgain.store(false, std::memory_order_release);
    }

    return static_cast<int32_t>(result.retCode);
}

} // namespace

extern "C" int32_t xtool_swift_frontend_run(
    int32_t argc,
    const char *const *argv
) {
    if (argc < 0 || (argc > 0 && argv == nullptr)) {
        return 64;
    }

    initializeSwiftCompilerModulesOnce();

    llvm::ArrayRef<const char *> arguments(argv, static_cast<size_t>(argc));
    const int32_t result = static_cast<int32_t>(
        swift::performFrontend(arguments, "xtool-mobile", nullptr, nullptr)
    );

    llvm::outs().flush();
    llvm::errs().flush();

    return result;
}

extern "C" int32_t xtool_clang_frontend_run(
    int32_t argc,
    const char *const *argv
) {
    if (argc < 0 || (argc > 0 && argv == nullptr)) {
        return 64;
    }

    initializeClangTargetsOnce();

    auto invocation = std::make_shared<clang::CompilerInvocation>();
    clang::CompilerInstance compiler(invocation);

    compiler.createDiagnostics();
    if (!compiler.hasDiagnostics()) {
        return 70;
    }

    llvm::ArrayRef<const char *> arguments(argv, static_cast<size_t>(argc));
    if (!clang::CompilerInvocation::CreateFromArgs(
            *invocation,
            arguments,
            compiler.getDiagnostics(),
            "xtool-clang")) {
        return 1;
    }

    compiler.createVirtualFileSystem();

    return clang::ExecuteCompilerInvocation(&compiler) ? 0 : 1;
}

extern "C" int32_t xtool_lld_macho_run(
    int32_t argc,
    const char *const *argv
) {
    return runMachOLLD(argc, argv);
}

extern "C" const char *xtool_compiler_engine_version(void) {
    return XTOOL_COMPILER_ENGINE_VERSION;
}
