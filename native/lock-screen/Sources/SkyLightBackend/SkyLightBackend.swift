// Private SkyLight wrappers, dlopen'd by `t3-glass-card live-lock --private-skylight`; one export per function.
// Call sequence follows SkyLightWindow by Lakr233 (MIT, see NOTICE). Show, hide, level, add and destroy are void:
// their w0 is not a status. Ordering and failure policy live in Sources/Core/PrivatePlacement.swift.

import Foundation

private let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
private let addWindowsOptions: Int32 = 7

private typealias MainConnectionID = @convention(c) () -> Int32
private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Void
private typealias SpacesCall = @convention(c) (Int32, CFArray) -> Void
private typealias SpaceAddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Void

private let requiredSymbols = [
    "SLSMainConnectionID",
    "SLSSpaceCreate",
    "SLSSpaceSetAbsoluteLevel",
    "SLSShowSpaces",
    "SLSHideSpaces",
    "SLSSpaceAddWindowsAndRemoveFromSpaces",
]

private struct SkyLight {
    let mainConnectionID: MainConnectionID
    let spaceCreate: SpaceCreate
    let setAbsoluteLevel: SpaceSetAbsoluteLevel
    let showSpaces: SpacesCall
    let hideSpaces: SpacesCall
    let addWindows: SpaceAddWindows
    let destroy: SpaceDestroy?

    static let shared: SkyLight? = {
        guard let handle = dlopen(skyLightPath, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let main = symbol("SLSMainConnectionID", MainConnectionID.self),
              let create = symbol("SLSSpaceCreate", SpaceCreate.self),
              let level = symbol("SLSSpaceSetAbsoluteLevel", SpaceSetAbsoluteLevel.self),
              let show = symbol("SLSShowSpaces", SpacesCall.self),
              let hide = symbol("SLSHideSpaces", SpacesCall.self),
              let add = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", SpaceAddWindows.self)
        else { return nil }
        return SkyLight(
            mainConnectionID: main, spaceCreate: create, setAbsoluteLevel: level,
            showSpaces: show, hideSpaces: hide, addWindows: add,
            destroy: symbol("SLSSpaceDestroy", SpaceDestroy.self)
        )
    }()
}

private var connection: Int32 = 0

private func spaceList(_ space: UInt64) -> CFArray { [NSNumber(value: space)] as CFArray }

private func windowList(_ windowNumber: Int32) -> CFArray { [NSNumber(value: windowNumber)] as CFArray }

/// 0 when every required symbol resolves; otherwise bit i is set for missing requiredSymbols[i]; -1 if SkyLight won't load.
@_cdecl("t3skl_probe")
public func t3sklProbe() -> Int32 {
    guard let handle = dlopen(skyLightPath, RTLD_NOW | RTLD_LOCAL) else { return -1 }
    var missing: Int32 = 0
    for (index, name) in requiredSymbols.enumerated() where dlsym(handle, name) == nil {
        missing |= 1 << Int32(index)
    }
    return missing
}

/// SLSSpaceCreate(cid, 1, 0); the new space ID, or 0 on failure (including SkyLight not loading).
@_cdecl("t3skl_space_create")
public func t3sklSpaceCreate() -> UInt64 {
    guard let sls = SkyLight.shared else { return 0 }
    if connection == 0 { connection = sls.mainConnectionID() }
    return sls.spaceCreate(connection, 1, 0)
}

@_cdecl("t3skl_set_absolute_level")
public func t3sklSetAbsoluteLevel(_ space: UInt64, _ level: Int32) {
    SkyLight.shared?.setAbsoluteLevel(connection, space, level)
}

@_cdecl("t3skl_show_space")
public func t3sklShowSpace(_ space: UInt64) {
    SkyLight.shared?.showSpaces(connection, spaceList(space))
}

@_cdecl("t3skl_add_window")
public func t3sklAddWindow(_ space: UInt64, _ windowNumber: Int32) {
    SkyLight.shared?.addWindows(connection, space, windowList(windowNumber), addWindowsOptions)
}

@_cdecl("t3skl_hide_space")
public func t3sklHideSpace(_ space: UInt64) {
    SkyLight.shared?.hideSpaces(connection, spaceList(space))
}

/// 1 once the void SLSSpaceDestroy returned; 0 if it is not exported (it is optional) or SkyLight won't load.
@_cdecl("t3skl_destroy_space")
public func t3sklDestroySpace(_ space: UInt64) -> Int32 {
    guard let destroy = SkyLight.shared?.destroy else { return 0 }
    destroy(connection, space)
    return 1
}
