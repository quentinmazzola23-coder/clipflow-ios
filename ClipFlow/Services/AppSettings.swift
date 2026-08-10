//
//  AppSettings.swift
//  ClipFlow
//
//  Réglages GLOBAUX, maintenus entre les projets. Les champs restent stockés
//  sur ClipProject (schéma inchangé), mais UserDefaults fait foi : toute
//  modification est capturée, et chaque ouverture/création de projet applique
//  les valeurs globales.
//

import Foundation

enum AppSettings {

    private static let defaults = UserDefaults.standard

    private enum Key {
        static let finalDuration = "settings.finalDurationCentiseconds"
        static let touchCenter = "settings.touchAnchorIsCenter"
        static let autoExport = "settings.autoExportOnValidate"
        static let previewLight = "settings.previewLight"
    }

    /// Applique les réglages globaux au projet (ouverture, création).
    static func apply(to project: ClipProject) {
        if let duration = defaults.object(forKey: Key.finalDuration) as? Int {
            project.finalDurationCentiseconds = duration
        }
        if let center = defaults.object(forKey: Key.touchCenter) as? Bool {
            project.touchAnchorIsCenter = center
        }
        if let auto = defaults.object(forKey: Key.autoExport) as? Bool {
            project.autoExportOnValidate = auto
        }
        if let light = defaults.object(forKey: Key.previewLight) as? Bool {
            project.previewLight = light
        }
    }

    /// Capture les réglages du projet comme nouveaux réglages globaux
    /// (appelé après toute modification).
    static func capture(from project: ClipProject) {
        defaults.set(project.finalDurationCentiseconds, forKey: Key.finalDuration)
        defaults.set(project.touchAnchorIsCenter, forKey: Key.touchCenter)
        defaults.set(project.autoExportOnValidate, forKey: Key.autoExport)
        defaults.set(project.previewLight, forKey: Key.previewLight)
    }
}
