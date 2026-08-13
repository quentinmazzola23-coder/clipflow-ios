// swift-tools-version: 6.0
//
//  Package.swift — BANC D'ESSAI DU PIPELINE D'EXPORT
//
//  L'app reste un projet Xcode iOS (ClipFlow.xcodeproj) : ce paquet ne la
//  remplace pas. Il expose LES MÊMES FICHIERS SOURCES du pipeline (aucune
//  copie, aucun fork) comme une bibliothèque compilable pour macOS, afin de
//  les tester avec le VRAI moteur VideoToolbox.
//
//  Pourquoi : le simulateur iOS n'embarque pas VTFrameProcessor, et faire
//  tourner l'app iOS sur un Mac (« Designed for iPad ») exige une identité de
//  signature qu'un runner CI n'a pas (« Ad Hoc code signing is not allowed
//  with SDK iOS »). Un paquet Swift, lui, se teste sans aucune signature.
//  Conséquence : les artefacts de flux optique sont constatés par la machine
//  en intégration continue, plus par l'utilisateur sur son iPhone.
//
//  Les fichiers listés ici n'importent que Foundation/AVFoundation/CoreVideo/
//  CoreMedia/VideoToolbox/os — aucun UIKit, aucun SwiftData : ils compilent
//  tels quels pour macOS.
//

import PackageDescription

let package = Package(
    name: "ClipFlowPipeline",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ClipFlowPipeline", targets: ["ClipFlowPipeline"]),
    ],
    targets: [
        // Le dossier est REMPLI à la demande par PipelineHarness/sync-sources.sh
        // (copie des fichiers de l'app, seule source de vérité) — exécuter ce
        // script avant `swift test`.
        .target(
            name: "ClipFlowPipeline",
            path: "PipelineHarness/Sources/ClipFlowPipeline",
            swiftSettings: [.swiftLanguageMode(.v5)]   // aligné sur SWIFT_VERSION = 5.0 du projet
        ),
        .testTarget(
            name: "ClipFlowPipelineTests",
            dependencies: ["ClipFlowPipeline"],
            path: "PipelineHarnessTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
