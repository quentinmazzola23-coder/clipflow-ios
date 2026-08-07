//
//  ThumbnailCache.swift
//  ClipFlow
//
//  Cache de vignettes pour la timeline, générées depuis les fichiers ORIGINAUX
//  (une image par rush, réutilisée pour toutes les tuiles du segment).
//  Mémoire bornée par NSCache.
//

import Foundation
import AVFoundation
import UIKit

final class ThumbnailCache: @unchecked Sendable {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    /// Générateurs par fichier — réutilisés (création coûteuse).
    private var generators: [String: AVAssetImageGenerator] = [:]
    private let lock = NSLock()
    /// Demandes en cours pour éviter les doublons.
    private var inFlight = Set<String>()

    private init() {
        cache.countLimit = 300
    }

    /// Clé : identifiant appelant + seconde arrondie au dixième.
    private func cacheKey(_ key: String, time: CMTime) -> NSString {
        let tenth = Int((time.seconds * 10).rounded())
        return "\(key)#\(tenth)" as NSString
    }

    /// Vignette immédiate si en cache, sinon nil.
    func cachedThumbnail(key: String, time: CMTime) -> UIImage? {
        cache.object(forKey: cacheKey(key, time: time))
    }

    /// Génère (si nécessaire) depuis `fileURL` puis rappelle sur le MainActor.
    func requestThumbnail(fileURL: URL,
                          key: String,
                          time: CMTime,
                          completion: @MainActor @escaping (UIImage?) -> Void) {
        let ck = cacheKey(key, time: time)
        if let hit = cache.object(forKey: ck) {
            Task { @MainActor in completion(hit) }
            return
        }
        lock.lock()
        if inFlight.contains(ck as String) {
            lock.unlock()
            return
        }
        inFlight.insert(ck as String)
        let generator = self.generator(for: fileURL, key: key)
        lock.unlock()

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var image: UIImage?
            do {
                let (cgImage, _) = try await generator.image(at: time)
                image = UIImage(cgImage: cgImage)
                self.cache.setObject(image!, forKey: ck)
            } catch {
                // Fichier indisponible ou temps hors bornes : ignorer.
            }
            self.lock.lock()
            self.inFlight.remove(ck as String)
            self.lock.unlock()
            let result = image
            await MainActor.run { completion(result) }
        }
    }

    private func generator(for fileURL: URL, key: String) -> AVAssetImageGenerator {
        if let existing = generators[key] { return existing }
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Une seule image représentative par rush : tolérance large, l'image
        // clé la plus proche suffit et se décode vite même en 4K.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        generator.maximumSize = CGSize(width: 640, height: 360)
        generators[key] = generator
        return generator
    }

    func clearMemory() {
        cache.removeAllObjects()
        lock.lock()
        generators.removeAll()
        lock.unlock()
    }
}
