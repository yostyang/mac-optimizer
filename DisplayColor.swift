import AppKit
import ColorSync
import CoreGraphics

struct DisplayProfile: Identifiable, Equatable {
    static func sameURL(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
    }
    var id: String { url.path }
    var name: String
    var url: URL
}
struct DisplayProfileState: Equatable {
    var current: URL?
    var overrideURL: URL?
    var choices: [DisplayProfile] = []
    var factoryDefault: URL?
}
protocol DisplayProfileSystem: AnyObject {
    func read(_ id: CGDirectDisplayID) -> DisplayProfileState
    func apply(_ id: CGDirectDisplayID, url: URL?) -> Bool
}
final class ColorSyncProfiles: DisplayProfileSystem {
    static func profile(_ url: URL) -> DisplayProfile? {
        guard let data = try? Data(contentsOf: url), data.count >= 128,
              String(decoding: data[12..<16], as: UTF8.self) == "mntr",
              let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        let name = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String? ?? url.deletingPathExtension().lastPathComponent
        return DisplayProfile(name: name, url: url.standardizedFileURL)
    }
    func read(_ id: CGDirectDisplayID) -> DisplayProfileState {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return DisplayProfileState() }
        let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass!.takeUnretainedValue(), uuid)?.takeRetainedValue() as? [String: Any] ?? [:]
        let factory = info[kColorSyncFactoryProfiles!.takeUnretainedValue() as String] as? [String: Any] ?? [:]
        let custom = info[kColorSyncCustomProfiles!.takeUnretainedValue() as String] as? [String: Any] ?? [:]
        let defaultID = factory[kColorSyncDeviceDefaultProfileID!.takeUnretainedValue() as String] as? String ?? "1"
        let active = ColorSyncProfileCreateWithDisplayID(id)?.takeRetainedValue()
        let current = active.flatMap { ColorSyncProfileGetURL($0, nil)?.takeUnretainedValue() as URL? }
        let override = custom[defaultID] as? URL ?? custom[kColorSyncDeviceDefaultProfileID!.takeUnretainedValue() as String] as? URL
        var urls: [URL] = [current, override].compactMap { $0 }
        for value in factory.values {
            if let dict = value as? [String: Any], let url = dict[kColorSyncDeviceProfileURL!.takeUnretainedValue() as String] as? URL { urls.append(url) }
        }
        // Only device-class display profiles from user/admin locations. Do not
        // offer generic RGB working spaces as monitor calibration profiles.
        for folder in [URL(fileURLWithPath: "/Library/ColorSync/Profiles"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/ColorSync/Profiles")] {
            if let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let url as URL in files {
                    if url.lastPathComponent == "Displays" { files.skipDescendants(); continue }
                    if ["icc", "icm"].contains(url.pathExtension.lowercased()) { urls.append(url) }
                }
            }
        }
        var seen = Set<String>()
        let choices = urls.compactMap { Self.profile($0) }.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let defaultProfile = factory[defaultID] as? [String: Any]
        let factoryURL = (defaultProfile?[kColorSyncDeviceProfileURL!.takeUnretainedValue() as String] as? URL)?.standardizedFileURL
        return DisplayProfileState(current: (override ?? current)?.standardizedFileURL, overrideURL: override?.standardizedFileURL, choices: choices, factoryDefault: factoryURL)
    }
    func apply(_ id: CGDirectDisplayID, url: URL?) -> Bool {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
        let value: Any = url.map { $0 as CFURL } ?? kCFNull!
        return ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass!.takeUnretainedValue(), uuid, [
            kColorSyncDeviceDefaultProfileID!.takeUnretainedValue() as String: value,
            kColorSyncProfileUserScope!.takeUnretainedValue() as String: kCFPreferencesCurrentUser,
            kColorSyncProfileHostScope!.takeUnretainedValue() as String: kCFPreferencesCurrentHost
        ] as CFDictionary)
    }
}

struct DDCOperationKey: Hashable {
    var display: CGDirectDisplayID
    var code: UInt8
}

/// Ambiguous identical displays stay unmatched: enumeration order is not an identity.
enum DDCIdentity {
    static func match(_ display: DisplayInfo, in services: [AVServiceDDC], displays: [DisplayInfo]) -> AVServiceDDC? {
        guard display.vendor != 0, display.model != 0 else { return nil }
        let candidates = services.filter { $0.vendor == display.vendor && $0.model == display.model && (display.serial == 0 || $0.serial == 0 || $0.serial == display.serial) }
        if display.serial != 0 {
            let exact = candidates.filter { $0.serial == display.serial }
            let same = displays.filter { !$0.builtin && $0.vendor == display.vendor && $0.model == display.model && $0.serial == display.serial }
            if exact.count == 1 && same.count == 1 { return exact[0] }
        }
        let sameModel = displays.filter { !$0.builtin && $0.vendor == display.vendor && $0.model == display.model }
        return candidates.count == 1 && sameModel.count == 1 ? candidates[0] : nil
    }
}
