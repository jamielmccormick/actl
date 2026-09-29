// Harness identity for the UI: a two-letter code and a stable color slot. Harnesses are data, not brand.
import { paths } from "./config";
import type { Harness as DetectedHarness } from "./collect";
import { readJson, writeFileAtomic } from "./util";

export type Harness = DetectedHarness & { code: string; colorSlot: number };

const SLOTS = 6;
// English letters from most to least common: a rarer letter is a more distinctive second character.
const FREQ = "etaoinshrdlcumwfgypbvkjxqz";
const GENERIC = new Set(["cli", "github", "the"]);

/**
 * One rule for every harness: split the name into words (spaces and camelCase), ignoring generic words.
 * Two or more words give their initials; one word gives its first letter plus its rarest remaining letter.
 * On a collision the next rarest letter is tried, then a digit.
 * Claude Code → CC, Codex → CX, Cursor → CU, Gemini CLI → GM, OpenCode → OC.
 */
export function harnessCodes(names: string[]): string[] {
  const used = new Set<string>();
  return names.map((name) => {
    const words = name.split(/\s+/).filter((w) => w && !GENERIC.has(w.toLowerCase())).flatMap((w) => w.split(/(?<=[a-z])(?=[A-Z])/));
    const letters = (words.length ? words : [name]).map((w) => w.toLowerCase().replace(/[^a-z0-9]/g, "")).filter(Boolean);
    const candidates: string[] = [];
    if (letters.length >= 2) candidates.push(letters[0][0] + letters[1][0]);
    const w = letters[0] ?? "x";
    const rest = [...new Set(w.slice(1))].sort((a, b) => FREQ.indexOf(b) - FREQ.indexOf(a));
    candidates.push(...rest.map((c) => w[0] + c));
    const pick = candidates.map((c) => c.toUpperCase()).find((c) => !used.has(c)) ?? [...Array(10).keys()].map((i) => `${w[0].toUpperCase()}${i}`).find((c) => !used.has(c))!;
    used.add(pick);
    return pick;
  });
}

type State = { version: 1; colorSlots: Record<string, number> };
export const readState = (): State => readJson(paths.state) ?? { version: 1, colorSlots: {} };

/** Slots are assigned once, in the order harnesses are first seen installed, and never reshuffled. */
export function withIdentity(detected: DetectedHarness[], persist: boolean): Harness[] {
  const state = readState();
  const next = () => Object.keys(state.colorSlots).length % SLOTS;
  let changed = false;
  for (const h of detected)
    if (h.installed && state.colorSlots[h.id] === undefined) {
      state.colorSlots[h.id] = next();
      changed = true;
    }
  if (changed && persist) writeFileAtomic(paths.state, `${JSON.stringify(state, null, 2)}\n`);
  const codes = harnessCodes(detected.map((h) => h.name));
  let provisional = Object.keys(state.colorSlots).length;
  return detected.map((h, i) => ({ ...h, code: codes[i], colorSlot: state.colorSlots[h.id] ?? provisional++ % SLOTS }));
}
