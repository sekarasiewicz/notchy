import CoreGraphics

// Private SkyLight/CoreGraphics symbols. These are the only reliable way to ask
// the window server which windows are status items and where they are right now.
// Not App Store safe. Signatures follow what Ice uses in production.

typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
nonisolated func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
nonisolated func CGSGetWindowCount(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetOnScreenWindowCount")
nonisolated func CGSGetOnScreenWindowCount(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetOnScreenWindowList")
nonisolated func CGSGetOnScreenWindowList(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
nonisolated func CGSGetProcessMenuBarWindowList(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetScreenRectForWindow")
nonisolated func CGSGetScreenRectForWindow(
    _ cid: CGSConnectionID,
    _ wid: CGWindowID,
    _ outRect: inout CGRect
) -> CGError
