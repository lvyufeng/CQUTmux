import SwiftUI
import UIKit

/// The alternate icons the app ships, and which one is showing.
///
/// The names here must match `CFBundleAlternateIcons` in `project.yml` — iOS
/// rejects a name it was not told about, and `setAlternateIconName` then fails
/// with a message that does not say which list to go and look in.
@Observable
final class AppIconStore {
    /// A shipped icon choice. `primary` is the app's own icon, which is
    /// selected by passing `nil` to `setAlternateIconName` rather than by name.
    enum Choice: String, CaseIterable, Identifiable {
        case primary
        case nebula = "CQUTmuxNebula"
        case aurora = "CQUTmuxAurora"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .primary: "Moshi Green"
            case .nebula: "Nebula"
            case .aurora: "Aurora"
            }
        }

        /// What iOS wants: a name for an alternate, `nil` for the primary.
        var alternateName: String? { self == .primary ? nil : rawValue }

        /// The preview image. The primary comes from the asset catalog; the
        /// alternates are loose files, so they are loaded by name.
        var image: UIImage? {
            switch self {
            case .primary: UIImage(named: "AppIcon")
            case .nebula: UIImage(named: "Nebula60x60@3x")
            case .aurora: UIImage(named: "Aurora60x60@3x")
            }
        }
    }

    /// What the system currently reports, read on init rather than stored:
    /// the icon can be changed from outside the app (Settings › Home Screen),
    /// and a stored copy would then be wrong.
    private(set) var current: Choice
    private(set) var problem: String?

    private let application: UIApplication

    init(application: UIApplication = .shared) {
        self.application = application
        let name = application.alternateIconName
        current = Choice.allCases.first { $0.alternateName == name } ?? .primary
    }

    /// iOS shows its own "You have changed the icon" alert on the first change;
    /// it cannot be suppressed, so this does not try to draw a second one.
    func select(_ choice: Choice) {
        guard application.supportsAlternateIcons else {
            problem = "This device doesn't support alternate icons."
            return
        }
        application.setAlternateIconName(choice.alternateName) { [weak self] error in
            guard let self else { return }
            if let error {
                // The failure is almost always a name that is not in
                // `CFBundleAlternateIcons`; the system's error does not say so,
                // and the name is the only thing that can be wrong here.
                problem = "Couldn't change the icon: \(error.localizedDescription)"
                return
            }
            current = choice
            problem = nil
        }
    }
}

struct AppIconSettingsView: View {
    @Environment(AppIconStore.self) private var icons
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        List {
            Section {
                ForEach(AppIconStore.Choice.allCases) { choice in
                    Button {
                        icons.select(choice)
                    } label: {
                        HStack(spacing: 14) {
                            preview(choice)
                            Text(choice.label).foregroundStyle(.primary)
                            Spacer()
                            if icons.current == choice {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(themes.current.accentColor)
                            }
                        }
                    }
                }
            } footer: {
                Text("iOS shows its own confirmation the first time you change this.")
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Icon not changed", isPresented: .constant(icons.problem != nil)) {
            Button("OK") {}
        } message: {
            Text(icons.problem ?? "")
        }
    }

    @ViewBuilder
    private func preview(_ choice: AppIconStore.Choice) -> some View {
        Group {
            if let image = choice.image {
                Image(uiImage: image).resizable()
            } else {
                // A missing file is not worth failing the screen over, but it
                // should be visible rather than silently blank.
                Image(systemName: "app.dashed")
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}