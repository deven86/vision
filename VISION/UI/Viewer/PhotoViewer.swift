import SwiftUI
import ImageIO
import SwiftData

struct PhotoViewer: View {
    let context: PhotoViewerContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var current: UUID
    @State private var chromeVisible = true
    @State private var showInfo = false
    @State private var exportItems: ExportBatch?

    init(context: PhotoViewerContext) {
        self.context = context
        _current = State(initialValue: context.startID)
    }

    private var currentItem: MediaItem? { context.items.first { $0.id == current } }
    private var position: Int { (context.items.firstIndex { $0.id == current } ?? 0) + 1 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(context.items) { item in
                    ZoomableVaultPhoto(id: item.id) {
                        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
                    }
                    .tag(item.id)
                    .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chromeVisible { chrome.transition(.opacity) }
        }
        .statusBarHidden(!chromeVisible)
        .sheet(item: $exportItems) { ExportSheet(items: $0.items) }
        .sheet(isPresented: $showInfo) {
            if let item = currentItem { MediaInfoSheet(item: item) }
        }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
                Spacer()
                VStack(spacing: 2) {
                    Text(currentItem?.title ?? "").font(.headline).lineLimit(1)
                    Text("\(position) of \(context.items.count)").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button {
                    if let item = currentItem { Library.toggleFavorite(item, context: modelContext) }
                } label: {
                    Image(systemName: currentItem?.isFavorite == true ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(currentItem?.isFavorite == true ? Theme.accent : .white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Favorite")
                Button {
                    if let item = currentItem { exportItems = ExportBatch(items: [item]) }
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Export")
                Button { showInfo = true } label: {
                    Image(systemName: "info.circle").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Details")
            }
            .padding(.horizontal, 8)
            .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
            Spacer()
        }
        .foregroundStyle(.white)
    }
}

/// Decrypts the full photo (downsampled to screen-useful size) on demand.
struct ZoomableVaultPhoto: View {
    let id: UUID
    var onSingleTap: () -> Void
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImageView(image: image, onSingleTap: onSingleTap)
            } else {
                if let placeholder = ThumbnailCache.shared.cached(id, .large) {
                    Image(uiImage: placeholder).resizable().scaledToFit()
                }
                ProgressView().tint(.white)
            }
        }
        .task(id: id) {
            image = await FullImageLoader.load(id: id)
        }
    }
}

enum FullImageLoader {
    static func load(id: UUID, maxPixel: Int = 3200) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let reader = try? VaultStore.shared.openMedia(id),
                  let data = try? reader.readAll(),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

// MARK: - UIScrollView-backed zoom (native-feeling pinch, double-tap, pan)

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var onSingleTap: () -> Void

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.onSingleTap = onSingleTap
        view.display(image)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onSingleTap = onSingleTap
        if view.imageView.image !== image { view.display(image) }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onSingleTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func display(_ image: UIImage) {
        zoomScale = 1
        imageView.image = image
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        if zoomScale == minimumZoomScale {
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            minimumZoomScale = 1
            maximumZoomScale = max(4, 1 / fit)
        }
        centerImage()
    }

    private func centerImage() {
        let offsetX = max(0, (bounds.width - contentSize.width) / 2)
        let offsetY = max(0, (bounds.height - contentSize.height) / 2)
        imageView.center = CGPoint(x: contentSize.width / 2 + offsetX, y: contentSize.height / 2 + offsetY)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale = min(maximumZoomScale, 2.5)
            let width = bounds.width / scale, height = bounds.height / scale
            zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: true)
        }
    }

    @objc private func handleSingleTap() { onSingleTap?() }
}
