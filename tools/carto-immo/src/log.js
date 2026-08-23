import fs from 'node:fs';
import path from 'node:path';

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };
let threshold = LEVELS.info;
let logFile = null;

export function configureLog({ level = 'info', file = null } = {}) {
  threshold = LEVELS[level] ?? LEVELS.info;
  if (file) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    logFile = file;
  }
}

function stamp() {
  return new Date().toISOString().replace('T', ' ').slice(0, 19);
}

/**
 * Observateurs du journal : l'agent local y branche la carte, pour montrer
 * l'avancement d'une analyse lancée d'un clic.
 */
let observateurs = [];

export function observerLog(fn) {
  observateurs.push(fn);
  return () => { observateurs = observateurs.filter((o) => o !== fn); };
}

function emit(level, icon, args) {
  if (LEVELS[level] < threshold) return;
  const line = args
    .map((a) => (typeof a === 'string' ? a : JSON.stringify(a)))
    .join(' ');
  const out = `${icon} ${line}`;
  for (const o of observateurs) {
    // Un observateur qui échoue ne doit pas interrompre l'exécution journalisée.
    try { o({ level, line, texte: out }); } catch { /* rien */ }
  }
  if (level === 'error' || level === 'warn') console.error(out);
  else console.log(out);
  if (logFile) {
    fs.appendFileSync(logFile, `${stamp()} [${level}] ${line}\n`);
  }
}

export const log = {
  debug: (...a) => emit('debug', '  ·', a),
  info: (...a) => emit('info', '  ', a),
  step: (...a) => emit('info', '▸', a),
  ok: (...a) => emit('info', '✓', a),
  warn: (...a) => emit('warn', '!', a),
  error: (...a) => emit('error', '✗', a),
};

/** Pause polie entre deux requêtes, avec une part d'aléatoire. */
export function sleep(ms, jitterRatio = 0.35) {
  const jitter = ms * jitterRatio * (Math.random() * 2 - 1);
  return new Promise((r) => setTimeout(r, Math.max(0, Math.round(ms + jitter))));
}
