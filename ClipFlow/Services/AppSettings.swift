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
        static let durationToRushEnd = "settings.durationToRushEnd"
        static let touchCenter = "settings.touchAnchorIsCenter"
        static let autoExport = "settings.autoExportOnValidate"
        static let previewLight = "settings.previewLight"
        static let opticalFlow = "settings.opticalFlowEnabled"
        static let albumPerProject = "settings.albumPerProject"
    }

    /// Applique les réglages globaux au projet (ouverture, création).
    static func apply(to project: ClipProject) {
        if let duration = defaults.object(forKey: Key.finalDuration) as? Int {
            project.finalDurationCentiseconds = duration
        }
        if let toEnd = defaults.object(forKey: Key.durationToRushEnd) as? Bool {
            project.durationToRushEnd = toEnd
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
        if let flow = defaults.object(forKey: Key.opticalFlow) as? Bool {
            project.opticalFlowEnabled = flow
        }
        if let perProject = defaults.object(forKey: Key.albumPerProject) as? Bool {
            project.albumPerProject = perProject
        }
    }

    /// Capture les réglages du projet comme nouveaux réglages globaux
    /// (appelé après toute modification).
    static func capture(from project: ClipProject) {
        defaults.set(project.finalDurationCentiseconds, forKey: Key.finalDuration)
        defaults.set(project.durationToRushEnd, forKey: Key.durationToRushEnd)
        defaults.set(project.touchAnchorIsCenter, forKey: Key.touchCenter)
        defaults.set(project.autoExportOnValidate, forKey: Key.autoExport)
        defaults.set(project.previewLight, forKey: Key.previewLight)
        defaults.set(project.opticalFlowEnabled, forKey: Key.opticalFlow)
        defaults.set(project.albumPerProject, forKey: Key.albumPerProject)
    }
}
