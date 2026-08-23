import fs from 'node:fs';
import ExcelJS from 'exceljs';

// Colonnes pensées pour la prospection : ce qui décide d'aller frapper à la
// porte vient d'abord, le détail technique suit, les liens ferment la marche.
const COLUMNS = [
  { header: 'Jours en ligne', key: 'joursEnLigne', width: 13 },
  { header: 'Prix', key: 'prix', width: 13, fmt: '#,##0 "€"' },
  { header: '€/m²', key: 'prixM2', width: 10, fmt: '#,##0' },
  { header: 'Écart marché', key: 'ecartMarcheAffiche', width: 13, fmt: '+0"%";-0"%";0"%"' },
  { header: 'Ventes comparées', key: 'nbVentesComparables', width: 16 },
  { header: 'Commune', key: 'ville', width: 20 },
  { header: 'Adresse', key: 'adresseEstimee', width: 42 },
  { header: 'Confiance', key: 'niveauConfiance', width: 11 },
  { header: 'Surface', key: 'surface', width: 9, fmt: '0" m²"' },
  { header: 'Terrain', key: 'terrain', width: 11, fmt: '#,##0" m²"' },
  { header: 'Pièces', key: 'pieces', width: 8 },
  { header: 'DPE', key: 'dpe', width: 6 },
  { header: 'Parcelle', key: 'parcelle', width: 17 },
  { header: 'Publiée le', key: 'publieeLe', width: 12 },
  { header: 'Baisse de prix', key: 'baisseAffichee', width: 14 },
  { header: 'Statut', key: 'statutLabel', width: 16 },
  { header: 'Vendeur', key: 'vendeur', width: 16 },
  { header: 'Latitude', key: 'latitude', width: 12, fmt: '0.000000' },
  { header: 'Longitude', key: 'longitude', width: 12, fmt: '0.000000' },
  { header: 'Annonce', key: 'urlAnnonce', width: 16, link: true },
  { header: 'Carte', key: 'urlMaps', width: 14, link: true, linkText: 'Maps' },
];

/** Champs calculés au moment de l'export. */
function ligne(rec) {
  const comparable = rec.ecartMarchePct != null && Math.abs(rec.ecartMarchePct) <= 120;
  return {
    ...rec,
    statutLabel: STATUT_FR[rec.statut] ?? '',
    // Un écart de plusieurs centaines de pour cent ne compare plus rien :
    // le bien est sorti de son marché communal.
    ecartMarcheAffiche: comparable ? rec.ecartMarchePct : null,
    baisseAffichee: rec.nbBaisses ? 'oui' : '',
  };
}

const HEADER_FILL = 'FF1F3A5F';
const GREEN = 'FF1E7A46';
const RED = 'FFB3261E';
const AMBER = 'FF8A6100';
const BLUE = 'FF0B57D0';

/** Nomme un lien d'après son hôte : « ouvrir » ne dit pas où l'on va. */
function nomSource(url) {
  try {
    const h = new URL(url).hostname.replace(/^www\./, '');
    if (h.includes('leboncoin')) return 'leboncoin';
    if (h.includes('bienici')) return "Bien'ici";
    if (h.includes('seloger')) return 'SeLoger';
    return h;
  } catch {
    return 'ouvrir';
  }
}

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
    const row = ws.addRow(ligne(rec));

    for (const col of COLUMNS) {
      const cell = row.getCell(col.key);
      if (col.fmt) cell.numFmt = col.fmt;
      if (col.link && cell.value) {
        const url = String(cell.value);
        cell.value = { text: col.linkText ?? nomSource(url), hyperlink: url };
        cell.font = { color: { argb: 'FF0B57D0' }, underline: true };
      }
    }

    // Un coup d'œil doit suffire à repérer les annonces négociables.
    const ecart = row.getCell('ecartMarcheAffiche');
    if (typeof ecart.value === 'number') {
      ecart.font = { bold: true, color: { argb: ecart.value > 0 ? RED : GREEN } };
    }
    if (rec.statut === 'nouveau') {
      row.getCell('statutLabel').font = { color: { argb: AMBER }, bold: true };
    } else if (rec.statut === 'republie') {
      row.getCell('statutLabel').font = { color: { argb: BLUE }, bold: true };
    }

    // L'ancienneté est le premier signal de prospection : elle doit sauter aux yeux.
    const j = rec.joursEnLigne;
    if (typeof j === 'number') {
      const cell = row.getCell('joursEnLigne');
      cell.value = rec.ancienneteMinorant ? `≥ ${j}` : j;
      if (j >= 240) cell.font = { bold: true, color: { argb: RED } };
      else if (j >= 120) cell.font = { bold: true, color: { argb: AMBER } };
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
    // Virgule décimale : avec le point, Excel FR lit 43.52 comme du texte.
    let s = typeof v === 'number' ? String(v).replace('.', ',') : String(v);
    // Une cellule commençant par un opérateur serait interprétée comme formule.
    if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
    s = s.replace(/"/g, '""');
    return /[;\n"]/.test(s) ? `"${s}"` : s;
  };
  const lines = [COLUMNS.map((c) => esc(c.header)).join(';')];
  for (const rec of records) {
    lines.push(
      COLUMNS.map((c) => esc(ligne(rec)[c.key])).join(';')
    );
  }
  fs.writeFileSync(file, '﻿' + lines.join('\n'), 'utf8');
  return file;
}
