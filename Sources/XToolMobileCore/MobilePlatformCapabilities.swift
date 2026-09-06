import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct MobilePlatformCapabilities: Sendable, Hashable {
    public let operatingSystemVersion: String
    public let architecture: String
    public let physicalMemory: UInt64
    public let homeDirectory: String
    public let temporaryDirectory: String
    public let isRunningOnIOSFamily: Bool

    public static func current(processInfo: ProcessInfo = .processInfo) -> Self {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        #if os(iOS)
        let isRunningOnIOSFamily = true
        #else
        let isRunningOnIOSFamily = false
        #endif

        return Self(
            operatingSystemVersion: processInfo.operatingSystemVersionString,
            architecture: architecture,
            physicalMemory: processInfo.physicalMemory,
            homeDirectory: NSHomeDirectory(),
            temporaryDirectory: NSTemporaryDirectory(),
            isRunningOnIOSFamily: isRunningOnIOSFamily
        )
    }

    /// Performs a harmless virtual-address-space reservation test.
    ///
    /// This does not prove a particular entitlement is present; it gives the
    /// mobile prototype a concrete runtime signal before loading Swift/LLVM.
    public static func canReserveAddressSpace(bytes: Int) -> Bool {
        guard bytes > 0 else { return false }

        #if canImport(Darwin)
        let pointer = mmap(nil, bytes, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard pointer != MAP_FAILED else { return false }
        munmap(pointer, bytes)
        return true
        #else
        return false
        #endif
    }
}
