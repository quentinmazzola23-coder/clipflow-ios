import fs from 'node:fs';

/**
 * Base locale, un simple fichier JSON. Volume attendu : quelques milliers de
 * fiches au plus, une vraie base serait de la sur-ingénierie ici.
 */
export function loadStore(file) {
  if (!fs.existsSync(file)) return { version: 1, updatedAt: null, records: {} };
  try {
    const s = JSON.parse(fs.readFileSync(file, 'utf8'));
    s.records ??= {};
    return s;
  } catch {
    // Fichier corrompu : on le met de côté plutôt que de perdre l'exécution.
    fs.renameSync(file, `${file}.corrupt-${Date.now()}`);
    return { version: 1, updatedAt: null, records: {} };
  }
}

export function saveStore(file, store) {
  store.updatedAt = new Date().toISOString();
  fs.writeFileSync(file, JSON.stringify(store, null, 1));
}

/** Faut-il (ré)analyser cette annonce ? */
export function needsAnalysis(store, id, reanalyseAfterDays) {
  const rec = store.records[id];
  if (!rec) return true;
  if (!reanalyseAfterDays) return false;
  const age = (Date.now() - new Date(rec.collecteLe).getTime()) / 86400000;
  return age >= reanalyseAfterDays;
}

/**
 * Enregistre une fiche en conservant la trace des variations de prix
 * constatées d'une exécution à l'autre.
 */
export function upsert(store, record) {
  const prev = store.records[record.id];
  const suivi = prev?.suiviPrix ? [...prev.suiviPrix] : [];

  if (record.prix != null) {
    const last = suivi[suivi.length - 1];
    if (!last || last.prix !== record.prix) {
      suivi.push({ date: record.collecteLe.slice(0, 10), prix: record.prix });
    }
  }

  const merged = {
    ...record,
    suiviPrix: suivi,
    vuePremiereFois: prev?.vuePremiereFois ?? record.collecteLe,
    nouvelle: !prev,
    baisseDepuisSuivi:
      suivi.length > 1 ? suivi[0].prix - suivi[suivi.length - 1].prix : 0,
  };

  store.records[record.id] = merged;
  return merged;
}

export function allRecords(store) {
  return Object.values(store.records).sort((a, b) => {
    const da = a.collecteLe || '';
    const db = b.collecteLe || '';
    return db.localeCompare(da);
  });
}
