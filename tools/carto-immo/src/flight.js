/**
 * Décodeur de payload Next.js "RSC flight".
 *
 * Les pages de lacquereur.fr (et de leboncoin) sont rendues côté serveur par
 * Next.js App Router : la totalité des données de la page est sérialisée dans
 * une suite de `self.__next_f.push([1,"...">])`. On reconstitue ce flux puis on
 * y pêche des objets JSON par nom de clé, sans dépendre du DOM (qui change
 * beaucoup plus souvent que les données).
 */

/** Reconstitue le flux RSC complet à partir du HTML d'une page. */
export function decodeFlight(html) {
  const chunks = [];
  const re = /self\.__next_f\.push\(\[1\s*,\s*("(?:[^"\\]|\\.)*")\s*\]\)/g;
  let m;
  while ((m = re.exec(html)) !== null) {
    try {
      chunks.push(JSON.parse(m[1]));
    } catch {
      /* fragment illisible : on l'ignore plutôt que de casser la page entière */
    }
  }
  return chunks.join('');
}

/**
 * Extrait la sous-chaîne d'un objet JSON équilibré démarrant à `start`.
 * Tient compte des chaînes et des échappements pour ne pas compter une
 * accolade présente dans une description d'annonce.
 */
export function balancedObject(text, start) {
  if (text[start] !== '{') return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') inString = true;
    else if (c === '{') depth++;
    else if (c === '}') {
      depth--;
      if (depth === 0) return text.slice(start, i + 1);
    }
  }
  return null;
}

/**
 * Cherche dans `text` le plus petit objet JSON valide qui contient toutes les
 * clés `requiredKeys`. Remonte depuis l'occurrence de la première clé jusqu'à
 * trouver une accolade ouvrante qui produit un objet parsable.
 *
 * @param {string} text        flux RSC décodé
 * @param {string[]} requiredKeys clés devant toutes être présentes
 * @param {number} lookback    nombre de caractères remontés au maximum
 */
export function findObjectWithKeys(text, requiredKeys, lookback = 200000) {
  const anchor = `"${requiredKeys[0]}"`;
  let searchFrom = 0;
  for (;;) {
    const at = text.indexOf(anchor, searchFrom);
    if (at === -1) return null;
    searchFrom = at + anchor.length;

    let best = null;
    const floor = Math.max(0, at - lookback);
    for (let i = at; i >= floor; i--) {
      if (text[i] !== '{') continue;
      const raw = balancedObject(text, i);
      if (!raw || raw.length < anchor.length) continue;
      if (!requiredKeys.every((k) => raw.includes(`"${k}"`))) continue;
      let parsed;
      try {
        parsed = JSON.parse(raw);
      } catch {
        continue;
      }
      // On garde le candidat le plus englobant trouvé en remontant.
      best = parsed;
    }
    if (best) return best;
  }
}

/** Collecte tous les objets JSON valides contenant les clés demandées. */
export function collectObjectsWithKeys(text, requiredKeys, { limit = 5000 } = {}) {
  const anchor = `"${requiredKeys[0]}"`;
  const out = [];
  const seen = new Set();
  let from = 0;
  while (out.length < limit) {
    const at = text.indexOf(anchor, from);
    if (at === -1) break;
    from = at + anchor.length;
    for (let i = at; i >= Math.max(0, at - 20000); i--) {
      if (text[i] !== '{') continue;
      const raw = balancedObject(text, i);
      if (!raw) continue;
      if (!requiredKeys.every((k) => raw.includes(`"${k}"`))) continue;
      let parsed;
      try {
        parsed = JSON.parse(raw);
      } catch {
        continue;
      }
      const key = raw.length + ':' + raw.slice(0, 120);
      if (!seen.has(key)) {
        seen.add(key);
        out.push(parsed);
      }
      break;
    }
  }
  return out;
}

/** Récupère le JSON de `<script id="__NEXT_DATA__">` (Pages Router). */
export function decodeNextData(html) {
  const m = html.match(
    /<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/
  );
  if (!m) return null;
  try {
    return JSON.parse(m[1]);
  } catch {
    return null;
  }
}
