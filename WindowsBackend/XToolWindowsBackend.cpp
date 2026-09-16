#include "XToolWindowsBackend.h"

#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/FrontendTool/Utils.h"
#include "lld/Common/Driver.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"

#include <atomic>
#include <cstddef>
#include <memory>
#include <mutex>

#ifndef XTOOL_WINDOWS_BACKEND_VERSION
#define XTOOL_WINDOWS_BACKEND_VERSION "windows-backend"
#endif

LLD_HAS_DRIVER(coff)

namespace {

void initializeX86TargetsOnce() {
    static std::once_flag once;
    std::call_once(once, [] {
        // This dylib is compiled for arm64 iOS, but its LLVM build contains the
        // X86 target backend so Clang can emit x86_64 Windows objects.
        llvm::InitializeAllTargetInfos();
        llvm::InitializeAllTargets();
        llvm::InitializeAllTargetMCs();
        llvm::InitializeAllAsmPrinters();
        llvm::InitializeAllAsmParsers();
    });
}

std::atomic<bool> gLLDCanRunAgain{true};

int32_t runCOFFLLD(int32_t argc, const char *const *argv) {
    if (argc < 0 || (argc > 0 && argv == nullptr)) {
        return 64;
    }

    if (!gLLDCanRunAgain.load(std::memory_order_acquire)) {
        llvm::errs() << "xtool-windows: embedded COFF LLD cannot safely be re-entered after the previous link\n";
        return 70;
    }

    llvm::SmallVector<const char *, 32> arguments;
    arguments.push_back("lld-link");
    if (argc > 0) {
        arguments.append(argv, argv + static_cast<size_t>(argc));
    }

    const lld::DriverDef drivers[] = {
        {lld::WinLink, &lld::coff::link}
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

extern "C" int32_t xtool_windows_clang_run(
    int32_t argc,
    const char *const *argv
) {
    if (argc < 0 || (argc > 0 && argv == nullptr)) {
        return 64;
    }

    initializeX86TargetsOnce();

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
            "xtool-windows-clang")) {
        return 1;
    }

    compiler.createVirtualFileSystem();
    return clang::ExecuteCompilerInvocation(&compiler) ? 0 : 1;
}

extern "C" int32_t xtool_windows_lld_coff_run(
    int32_t argc,
    const char *const *argv
) {
    return runCOFFLLD(argc, argv);
}

extern "C" const char *xtool_windows_backend_version(void) {
    return XTOOL_WINDOWS_BACKEND_VERSION;
}
