import SwiftUI

/// A small card at the bottom of a machine's window while dropped files copy in.
struct FileDropToast: View {
    @State private var drop = FileDrop.shared

    var body: some View {
        if let transfer = drop.transfer {
            HStack(spacing: 10) {
                Image(systemName: transfer.failed ? "exclamationmark.triangle.fill" : transfer.done ? "checkmark.circle.fill" : "arrow.down.doc.fill")
                    .foregroundStyle(transfer.failed ? .yellow : transfer.done ? .green : .secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(transfer.title)
                        .lineLimit(3)
                    if !transfer.done && !transfer.failed {
                        ProgressView(value: transfer.fraction)
                            .frame(width: 240)
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .padding(20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
