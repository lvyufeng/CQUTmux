import SwiftUI
import UIKit
import PhotosUI

/// The photo library, via `PHPickerViewController`.
///
/// `PHPicker` rather than `UIImagePickerController(.photoLibrary)` because it
/// runs out of process and needs **no** photo-library permission and therefore
/// no `NSPhotoLibraryUsageDescription` — the system shows its own picker and
/// hands back only what was chosen. The older picker demanded full-library
/// access to pick one image, which is a permission prompt that buys nothing.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoLibraryPicker
        init(_ parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // The sheet closes either way; a cancelled pick just picks nothing.
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                // `loadObject` calls back off the main thread; touching the
                // SwiftUI state that presents the annotator has to be on it.
                DispatchQueue.main.async { self.parent.onPick(image) }
            }
        }
    }
}

/// The camera, via `UIImagePickerController(sourceType: .camera)`.
///
/// The camera has no SwiftUI-native equivalent for a still capture, and this is
/// the one path that needs `NSCameraUsageDescription` — the same key the QR
/// scanner uses, which is why the string covers both.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)
            guard let image = info[.originalImage] as? UIImage else { return }
            parent.onPick(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}