import Foundation

/// Where an image attached to the terminal can come from.
///
/// The decision of *which* sources to offer is the part that fails silently: a
/// Clipboard row with nothing on the clipboard looks like a broken button
/// rather than a missing image, and a camera row on a device without a camera
/// does the same. So the rule lives here — Foundation-only, no UIKit — and
/// `scripts/attachment-check.sh` drives it directly rather than trusting a
/// screenshot to show which rows should have been there.
enum AttachmentSource: String, CaseIterable, Identifiable {
    case camera
    case photoLibrary
    case files
    case clipboard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camera: "Camera"
        case .photoLibrary: "Photo Library"
        case .files: "Files"
        case .clipboard: "Clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .camera: "camera"
        case .photoLibrary: "photo.on.rectangle"
        case .files: "folder"
        case .clipboard: "doc.on.clipboard"
        }
    }

    /// The sources to offer, in the order they are shown.
    ///
    /// Clipboard is last and only when there is an image on it — a row that
    /// opens onto "nothing on the clipboard" is a row that should not have been
    /// drawn. Camera is likewise conditional on the device. Photo Library and
    /// Files are always offered: both are always present on an iPhone, and the
    /// photo picker is `PHPickerViewController`, which needs no library
    /// permission and so has nothing to be unavailable about.
    ///
    /// The parameters are explicit rather than read from UIKit here so the
    /// ordering and the conditionals are one pure function a check can pin.
    static func available(
        hasCamera: Bool,
        hasPhotoLibrary: Bool = true,
        hasClipboardImage: Bool
    ) -> [AttachmentSource] {
        var out: [AttachmentSource] = []
        if hasCamera { out.append(.camera) }
        if hasPhotoLibrary { out.append(.photoLibrary) }
        out.append(.files)
        if hasClipboardImage { out.append(.clipboard) }
        return out
    }
}