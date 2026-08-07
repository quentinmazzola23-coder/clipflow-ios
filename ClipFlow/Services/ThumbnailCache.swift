//
//  ThumbnailCache.swift
//  ClipFlow
//
//  Cache de miniatures pour la timeline. Génère depuis les PROXYS (tout-intra,
//  décodage instantané), mémoire bornée par NSCache. Jamais depuis les 4K.
//

import Foundation
import AVFoundation
import UIKit

final class ThumbnailCache: @unchecked Sendable {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    /// Générateurs par proxy — réutilisés (création coûteuse).
    private var generators: [String: AVAssetImageGenerator] = [:]
    private let lock = NSLock()
    /// Demandes en cours pour éviter les doublons.
    private var inFlight = Set<String>()

    private init() {
        cache.countLimit = 600 // ~600 miniatures 144p ≈ quelques dizaines de Mo max
    }

    /// Clé : chemin proxy + seconde arrondie au dixième.
    private func key(proxyPath: String, time: CMTime) -> NSString {
        let tenth = Int((time.seconds * 10).rounded())
        return "\(proxyPath)#\(tenth)" as NSString
    }

    /// Miniature immédiate si en cache, sinon nil (et lancement de la génération).
    func cachedThumbnail(proxyPath: String, time: CMTime) -> UIImage? {
        cache.object(forKey: key(proxyPath: proxyPath, time: time))
    }

    /// Génère (si nécessaire) puis rappelle sur le MainActor.
    func requestThumbnail(proxyPath: String,
                          time: CMTime,
                          completion: @MainActor @escaping (UIImage?) -> Void) {
        let cacheKey = key(proxyPath: proxyPath, time: time)
        if let hit = cache.object(forKey: cacheKey) {
            Task { @MainActor in completion(hit) }
            return
        }
        lock.lock()
        if inFlight.contains(cacheKey as String) {
            lock.unlock()
            return
        }
        inFlight.insert(cacheKey as String)
        let generator = self.generator(for: proxyPath)
        lock.unlock()

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var image: UIImage?
            do {
                let (cgImage, _) = try await generator.image(at: time)
                image = UIImage(cgImage: cgImage)
                self.cache.setObject(image!, forKey: cacheKey)
            } catch {
                // Proxy pas encore prêt ou temps hors bornes : ignorer.
            }
            self.lock.lock()
            self.inFlight.remove(cacheKey as String)
            self.lock.unlock()
            let result = image
            await MainActor.run { completion(result) }
        }
    }

    private func generator(for proxyPath: String) -> AVAssetImageGenerator {
        if let existing = generators[proxyPath] { return existing }
        let url = StorageManager.url(forProxyRelativePath: proxyPath)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Proxy tout-intra : tolérance large = image la plus proche, décodée en O(1).
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        generator.maximumSize = CGSize(width: 426, height: 240)
        generators[proxyPath] = generator
        return generator
    }

    func clearMemory() {
        cache.removeAllObjects()
        lock.lock()
        generators.removeAll()
        lock.unlock()
    }
}
