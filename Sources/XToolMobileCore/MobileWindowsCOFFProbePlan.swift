import Foundation

/// Minimal on-device Windows compiler probe:
///
/// C source -> x86_64 COFF object -> PE32+ executable.
///
/// It intentionally uses no Windows SDK headers, CRT, startup object or import
/// libraries. The executable entry point is the C `main` function itself and
/// simply returns 42. That keeps the first Windows probe focused on proving the
/// X86 LLVM backend and COFF LLD driver inside XTool Mobile.
public struct MobileWindowsCOFFProbePlan: Sendable, Hashable {
    public let sourceURL: URL
    public let objectURL: URL
    public let executableURL: URL
    public let targetTriple: String
    public let clangArguments: [String]
    public let lldArguments: [String]

    public static func helloReturn42(
        workspace: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )

        let source = workspace.appendingPathComponent("HelloWindows.c")
        let object = workspace.appendingPathComponent("HelloWindows.obj")
        let executable = workspace.appendingPathComponent("HelloWindows.exe")
        let target = "x86_64-pc-windows-msvc"

        let sourceText = """
        __attribute__((noinline))
        int main(void) {
            return 42;
        }
        """
        try Data(sourceText.utf8).write(to: source, options: .atomic)
        try? fileManager.removeItem(at: object)
        try? fileManager.removeItem(at: executable)

        // CompilerInvocation::CreateFromArgs consumes cc1-style arguments.
        // No Windows headers are required for this freestanding probe.
        let clangArguments = [
            "-triple", target,
            "-emit-obj",
            "-x", "c",
            "-O2",
            "-ffreestanding",
            "-fno-stack-protector",
            source.path,
            "-o", object.path,
        ]

        // Link the object directly as a PE32+ console image. `main` is the real
        // PE entry point; no CRT or default libraries are involved.
        let lldArguments = [
            "/machine:x64",
            "/subsystem:console",
            "/entry:main",
            "/nodefaultlib",
            "/fixed",
            "/out:\(executable.path)",
            object.path,
        ]

        return Self(
            sourceURL: source,
            objectURL: object,
            executableURL: executable,
            targetTriple: target,
            clangArguments: clangArguments,
            lldArguments: lldArguments
        )
    }

    public func inspectExecutable() throws -> MobileWindowsPEInspection {
        try MobileWindowsPEInspection(url: executableURL)
    }
}

public struct MobileWindowsPEInspection: Sendable, Hashable {
    public let fileSize: Int
    public let machine: UInt16
    public let optionalMagic: UInt16
    public let sectionCount: UInt16
    public let entryRVA: UInt32
    public let entrySection: String
    public let entryPreview: String
    public let phase17EntryCompatible: Bool

    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])

        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw MobileWindowsPEInspectionError.invalidPE(message) }
        }
        func u16(_ offset: Int) throws -> UInt16 {
            try require(offset >= 0 && offset + 2 <= data.count, "u16 outside file")
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        func u32(_ offset: Int) throws -> UInt32 {
            try require(offset >= 0 && offset + 4 <= data.count, "u32 outside file")
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }

        try require(data.count >= 0x40, "file is too small")
        try require(try u16(0) == 0x5A4D, "missing MZ signature")
        let peOffset = Int(try u32(0x3C))
        try require(peOffset >= 0 && peOffset + 24 <= data.count, "PE header outside file")
        try require(try u32(peOffset) == 0x0000_4550, "missing PE signature")

        let coff = peOffset + 4
        let machine = try u16(coff)
        let sectionCount = try u16(coff + 2)
        let optionalSize = Int(try u16(coff + 16))
        let optional = coff + 20
        try require(optionalSize >= 112 && optional + optionalSize <= data.count, "invalid PE32+ optional header")
        let magic = try u16(optional)
        let entryRVA = try u32(optional + 16)
        try require(machine == 0x8664, "machine is not AMD64")
        try require(magic == 0x20B, "optional header is not PE32+")

        let sectionTable = optional + optionalSize
        try require(sectionCount > 0, "PE has no sections")
        try require(sectionTable + Int(sectionCount) * 40 <= data.count, "section table outside file")

        var foundName = ""
        var entryFileOffset: Int?
        for index in 0..<Int(sectionCount) {
            let section = sectionTable + index * 40
            let nameBytes = data[section..<(section + 8)]
            let name = String(bytes: nameBytes.prefix { $0 != 0 }, encoding: .utf8) ?? "?"
            let virtualSize = try u32(section + 8)
            let virtualAddress = try u32(section + 12)
            let rawSize = try u32(section + 16)
            let rawPointer = try u32(section + 20)
            let span = max(virtualSize, rawSize)
            if entryRVA >= virtualAddress && entryRVA < virtualAddress &+ span {
                let delta = entryRVA - virtualAddress
                try require(delta < rawSize, "entry point is not backed by raw section data")
                let offset = Int(rawPointer &+ delta)
                try require(offset >= 0 && offset < data.count, "entry point outside file")
                foundName = name
                entryFileOffset = offset
                break
            }
        }

        guard let entryFileOffset else {
            throw MobileWindowsPEInspectionError.invalidPE("entry RVA is not inside a section")
        }

        let previewCount = min(16, data.count - entryFileOffset)
        let previewBytes = data[entryFileOffset..<(entryFileOffset + previewCount)]
        let preview = previewBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let expected: [UInt8] = [0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3]
        let compatible = previewBytes.count >= expected.count
            && Array(previewBytes.prefix(expected.count)) == expected

        self.fileSize = data.count
        self.machine = machine
        self.optionalMagic = magic
        self.sectionCount = sectionCount
        self.entryRVA = entryRVA
        self.entrySection = foundName
        self.entryPreview = preview
        self.phase17EntryCompatible = compatible
    }
}

public enum MobileWindowsPEInspectionError: Error, CustomStringConvertible, Sendable {
    case invalidPE(String)

    public var description: String {
        switch self {
        case .invalidPE(let reason):
            return "Windows PE inspection failed: \(reason)"
        }
    }
}
