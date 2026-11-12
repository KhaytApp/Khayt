/**
 * Khayt's semantic colours — the ones `Palette.swift` gives a sentence to.
 *
 * ── THESE ARE NOT A RAINBOW TO PICK FROM ───────────────────────────────────
 *
 * Every one means something, and the meaning is the reason to reach for it:
 *
 *   hot        "something is being made right now" — the drop of filament in
 *              the app's own icon, and the one state worth looking up at
 *   done       "finished, paid, sent, agreed"
 *   attention  "wants a person, and will keep working if it does not get one"
 *   late       "late, failed, refused"
 *   note       a remark, an aside, something the shop wrote down
 *   marked     flagged by the shop itself — a priority it set
 *   brand      the app's own blue, for the one action a screen is FOR
 *
 * Nine stages given nine colours is a rainbow, and a rainbow is what a colour
 * scheme looks like when it has stopped meaning anything. Most things in Khayt
 * are the colour of ordinary text, on purpose: the ordinary course of a job is
 * not news. If something here seems to need a colour it does not have, the
 * question to answer first is which of these sentences it is an instance of.
 *
 * Contrast is measured in `Palette.swift` against `Khayt.surface`, in both
 * light and dark. Putting one of these on any other background is a figure
 * nobody has checked.
 */
export type Tone = 'brand' | 'hot' | 'done' | 'attention' | 'late' | 'note' | 'marked';

/** The custom property each tone resolves to. */
export const TONE_VAR: Record<Tone, string> = {
  brand: '--khayt-brand',
  // Printing is the thread amber since Nov 2026 (Palette.swift has no `hot`).
  // The tone keeps its name. This is the FILL: a rail, a wash, a dot. Words
  // in this tone go through `toneInk`, because amber is not a text colour.
  hot: '--khayt-thread',
  done: '--khayt-done',
  attention: '--khayt-attention',
  late: '--khayt-late',
  note: '--khayt-note',
  marked: '--khayt-marked',
};

/**
 * The colour a tone's WORDS and figures are set in, as a CSS value.
 *
 * Every tone is its own text colour except `hot`. The thread amber measures
 * under 3:1 on the light surface, so the Mac app never sets a word in it
 * (`PaletteTests.amberIsNeverText`): the mark beside the word is amber and
 * the word is the ordinary ink around it. `currentColor` is exactly that.
 * It is NOT the attention colour: that one means "wants a person", and a
 * print that is running does not.
 */
export function toneInk(tone: Tone): string {
  return tone === 'hot' ? 'currentColor' : `var(${TONE_VAR[tone]})`;
}

export const TONES: Tone[] = ['brand', 'hot', 'done', 'attention', 'late', 'note', 'marked'];
