#include "XToolWindowsBackend.h"

#include "lld/Common/Driver.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/CodeGen.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetOptions.h"
#include "llvm/TargetParser/Triple.h"

#include <atomic>
#include <cstddef>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

#ifndef XTOOL_WINDOWS_BACKEND_VERSION
#define XTOOL_WINDOWS_BACKEND_VERSION "windows-backend"
#endif

LLD_HAS_DRIVER(coff)

namespace {

void initializeX86TargetsOnce() {
    static std::once_flag once;
    std::call_once(once, [] {
        // Only X86 is built into this dylib. InitializeAll* therefore registers
        // just the x86/x86-64 backend while the dylib itself remains arm64 iOS.
        llvm::InitializeAllTargetInfos();
        llvm::InitializeAllTargets();
        llvm::InitializeAllTargetMCs();
        llvm::InitializeAllAsmPrinters();
    });
}

std::atomic<bool> gLLDCanRunAgain{true};

int32_t emitCOFFObject(
    const char *inputPath,
    const char *outputPath,
    const char *tripleText
) {
    if (inputPath == nullptr || outputPath == nullptr) {
        return 64;
    }

    initializeX86TargetsOnce();

    const std::string tripleString =
        (tripleText != nullptr && tripleText[0] != '\0')
            ? tripleText
            : "x86_64-pc-windows-msvc";
    const llvm::Triple triple(tripleString);

    auto bufferOrError = llvm::MemoryBuffer::getFile(inputPath);
    if (!bufferOrError) {
        llvm::errs() << "xtool-windows: could not read bitcode: "
                     << bufferOrError.getError().message() << "\n";
        return 66;
    }

    llvm::LLVMContext context;
    auto moduleOrError = llvm::parseBitcodeFile(
        (*bufferOrError)->getMemBufferRef(),
        context
    );
    if (!moduleOrError) {
        llvm::logAllUnhandledErrors(
            moduleOrError.takeError(),
            llvm::errs(),
            "xtool-windows: invalid LLVM bitcode: "
        );
        return 65;
    }

    std::unique_ptr<llvm::Module> module = std::move(*moduleOrError);
    module->setTargetTriple(triple);

    std::string lookupError;
    const llvm::Target *target = llvm::TargetRegistry::lookupTarget(
        triple.getTriple(),
        lookupError
    );
    if (target == nullptr) {
        llvm::errs() << "xtool-windows: X86 target lookup failed: "
                     << lookupError << "\n";
        return 69;
    }

    llvm::TargetOptions options;
    std::unique_ptr<llvm::TargetMachine> targetMachine(
        target->createTargetMachine(
            triple,
            "generic",
            "",
            options,
            std::nullopt,
            std::nullopt,
            llvm::CodeGenOptLevel::Default,
            false
        )
    );
    if (!targetMachine) {
        llvm::errs() << "xtool-windows: could not create x86_64 TargetMachine\n";
        return 70;
    }

    module->setDataLayout(targetMachine->createDataLayout());

    std::error_code outputError;
    llvm::raw_fd_ostream output(
        outputPath,
        outputError,
        llvm::sys::fs::OF_None
    );
    if (outputError) {
        llvm::errs() << "xtool-windows: could not create COFF object: "
                     << outputError.message() << "\n";
        return 73;
    }

    llvm::legacy::PassManager passes;
    if (targetMachine->addPassesToEmitFile(
            passes,
            output,
            nullptr,
            llvm::CodeGenFileType::ObjectFile)) {
        llvm::errs() << "xtool-windows: X86 backend cannot emit object files\n";
        return 70;
    }

    passes.run(*module);
    output.flush();
    return 0;
}

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

extern "C" int32_t xtool_windows_codegen_run(
    int32_t argc,
    const char *const *argv
) {
    if (argc < 2 || argv == nullptr) {
        return 64;
    }

    const char *triple = argc >= 3 ? argv[2] : "x86_64-pc-windows-msvc";
    return emitCOFFObject(argv[0], argv[1], triple);
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
