# Isolated Windows backend for XTool Mobile.
#
# The main XTool compiler engine already contains Clang. For Windows jobs it
# emits target-neutral LLVM bitcode first; this smaller dylib only lowers that
# bitcode through LLVM's X86 backend and links the resulting COFF object with
# lldCOFF. No Swift project and no second Clang frontend are built here.

if(NOT TARGET LLVMX86CodeGen)
  message(FATAL_ERROR "XToolWindowsBackend requires LLVM's X86 code generator")
endif()

if(NOT TARGET LLVMBitReader)
  message(FATAL_ERROR "XToolWindowsBackend requires LLVMBitReader")
endif()

if(NOT TARGET lldCOFF)
  message(FATAL_ERROR "XToolWindowsBackend requires lldCOFF")
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
  string(REPLACE "-Wl,-z,defs" "" CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS}")

  if(TARGET LLVMSupport)
    get_target_property(_xtool_windows_support_link_libs LLVMSupport LINK_LIBRARIES)
    if(_xtool_windows_support_link_libs AND NOT _xtool_windows_support_link_libs STREQUAL "_xtool_windows_support_link_libs-NOTFOUND")
      list(REMOVE_ITEM _xtool_windows_support_link_libs rt)
      set_property(TARGET LLVMSupport PROPERTY LINK_LIBRARIES "${_xtool_windows_support_link_libs}")
    endif()

    get_target_property(_xtool_windows_support_interface_libs LLVMSupport INTERFACE_LINK_LIBRARIES)
    if(_xtool_windows_support_interface_libs AND NOT _xtool_windows_support_interface_libs STREQUAL "_xtool_windows_support_interface_libs-NOTFOUND")
      list(REMOVE_ITEM _xtool_windows_support_interface_libs rt)
      set_property(TARGET LLVMSupport PROPERTY INTERFACE_LINK_LIBRARIES "${_xtool_windows_support_interface_libs}")
    endif()
  endif()
endif()

add_library(XToolWindowsBackend SHARED
  XToolWindowsBackend.cpp
)

target_include_directories(XToolWindowsBackend PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${LLVM_MAIN_INCLUDE_DIR}"
  "${LLVM_BINARY_DIR}/include"
  "${LLVM_MAIN_SRC_DIR}/../lld/include"
  "${LLVM_BINARY_DIR}/tools/lld/include"
)

target_compile_features(XToolWindowsBackend PRIVATE cxx_std_17)

set(XTOOL_WINDOWS_BACKEND_VERSION
  "swift-6.3.2-RELEASE+llvm-bitcode+x86+lld-coff"
  CACHE STRING
  "Version string reported by the XTool Windows backend"
  FORCE
)
target_compile_definitions(XToolWindowsBackend PRIVATE
  XTOOL_WINDOWS_BACKEND_VERSION="${XTOOL_WINDOWS_BACKEND_VERSION}"
)

target_link_libraries(XToolWindowsBackend PRIVATE
  LLVMX86CodeGen
  LLVMBitReader
  LLVMCore
  LLVMTargetParser
  LLVMSupport
  lldCOFF
  lldCommon
)

# Cross-linking the arm64 iOS dylib from Linux needs the same source-matched
# Mach-O linker used by the main compiler engine. This linker is only used to
# produce the backend dylib itself; the dylib embeds lldCOFF for Windows output.
set(XTOOL_MACHO_LINKER "" CACHE FILEPATH "Patched host ld64.lld used for Linux-to-iOS linking")
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
  if(XTOOL_MACHO_LINKER)
    if(NOT EXISTS "${XTOOL_MACHO_LINKER}")
      message(FATAL_ERROR "XTOOL_MACHO_LINKER does not exist: ${XTOOL_MACHO_LINKER}")
    endif()

    target_link_options(XToolWindowsBackend PRIVATE
      "--ld-path=${XTOOL_MACHO_LINKER}"
      "-Wl,-arch,arm64"
      "-Wl,-platform_version,ios,${CMAKE_OSX_DEPLOYMENT_TARGET},${CMAKE_OSX_DEPLOYMENT_TARGET}"
      "-Wl,-syslibroot,${CMAKE_OSX_SYSROOT}"
    )
  else()
    target_link_options(XToolWindowsBackend PRIVATE "-fuse-ld=lld")
  endif()
endif()

set_target_properties(XToolWindowsBackend PROPERTIES
  OUTPUT_NAME "XToolWindowsBackend"
  PREFIX "lib"
  POSITION_INDEPENDENT_CODE ON
  MACOSX_RPATH OFF
  BUILD_WITH_INSTALL_RPATH OFF
  SKIP_BUILD_RPATH TRUE
  INSTALL_RPATH ""
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/../package"
)
