import fs from 'node:fs';

/**
 * Rapport du matin : ce qui a bougé depuis la veille.
 *
 * C'est la sortie que l'on lit en premier — pas la carte. Elle doit répondre à
 * une seule question : qu'est-ce qui est réellement nouveau ce matin ?
 */

const eur = (n) =>
  n == null ? '—' : new Intl.NumberFormat('fr-FR').format(Math.round(n)) + ' €';

const jours = (depuis, jusqua) => {
  if (!depuis) return null;
  const d = (new Date(jusqua).getTime() - new Date(depuis).getTime()) / 86400000;
  return Number.isFinite(d) ? Math.round(d) : null;
};

const etiquette = (b) =>
  `${b.titre ?? 'Annonce ' + b.idPrincipal} — ${b.ville ?? '?'} — ${eur(b.prix)}`;

/**
 * @param {object} triage   sortie de trierAnnonces
 * @param {object[]} analyses fiches effectivement analysées ce matin
 */
export function construireRapport(triage, analyses, { maintenant = new Date().toISOString() } = {}) {
  const nouveaux = analyses.filter((b) => b.statut === 'nouveau');

  // Une remise en ligne peut être démasquée au triage — sur les caractéristiques
  // visibles — ou seulement à l'analyse, par la parcelle. Les deux comptent.
  const dejaCitees = new Set(triage.republies.map((r) => r.bien.cle));
  const republies = [
    ...triage.republies,
    ...analyses
      .filter((b) => b.statut === 'republie' && !dejaCitees.has(b.cle))
      .map((bien) => ({
        bien,
        motifs: [bien.motifRapprochement ?? 'démasquée à l’analyse'],
        prixModifie: bien.prixModifie ?? null,
      })),
  ];
  const baisses = [...triage.connus, ...republies]
    .filter((c) => c.prixModifie && c.prixModifie.apres < c.prixModifie.avant)
    .map((c) => ({ bien: c.bien, ...c.prixModifie }));
  const hausses = [...triage.connus, ...republies]
    .filter((c) => c.prixModifie && c.prixModifie.apres > c.prixModifie.avant)
    .map((c) => ({ bien: c.bien, ...c.prixModifie }));
  const affaires = nouveaux.filter((b) => b.positionMarche === 'Sous le marché');

  return {
    date: maintenant,
    nouveaux,
    republies,
    baisses,
    hausses,
    affaires,
    inchanges: triage.connus.filter((c) => !c.prixModifie).length,
    total:
      triage.nouveaux.length + triage.republies.length + triage.connus.length,
  };
}

/** Version courte, pour le terminal. */
export function resumerRapport(r) {
  const l = [];
  l.push(`${r.nouveaux.length} nouveau${r.nouveaux.length > 1 ? 'x' : ''} bien${r.nouveaux.length > 1 ? 's' : ''}`);
  if (r.republies.length) l.push(`${r.republies.length} remise${r.republies.length > 1 ? 's' : ''} en ligne`);
  if (r.baisses.length) l.push(`${r.baisses.length} baisse${r.baisses.length > 1 ? 's' : ''} de prix`);
  l.push(`${r.inchanges} inchangé${r.inchanges > 1 ? 's' : ''}`);
  return l.join(' · ');
}

/** Version détaillée, écrite dans data/rapport.md et affichée au terminal. */
export function ecrireRapport(r, file) {
  const d = new Date(r.date);
  const lignes = [];
  const titre = d.toLocaleDateString('fr-FR', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
  lignes.push(`# Veille immobilière — ${titre}`, '');
  lignes.push(`${r.total} annonces relevées · ${resumerRapport(r)}`, '');

  if (r.nouveaux.length) {
    lignes.push(`## ${r.nouveaux.length} nouveau${r.nouveaux.length > 1 ? 'x' : ''} bien${r.nouveaux.length > 1 ? 's' : ''}`, '');
    for (const b of r.nouveaux) {
      const marche =
        b.ecartMarchePct != null
          ? ` — ${b.ecartMarchePct > 0 ? '+' : ''}${b.ecartMarchePct.toFixed(1)} % vs marché`
          : '';
      lignes.push(`- **${etiquette(b)}**${marche}`);
      if (b.adresseEstimee) lignes.push(`  ${b.adresseEstimee} (confiance ${b.niveauConfiance ?? 'inconnue'})`);
      lignes.push(`  ${b.urlAnnonce}`);
    }
    lignes.push('');
  }

  if (r.republies.length) {
    lignes.push(`## ${r.republies.length} remise${r.republies.length > 1 ? 's' : ''} en ligne`, '');
    lignes.push('Même bien qu\'une annonce déjà connue, republié sous un nouvel identifiant. Pas de nouvelle analyse.', '');
    for (const { bien, motifs, prixModifie } of r.republies) {
      const anciennete = jours(bien.premiereApparition, r.date);
      lignes.push(`- **${etiquette(bien)}**`);
      lignes.push(
        `  Suivi depuis ${anciennete ?? '?'} jours, ${bien.annonces.length} parutions` +
          ` — rapproché par : ${motifs.join(', ')}`
      );
      if (prixModifie) {
        const delta = prixModifie.apres - prixModifie.avant;
        lignes.push(`  Prix : ${eur(prixModifie.avant)} → ${eur(prixModifie.apres)} (${delta > 0 ? '+' : ''}${eur(delta)})`);
      }
    }
    lignes.push('');
  }

  if (r.baisses.length) {
    lignes.push(`## ${r.baisses.length} baisse${r.baisses.length > 1 ? 's' : ''} de prix`, '');
    for (const { bien, avant, apres } of r.baisses) {
      const pct = (((avant - apres) / avant) * 100).toFixed(1);
      lignes.push(`- ${etiquette(bien)} : ${eur(avant)} → ${eur(apres)} (−${pct} %)`);
    }
    lignes.push('');
  }

  if (r.hausses.length) {
    lignes.push(`## ${r.hausses.length} hausse${r.hausses.length > 1 ? 's' : ''} de prix`, '');
    for (const { bien, avant, apres } of r.hausses) {
      lignes.push(`- ${etiquette(bien)} : ${eur(avant)} → ${eur(apres)}`);
    }
    lignes.push('');
  }

  if (r.affaires.length) {
    lignes.push('## À regarder en priorité', '');
    lignes.push('Nouveaux biens affichés sous la fourchette de marché du secteur.', '');
    for (const b of r.affaires) {
      lignes.push(`- ${etiquette(b)} — ${b.ecartMarchePct?.toFixed(1)} % sous la médiane, ${b.urlAnnonce}`);
    }
    lignes.push('');
  }

  const texte = lignes.join('\n');
  fs.writeFileSync(file, texte, 'utf8');
  return texte;
}
