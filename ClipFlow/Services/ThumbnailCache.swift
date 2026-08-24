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
    /// Générateurs par fichier — réutilisés, mais BORNÉS en LRU : un
    /// générateur retient son AVAsset ouvert ; en garder un par rush pour
    /// toujours = centaines d'assets ouverts (pression mémoire/décodeur).
    private var generators: [String: AVAssetImageGenerator] = [:]
    private var generatorOrder: [String] = []
    private let maxGenerators = 12
    private let lock = NSLock()
    /// Demandes en cours pour éviter les doublons.
    private var inFlight = Set<String>()

    /// Cache DISQUE (Caches/Thumbnails) : les vignettes survivent au
    /// relancement — plus de rafale de décodages 4K à l'ouverture d'un projet.
    private static let diskDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func diskURL(for cacheKey: NSString) -> URL {
        let safe = (cacheKey as String)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return Self.diskDirectory.appendingPathComponent(safe + ".jpg")
    }

    private init() {
        cache.countLimit = 120
        // ~48 Mo maximum d'images décodées (coût = octets réels).
        cache.totalCostLimit = 48 * 1024 * 1024
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
    /// - `preciseTime` : n'accepte que l'image demandée, sans remonter à
    ///   l'image clé précédente. Indispensable pour la vignette d'un CLIP : une
    ///   plage cachée est un remux sans réencodage, donc elle commence à
    ///   l'image clé située AVANT le début du clip. Avec la tolérance large,
    ///   la vignette montrait un instant qui précède le clip — parfois une
    ///   seconde plus tôt, sur une autre action.
    func requestThumbnail(fileURL: URL,
                          key: String,
                          time: CMTime,
                          preciseTime: Bool = false,
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
        // CLÉ DISTINCTE PAR MODE : un générateur à tolérance large déjà en
        // cache pour ce fichier rendrait la demande précise inutile.
        let generatorKey = preciseTime ? key + "#exact" : key
        let generator = self.generator(for: fileURL, key: generatorKey,
                                       precise: preciseTime)
        lock.unlock()

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var image: UIImage?
            // 1. Cache disque (survit au relancement de l'app).
            let diskURL = self.diskURL(for: ck)
            if let data = try? Data(contentsOf: diskURL),
               let disk = UIImage(data: data) {
                image = disk
                self.cache.setObject(disk, forKey: ck, cost: data.count * 4)
            }
            // 2. Génération depuis l'original, puis écriture disque.
            if image == nil {
                do {
                    let (cgImage, _) = try await generator.image(at: time)
                    let generated = UIImage(cgImage: cgImage)
                    image = generated
                    let cost = cgImage.bytesPerRow * cgImage.height
                    self.cache.setObject(generated, forKey: ck, cost: cost)
                    if let jpeg = generated.jpegData(compressionQuality: 0.7) {
                        try? jpeg.write(to: diskURL, options: .atomic)
                    }
                } catch {
                    // Fichier indisponible ou temps hors bornes : ignorer.
                }
            }
            self.lock.lock()
            self.inFlight.remove(ck as String)
            self.lock.unlock()
            let result = image
            await MainActor.run { completion(result) }
        }
    }

    /// Appelé sous `lock`.
    private func generator(for fileURL: URL, key: String,
                           precise: Bool) -> AVAssetImageGenerator {
        if let existing = generators[key] {
            // LRU : replacer la clé en fin de file.
            generatorOrder.removeAll { $0 == key }
            generatorOrder.append(key)
            return existing
        }
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if precise {
            // Décodage jusqu'à l'image demandée : plus lent, mais c'est la
            // bonne image. Réservé aux vignettes qui doivent représenter un
            // instant précis, pas un rush entier.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 640, height: 360)
            generators[key] = generator
            generatorOrder.append(key)
            while generatorOrder.count > maxGenerators {
                let evicted = generatorOrder.removeFirst()
                generators.removeValue(forKey: evicted)
            }
            return generator
        }
        // Une seule image représentative par rush : tolérance large, l'image
        // clé la plus proche suffit et se décode vite même en 4K.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        generator.maximumSize = CGSize(width: 640, height: 360)
        generators[key] = generator
        generatorOrder.append(key)
        // Éviction du plus ancien au-delà de la borne.
        while generatorOrder.count > maxGenerators {
            let evicted = generatorOrder.removeFirst()
            generators.removeValue(forKey: evicted)
        }
        return generator
    }

    func clearMemory() {
        cache.removeAllObjects()
        lock.lock()
        generators.removeAll()
        generatorOrder.removeAll()
        lock.unlock()
    }
}
