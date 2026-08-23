import fs from 'node:fs';
import ExcelJS from 'exceljs';

const COLUMNS = [
  { header: 'Titre', key: 'titre', width: 46 },
  { header: 'Type', key: 'typeBien', width: 12 },
  { header: 'Ville', key: 'ville', width: 20 },
  { header: 'CP', key: 'codePostal', width: 8 },
  { header: 'Prix', key: 'prix', width: 13, fmt: '#,##0 "€"' },
  { header: '€/m²', key: 'prixM2', width: 10, fmt: '#,##0' },
  { header: 'Surface', key: 'surface', width: 9, fmt: '0" m²"' },
  { header: 'Terrain', key: 'terrain', width: 10, fmt: '#,##0" m²"' },
  { header: 'Pièces', key: 'pieces', width: 8 },
  { header: 'Ch.', key: 'chambres', width: 6 },
  { header: 'Adresse estimée', key: 'adresseEstimee', width: 42 },
  { header: 'Confiance', key: 'niveauConfiance', width: 11 },
  { header: 'Latitude', key: 'latitude', width: 12, fmt: '0.000000' },
  { header: 'Longitude', key: 'longitude', width: 12, fmt: '0.000000' },
  { header: 'Parcelle', key: 'parcelle', width: 17 },
  { header: 'DPE', key: 'dpe', width: 6 },
  { header: 'GES', key: 'ges', width: 6 },
  { header: 'Année', key: 'anneeConstruction', width: 8 },
  { header: 'Publiée le', key: 'publieeLe', width: 12 },
  { header: 'Jours en ligne', key: 'joursEnLigne', width: 13 },
  { header: 'Baisses', key: 'nbBaisses', width: 9 },
  { header: 'Prix initial', key: 'prixInitial', width: 13, fmt: '#,##0 "€"' },
  { header: 'Baisse', key: 'baissePct', width: 9, fmt: '0.0"%"' },
  { header: 'Écart marché', key: 'ecartMarchePct', width: 13, fmt: '+0.0"%";-0.0"%";0"%"' },
  { header: 'Médiane secteur €/m²', key: 'medianeSecteurM2', width: 19, fmt: '#,##0' },
  { header: 'Fourchette basse', key: 'fourchetteBasse', width: 17, fmt: '#,##0 "€"' },
  { header: 'Fourchette haute', key: 'fourchetteHaute', width: 17, fmt: '#,##0 "€"' },
  { header: 'Position', key: 'positionMarche', width: 20 },
  { header: 'Délai vente commune (j)', key: 'delaiVenteCommuneJours', width: 21 },
  { header: 'Vendeur', key: 'vendeur', width: 22 },
  { header: 'Source', key: 'source', width: 10 },
  { header: 'Statut', key: 'statutLabel', width: 16 },
  { header: 'Suivi depuis', key: 'premiereApparitionJour', width: 13 },
  { header: 'Parutions', key: 'nbParutions', width: 10 },
  { header: 'Annonce', key: 'urlAnnonce', width: 16, link: true, linkText: 'leboncoin' },
  { header: 'Analyse', key: 'urlAnalyse', width: 16, link: true, linkText: 'lacquereur' },
  { header: 'Carte', key: 'urlMaps', width: 14, link: true, linkText: 'Google Maps' },
];

const HEADER_FILL = 'FF1F3A5F';
const GREEN = 'FF1E7A46';
const RED = 'FFB3261E';
const AMBER = 'FF8A6100';
const BLUE = 'FF0B57D0';

const STATUT_FR = {
  nouveau: 'nouveau',
  republie: 'remis en ligne',
  connu: '',
};

export async function writeSpreadsheet(records, file) {
  const wb = new ExcelJS.Workbook();
  wb.creator = 'carto-immo';
  wb.created = new Date();

  const ws = wb.addWorksheet('Annonces', {
    views: [{ state: 'frozen', ySplit: 1 }],
  });
  ws.columns = COLUMNS.map(({ header, key, width }) => ({ header, key, width }));

  const head = ws.getRow(1);
  head.height = 24;
  head.font = { bold: true, color: { argb: 'FFFFFFFF' }, size: 11 };
  head.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: HEADER_FILL } };
  head.alignment = { vertical: 'middle', wrapText: true };

  for (const rec of records) {
    const row = ws.addRow({
      ...rec,
      statutLabel: STATUT_FR[rec.statut] ?? '',
      premiereApparitionJour: (rec.premiereApparition ?? '').slice(0, 10),
      nbParutions: rec.annonces?.length ?? 1,
    });

    for (const col of COLUMNS) {
      const cell = row.getCell(col.key);
      if (col.fmt) cell.numFmt = col.fmt;
      if (col.link && cell.value) {
        cell.value = { text: col.linkText, hyperlink: String(cell.value) };
        cell.font = { color: { argb: 'FF0B57D0' }, underline: true };
      }
    }

    // Un coup d'œil doit suffire à repérer les annonces négociables.
    const ecart = row.getCell('ecartMarchePct');
    if (typeof rec.ecartMarchePct === 'number') {
      const over = rec.ecartMarchePct > 0;
      ecart.font = { bold: true, color: { argb: over ? RED : GREEN } };
    }
    const pos = row.getCell('positionMarche');
    if (rec.positionMarche === 'Sous le marché') pos.font = { color: { argb: GREEN }, bold: true };
    else if (rec.positionMarche === 'Au-dessus du marché') pos.font = { color: { argb: RED } };
    if (rec.statut === 'nouveau') {
      row.getCell('statutLabel').font = { color: { argb: AMBER }, bold: true };
    } else if (rec.statut === 'republie') {
      row.getCell('statutLabel').font = { color: { argb: BLUE }, bold: true };
      // Une remise en ligne signale un bien qui ne part pas : c'est négociable.
      row.getCell('nbParutions').font = { color: { argb: BLUE }, bold: true };
    }
    if (rec.localisationPrecise === false) {
      row.getCell('adresseEstimee').font = { italic: true, color: { argb: 'FF777777' } };
    }
  }

  ws.autoFilter = {
    from: { row: 1, column: 1 },
    to: { row: 1, column: COLUMNS.length },
  };

  await wb.xlsx.writeFile(file);
  return file;
}

/** CSV UTF-8 avec BOM : Excel FR l'ouvre proprement, séparateur point-virgule. */
export function writeCsv(records, file) {
  const esc = (v) => {
    if (v === null || v === undefined) return '';
    const s = String(v).replace(/"/g, '""');
    return /[;\n"]/.test(s) ? `"${s}"` : s;
  };
  const lines = [COLUMNS.map((c) => esc(c.header)).join(';')];
  for (const rec of records) {
    lines.push(
      COLUMNS.map((c) => {
        if (c.key === 'statutLabel') return esc(STATUT_FR[rec.statut] ?? '');
        if (c.key === 'premiereApparitionJour') return esc((rec.premiereApparition ?? '').slice(0, 10));
        if (c.key === 'nbParutions') return esc(rec.annonces?.length ?? 1);
        return esc(rec[c.key]);
      }).join(';')
    );
  }
  fs.writeFileSync(file, '﻿' + lines.join('\n'), 'utf8');
  return file;
}
