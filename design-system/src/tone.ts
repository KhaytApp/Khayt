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
  hot: '--khayt-hot',
  done: '--khayt-done',
  attention: '--khayt-attention',
  late: '--khayt-late',
  note: '--khayt-note',
  marked: '--khayt-marked',
};

export const TONES: Tone[] = ['brand', 'hot', 'done', 'attention', 'late', 'note', 'marked'];
