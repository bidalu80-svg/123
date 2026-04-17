import SwiftUI
import UIKit

struct ImagePreviewSheet: View {
    enum Source {
        case uiImage(UIImage)
        case remote(urlString: String)
    }

    let source: Source
    let apiKey: String
    let apiBaseURL: String

    @Environment(\.dismiss) private var dismiss
    @State private var remoteScale: CGFloat = 1
    @State private var remoteLastScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                content
            }
        }
        .statusBarHidden()
    }

    private var headerBar: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(Color.white.opacity(0.18))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case .uiImage(let image):
            ZoomableUIImageContainer(image: image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .remote(let urlString):
            RemoteImageView(urlString: urlString, apiKey: apiKey, baseURL: apiBaseURL)
                .scaleEffect(remoteScale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let scaled = remoteLastScale * value
                            remoteScale = min(max(1, scaled), 4)
                        }
                        .onEnded { _ in
                            remoteLastScale = remoteScale
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        if remoteScale > 1.2 {
                            remoteScale = 1
                            remoteLastScale = 1
                        } else {
                            remoteScale = 2
                            remoteLastScale = 2
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
        }
    }
}

private struct ZoomableUIImageContainer: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc
        func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let target: CGFloat = scrollView.zoomScale > 1.2 ? 1 : 2
            scrollView.setZoomScale(target, animated: true)
        }
    }
}

