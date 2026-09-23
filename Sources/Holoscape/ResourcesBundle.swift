import Foundation

#if !SWIFT_PACKAGE
extension Bundle {
    /// Xcode project builds do not synthesize SwiftPM's `Bundle.module` accessor.
    /// The Xcode project copies Holoscape resources into the app bundle, so use
    /// `Bundle.main` to keep resource lookup equivalent outside SwiftPM.
    static var module: Bundle { .main }
}
#endif
