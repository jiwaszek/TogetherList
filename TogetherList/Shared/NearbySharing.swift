import LinkPresentation
import SwiftUI
import TogetherListCore
import UniformTypeIdentifiers

/// Sharing an invitation with someone standing next to you.
///
/// * **Bringing iPhones together** (iOS 17+): iOS asks the frontmost scene what
///   it is showing — `UIWindowScene.activityItemsConfigurationSource` — and offers
///   to AirDrop that. `NearbyShareSource` makes an invitation link that content
///   while its view is on screen.
/// * **Send with AirDrop**: apps can't open AirDrop directly, so `AirDropSheet`
///   shows the share sheet with the other sharing services left out.
enum InvitationSharing {
    /// The invitation link with a proper preview (app icon, "Join “Groceries”…").
    static func configuration(url: URL, listName: String) -> UIActivityItemsConfiguration {
        let configuration = UIActivityItemsConfiguration(objects: [url as NSURL])
        addMetadata(to: configuration, url: url, listName: listName)
        return configuration
    }

    /// Like `configuration(url:listName:)`, but the invitation is only created
    /// when someone actually shares — e.g. when phones are brought together
    /// while a list is open.
    static func lazyConfiguration(listName: String,
                                  makeURL: @escaping @MainActor @Sendable () async throws -> URL) -> UIActivityItemsConfiguration {
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
            Task { @MainActor in
                do { completion(try await makeURL() as NSURL, nil) } catch { completion(nil, error) }
            }
            return nil
        }
        let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
        addMetadata(to: configuration, url: nil, listName: listName)
        return configuration
    }

    private static func addMetadata(to configuration: UIActivityItemsConfiguration, url: URL?, listName: String) {
        let title = L("Join “%@” on TogetherList", listName)
        configuration.metadataProvider = { key in
            switch key {
            case .title:
                return title
            case .messageBody:
                return L("Join my “%@” list on TogetherList:", listName)
            case .linkPresentationMetadata:
                let metadata = LPLinkMetadata()
                metadata.title = title
                if let url {
                    metadata.originalURL = url
                    metadata.url = url
                }
                if let icon = UIImage(named: "ShareIcon") {
                    metadata.iconProvider = NSItemProvider(object: icon)
                    metadata.imageProvider = NSItemProvider(object: icon)
                }
                return metadata
            default:
                return nil
            }
        }
    }
}

/// While this view is on screen, `configuration` is what iOS shares when the
/// user brings their iPhone close to someone else's. Pass nil to offer nothing.
struct NearbyShareSource: UIViewRepresentable {
    let configuration: UIActivityItemsConfiguration?

    func makeUIView(context: Context) -> SourceView {
        let view = SourceView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: SourceView, context: Context) {
        view.configuration = configuration
    }

    final class SourceView: UIView {
        /// Sources currently on screen, most recently shown last. When a sheet
        /// that offered something closes, the screen underneath takes over again.
        private static var visible: [Weak] = []
        private struct Weak { weak var view: SourceView? }

        var configuration: UIActivityItemsConfiguration? {
            didSet {
                activityItemsConfiguration = configuration
                Self.apply(to: window?.windowScene)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            Self.visible.removeAll { $0.view == nil || $0.view === self }
            Self.visible.append(Weak(view: self))
            Self.apply(to: window?.windowScene)
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            guard newWindow == nil, let scene = window?.windowScene else { return }
            Self.visible.removeAll { $0.view == nil || $0.view === self }
            Self.apply(to: scene)
        }

        private static func apply(to scene: UIWindowScene?) {
            guard let scene else { return }
            let current = visible.last { $0.view?.window?.windowScene === scene && $0.view?.configuration != nil }?.view
            // Weak on the scene's side: the view hierarchy keeps the source alive.
            scene.activityItemsConfigurationSource = current
        }
    }
}

/// Presents the share sheet with only AirDrop (and installed share extensions,
/// which apps can't hide) — the closest thing to an "AirDrop" button iOS allows.
@MainActor
enum AirDropSheet {
    static func present(_ configuration: UIActivityItemsConfiguration) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController
        else { return }
        while let presented = top.presentedViewController { top = presented }

        let sheet = UIActivityViewController(activityItemsConfiguration: configuration)
        sheet.excludedActivityTypes = [
            .message, .mail, .print, .copyToPasteboard, .assignToContact, .saveToCameraRoll,
            .addToReadingList, .postToFacebook, .postToTwitter, .postToWeibo, .postToTencentWeibo,
            .postToFlickr, .postToVimeo, .openInIBooks, .markupAsPDF, .sharePlay,
            .collaborationInviteWithLink, .collaborationCopyLink, .addToHomeScreen,
        ]
        if let popover = sheet.popoverPresentationController {   // iPad
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }
}
