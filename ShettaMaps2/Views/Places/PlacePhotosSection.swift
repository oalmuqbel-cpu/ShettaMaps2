import SwiftUI
import SwiftData
import PhotosUI

/// تصغير الصورة وضغطها قبل الحفظ حتى لا تستهلك مساحة كبيرة.
enum PhotoCompressor {
    static func jpeg(_ image: UIImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        let s = image.size
        let scale = min(1, maxSide / max(s.width, s.height))
        let size = CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return img.jpegData(compressionQuality: quality)
    }
}

/// قسم صور المكان: إضافة من المعرض أو الكاميرا، عرض، وحذف.
struct PlacePhotosSection: View {
    @Environment(\.modelContext) private var context
    @Bindable var place: SavedPlace
    @State private var picked: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var viewing: PlacePhoto?
    @State private var toDelete: PlacePhoto?
    static let maxPhotos = 12

    private var photos: [PlacePhoto] { (place.photos ?? []).sorted { $0.createdAt < $1.createdAt } }

    var body: some View {
        Section {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos) { p in
                            thumb(p)
                                .onTapGesture { viewing = p }
                                .contextMenu { Button("حذف الصورة", role: .destructive) { toDelete = p } }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if photos.count < Self.maxPhotos {
                PhotosPicker(selection: $picked, maxSelectionCount: Self.maxPhotos - photos.count, matching: .images) {
                    Label("إضافة صور من المعرض", systemImage: "photo.on.rectangle")
                }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: { Label("التقاط صورة", systemImage: "camera") }
                }
            }
        } header: { Text("الصور") } footer: {
            Text("الصور خاصة بك: تُحفظ على جهازك، ومع iCloud إذا فعّلت المزامنة. اضغط مطولًا على الصورة لحذفها.")
        }
        .onChange(of: picked) { _, items in Task { await importItems(items) } }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in add(image) }.ignoresSafeArea()
        }
        .sheet(item: $viewing) { p in PhotoViewer(photo: p) { toDelete = p; viewing = nil } }
        .confirmationDialog("حذف الصورة؟", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                if let p = toDelete { context.delete(p); try? context.save() }
                toDelete = nil
            }
        }
    }

    private func thumb(_ p: PlacePhoto) -> some View {
        Group {
            if let d = p.thumbnailData ?? p.imageData, let ui = UIImage(data: d) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func importItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) { add(ui) }
        }
        picked = []
    }

    private func add(_ image: UIImage) {
        guard (place.photos?.count ?? 0) < Self.maxPhotos,
              let full = PhotoCompressor.jpeg(image, maxSide: 1600, quality: 0.72) else { return }
        let photo = PlacePhoto(imageData: full, thumbnailData: PhotoCompressor.jpeg(image, maxSide: 240, quality: 0.7))
        context.insert(photo)
        photo.place = place
        place.updatedAt = Date()
        try? context.save()
    }
}

struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let photo: PlacePhoto
    var onDelete: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let d = photo.imageData, let ui = UIImage(data: d) {
                    Image(uiImage: ui).resizable().scaledToFit()
                } else {
                    ContentUnavailableView("تعذّر عرض الصورة", systemImage: "photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                }
            }
        }
    }
}

/// الكاميرا عبر UIImagePickerController.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
