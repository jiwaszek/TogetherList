import AVFoundation
import SwiftUI
import TogetherListCore

struct ScannerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum CameraState { case checking, authorized, denied, unavailable }

    @State private var camera: CameraState = .checking
    @State private var manualEntry = ""
    @State private var scanMessage: String?
    @State private var scanCount = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cameraArea
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    if let scanMessage {
                        Label(scanMessage, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .transition(.opacity)
                    }

                    manualEntrySection
                }
                .padding()
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Scan invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await checkCamera() }
            .sensoryFeedback(.success, trigger: scanCount)
        }
    }

    @ViewBuilder
    private var cameraArea: some View {
        switch camera {
        case .checking:
            Color.black.overlay(ProgressView().tint(.white))
        case .authorized:
            QRScannerRepresentable { code in handle(scanned: code) }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                        .padding(48)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel("Camera viewfinder. Point at a ShareMeList QR code.")
        case .denied:
            placeholder(
                icon: "camera.fill",
                title: "Camera access is off",
                text: "To scan invitation codes, allow camera access in Settings. You can also paste an invitation link below.",
                action: ("Open Settings", { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } })
            )
        case .unavailable:
            placeholder(
                icon: "camera.metering.unknown",
                title: "No camera available",
                text: "Paste the invitation link or code below instead.",
                action: nil
            )
        }
    }

    private func placeholder(icon: String, title: LocalizedStringKey, text: LocalizedStringKey,
                             action: (LocalizedStringKey, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
        .accessibilityElement(children: .contain)
    }

    private var manualEntrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Have a link instead?")
                .font(.headline)
            HStack {
                TextField("Paste invitation link or code", text: $manualEntry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { handle(scanned: manualEntry) }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { manualEntry = first; handle(scanned: first) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.roundedRectangle(radius: 12))
            }
            Button("Continue") { handle(scanned: manualEntry) }
                .buttonStyle(.bordered)
                .disabled(manualEntry.nilIfBlank == nil)
        }
    }

    private func checkCamera() async {
        guard AVCaptureDevice.default(for: .video) != nil else { camera = .unavailable; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = .authorized
        case .notDetermined:
            camera = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        default: camera = .denied
        }
    }

    private func handle(scanned code: String) {
        guard let token = InvitationLink.token(from: code) else {
            withAnimation { scanMessage = L("That isn't a ShareMeList invitation.") }
            return
        }
        scanMessage = nil
        scanCount += 1
        app.openInvitation(token: token)
    }
}

// MARK: - Camera

/// AVFoundation QR reader. Reports each distinct code once.
struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onCode = onCode
    }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "TogetherList.QRScanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastCode: String?
    private var lastCodeDate = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        nonisolated(unsafe) let session = session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        nonisolated(unsafe) let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let value = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        MainActor.assumeIsolated {
            guard let value else { return }
            // Debounce: the same code is reported many times per second.
            if value == lastCode, Date().timeIntervalSince(lastCodeDate) < 3 { return }
            lastCode = value
            lastCodeDate = Date()
            onCode?(value)
        }
    }
}
