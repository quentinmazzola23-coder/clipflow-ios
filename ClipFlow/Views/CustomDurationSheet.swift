//
//  CustomDurationSheet.swift
//  ClipFlow
//
//  Choix du TEMPS EXACT d'un clip, au centième de seconde.
//
//  Remplace l'ancien sous-menu « Personnalisée » qui n'offrait que six valeurs
//  figées (1,10 / 1,20 / 1,40 / 1,60 / 1,75 / 2,50 s) : « personnalisé » y
//  voulait dire « une autre liste », pas « la valeur que je veux ». Deux
//  molettes couvrent maintenant tout le domaine utile, sans clavier.
//

import SwiftUI

struct CustomDurationSheet: View {

    /// Valeur initiale (celle du projet à l'ouverture).
    var initial: ExactDuration
    /// Vitesse du projet : elle décide de la longueur réellement prélevée.
    var speed: RationalSpeed
    var onValidate: (ExactDuration) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var seconds: Int = 1
    @State private var hundredths: Int = 0

    /// Plage volontairement large : un clip de triage tient sous 2 s, mais rien
    /// n'interdit un plan de 10 s pour un passage à conserver entier.
    private let secondRange = Array(0...10)
    private let hundredthRange = Array(0...99)

    private var chosen: ExactDuration {
        ExactDuration(centiseconds: seconds * 100 + hundredths)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                HStack(spacing: 0) {
                    Picker("Secondes", selection: $seconds) {
                        ForEach(secondRange, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)

                    Text(",")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Picker("Centièmes", selection: $hundredths) {
                        ForEach(hundredthRange, id: \.self) { value in
                            Text(String(format: "%02d", value)).tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)

                    Text("s")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                .frame(height: 180)

                // Ce que la durée choisie implique concrètement : la longueur
                // réellement prélevée dans le rush. C'est elle qui décide si la
                // sélection tient encore près de la fin d'un plan.
                Text("Prélève \(sourceLabel) dans le rush.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .navigationTitle("Durée exacte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Valider") {
                        onValidate(chosen)
                        dismiss()
                    }
                    // Une durée nulle ne produirait aucune image.
                    .disabled(chosen.centiseconds < 10)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            seconds = min(max(initial.centiseconds / 100, 0), 10)
            hundredths = initial.centiseconds % 100
        }
    }

    /// Durée prélevée dans le rush = durée finale × vitesse (0,5× → moitié).
    private var sourceLabel: String {
        let source = TimeMath.sourceDuration(final: chosen, speed: speed)
        return String(format: "%.2f s", source.seconds)
    }
}
