import SwiftUI

public struct ShareRecipientPickerView: View {
    @ObservedObject var viewModel: ShareExtensionViewModel
    let onCancel: () -> Void
    let onComplete: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share with Nearside").font(.headline)
            if viewModel.isExtracting {
                ProgressView("Preparing files…")
            } else if let error = viewModel.extractionError {
                Text(error).foregroundStyle(.red)
            } else {
                Text("Choose a paired device in Nearside to send \(viewModel.stagedURLs.count) item(s).")
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
                if viewModel.isOpeningHost {
                    ProgressView("Opening Nearside…")
                }
            }
            Spacer()
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Continue in Nearside") {
                    viewModel.openInNearside(onComplete: onComplete)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isExtracting || viewModel.isOpeningHost || viewModel.stagedURLs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 280)
    }
}
