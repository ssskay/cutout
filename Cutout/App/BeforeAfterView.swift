import SwiftUI

/// Before/after wipe. The original is on the left of the divider, the composited
/// result on the right; drag the handle to sweep across.
///
/// Both sides are letterboxed into the same rect rather than matched pixel for
/// pixel, because the framed presets deliberately change the aspect ratio — an
/// ID photo is 35 × 45 mm no matter what shape the source was.
struct BeforeAfterView: View {
    let item: ImageItem
    let backdrop: Backdrop

    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let divider = width * split

            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)

                if let error = item.errorMessage {
                    failure(error)
                } else if item.state == .processing || item.afterPreview == nil {
                    working
                } else {
                    content(width: width, divider: divider, size: geometry.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        split = min(1, max(0, value.location.x / max(1, width)))
                    }
            )
        }
    }

    @ViewBuilder
    private func content(width: CGFloat, divider: CGFloat, size: CGSize) -> some View {
        // "After" fills the frame; "before" is revealed on the left by a mask.
        if let after = item.afterPreview {
            CheckerboardBackground()
                .opacity(backdrop == .transparent ? 1 : 0)

            Image(nsImage: after)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size.width, height: size.height)
        }

        if let before = item.beforePreview {
            Image(nsImage: before)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size.width, height: size.height)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: divider)
                }
        }

        // Divider handle.
        Rectangle()
            .fill(.white)
            .frame(width: 1.5)
            .shadow(color: .black.opacity(0.55), radius: 1.5)
            .overlay {
                Image(systemName: "arrow.left.and.right.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
            .offset(x: divider - 0.75)
            .allowsHitTesting(false)

        HStack {
            label("Before")
            Spacer()
            label("After")
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }

    private var working: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Lifting the subject…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.orange)
            Text(item.name).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The standard transparency checkerboard, so a transparent export reads as
/// transparent rather than as white.
struct CheckerboardBackground: View {
    var square: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(white: 0.98)))
            let columns = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            for row in 0..<max(0, rows) {
                for column in 0..<max(0, columns) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * square,
                                      y: CGFloat(row) * square,
                                      width: square, height: square)
                    context.fill(Path(rect), with: .color(Color(white: 0.88)))
                }
            }
        }
    }
}
