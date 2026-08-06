import SwiftUI

/// The ID-photo panel: what the automatic placement produced, and the controls to
/// override it.
///
/// The head-height readout is the point of this whole panel. Auto-placement always
/// aims at 32 mm, but the crown estimate can be wrong on hats, buns, or dark hair
/// against a dark room — and a rejected passport photo costs a week. So the number
/// is shown, the acceptable band is shown next to it, and the crop can be moved.
struct IDControls: View {
    @Bindable var model: AppModel

    private let spec = IDPhotoSpec.ica

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("ID photo")

            if let item = model.selectedItem {
                if let issue = item.faceIssue, item.headMM == nil {
                    warning(issue)
                } else if let headMM = item.headMM {
                    readout(headMM: headMM, item: item)
                    adjustments(item: item)
                } else if item.state == .processing {
                    Text("Finding the face…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Select an image to adjust its crop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("35 × 45 mm at 400 × 514 px. Crown-to-chin \(Int(spec.minHeadMM))–\(Int(spec.maxHeadMM)) mm, about \(Int(spec.headroomMM)) mm above the crown.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Readout

    private func readout(headMM: Double, item: ImageItem) -> some View {
        let ok = spec.isHeadHeightAcceptable(headMM)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Head height %.1f mm", headMM))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Text(ok
                     ? "Inside the \(Int(spec.minHeadMM))–\(Int(spec.maxHeadMM)) mm range."
                     : "Outside the \(Int(spec.minHeadMM))–\(Int(spec.maxHeadMM)) mm range — this would be rejected.")
                    .font(.caption2)
                    .foregroundStyle(ok ? Color.secondary : Color.orange)
            }
        }
    }

    // MARK: - Adjustments

    private func adjustments(item: ImageItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            slider(title: "Size",
                   value: item.adjustment.scale,
                   range: 0.70...1.40,
                   format: { String(format: "%.0f%%", $0 * 100) }) { newValue in
                var adjustment = item.adjustment
                adjustment.scale = newValue
                model.updateAdjustment(adjustment, for: item)
            }

            slider(title: "Up / down",
                   value: item.adjustment.offsetY,
                   range: -120...120,
                   format: { String(format: "%.0f px", $0) }) { newValue in
                var adjustment = item.adjustment
                adjustment.offsetY = newValue
                model.updateAdjustment(adjustment, for: item)
            }

            slider(title: "Left / right",
                   value: item.adjustment.offsetX,
                   range: -120...120,
                   format: { String(format: "%.0f px", $0) }) { newValue in
                var adjustment = item.adjustment
                adjustment.offsetX = newValue
                model.updateAdjustment(adjustment, for: item)
            }

            Button("Reset to automatic") {
                model.updateAdjustment(.identity, for: item)
            }
            .controlSize(.small)
            .disabled(item.adjustment.isIdentity)
        }
    }

    private func slider(title: String,
                        value: Double,
                        range: ClosedRange<Double>,
                        format: @escaping (Double) -> String,
                        onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(format(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .controlSize(.small)
        }
    }

    private func warning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
