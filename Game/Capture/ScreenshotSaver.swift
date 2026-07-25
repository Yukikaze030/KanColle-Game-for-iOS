import Foundation
import Photos
import UIKit

/// Validates a PNG data URL and saves it to the user's photo library.
///
/// The limits are intentionally conservative: screenshots are expected to be close to
/// the game's 1200×720 canvas, while malformed or hostile inputs must not create a large
/// Base64 or image-decoding memory spike.
@MainActor
final class ScreenshotSaver {
    enum SaveError: LocalizedError, Equatable {
        case inputTooLarge(maxBytes: Int)
        case invalidDataURL
        case decodedDataTooLarge(maxBytes: Int)
        case invalidBase64
        case invalidPNG
        case invalidImage
        case imageDimensionsTooLarge(maxPixels: Int)
        case authorizationDenied
        case authorizationRestricted
        case authorizationUnavailable
        case photoLibraryChangeFailed(String)

        var errorDescription: String? {
            switch self {
            case .inputTooLarge(let maxBytes):
                return "截图输入超过限制（最大 \(maxBytes) 字节）"
            case .invalidDataURL:
                return "截图不是有效的 PNG Data URL"
            case .decodedDataTooLarge(let maxBytes):
                return "截图数据超过限制（最大 \(maxBytes) 字节）"
            case .invalidBase64:
                return "截图 Base64 数据无效"
            case .invalidPNG:
                return "截图不是有效的 PNG 文件"
            case .invalidImage:
                return "截图图像无法解码"
            case .imageDimensionsTooLarge(let maxPixels):
                return "截图像素数量超过限制（最大 \(maxPixels)）"
            case .authorizationDenied:
                return "没有照片添加权限"
            case .authorizationRestricted:
                return "系统限制了照片访问"
            case .authorizationUnavailable:
                return "照片权限状态不可用"
            case .photoLibraryChangeFailed(let message):
                return "保存截图失败：\(message)"
            }
        }
    }

    static let maximumInputBytes = 32 * 1_024 * 1_024
    static let maximumDecodedBytes = 24 * 1_024 * 1_024
    static let maximumPixels = 24_000_000

    private static let dataURLPrefix = "data:image/png;base64,"
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Saves a PNG data URL and returns the newly created Photos local identifier.
    func save(dataURL: String) async throws -> String {
        let pngData = try Self.decodeAndValidate(dataURL: dataURL)
        try await ensureAddOnlyAuthorization()

        var localIdentifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: pngData, options: nil)
                localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw SaveError.photoLibraryChangeFailed(error.localizedDescription)
        }

        guard let localIdentifier else {
            throw SaveError.photoLibraryChangeFailed("照片库未返回资源标识")
        }
        return localIdentifier
    }

    private static func decodeAndValidate(dataURL: String) throws -> Data {
        guard dataURL.utf8.count <= maximumInputBytes else {
            throw SaveError.inputTooLarge(maxBytes: maximumInputBytes)
        }
        guard dataURL.hasPrefix(dataURLPrefix) else {
            throw SaveError.invalidDataURL
        }

        let payload = dataURL.dropFirst(dataURLPrefix.count)
        guard !payload.isEmpty else {
            throw SaveError.invalidBase64
        }

        // Reject oversized decoded data before allocating it. Base64 can decode to at
        // most ceil(characters / 4) × 3 bytes; the input limit keeps this arithmetic safe.
        let estimatedDecodedBytes = ((payload.utf8.count + 3) / 4) * 3
        guard estimatedDecodedBytes <= maximumDecodedBytes else {
            throw SaveError.decodedDataTooLarge(maxBytes: maximumDecodedBytes)
        }
        guard let pngData = Data(base64Encoded: String(payload)),
              pngData.count <= maximumDecodedBytes else {
            throw SaveError.invalidBase64
        }
        guard pngData.starts(with: pngSignature) else {
            throw SaveError.invalidPNG
        }
        guard let image = UIImage(data: pngData),
              let cgImage = image.cgImage,
              cgImage.width > 0,
              cgImage.height > 0 else {
            throw SaveError.invalidImage
        }

        let (pixelCount, overflow) = cgImage.width.multipliedReportingOverflow(by: cgImage.height)
        guard !overflow, pixelCount <= maximumPixels else {
            throw SaveError.imageDimensionsTooLarge(maxPixels: maximumPixels)
        }
        return pngData
    }

    private func ensureAddOnlyAuthorization() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            // Use Photos' native async API so there is no continuation that can be resumed twice.
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }

        switch status {
        case .authorized, .limited:
            return
        case .denied:
            throw SaveError.authorizationDenied
        case .restricted:
            throw SaveError.authorizationRestricted
        case .notDetermined:
            throw SaveError.authorizationUnavailable
        @unknown default:
            throw SaveError.authorizationUnavailable
        }
    }
}
