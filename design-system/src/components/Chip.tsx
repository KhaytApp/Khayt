import type { ReactNode } from 'react';
import { TONE_VAR, type Tone } from '../tone';

export interface ChipProps {
  /** The label. Figures inside it are tabular, so a column of chips lines up. */
  children: ReactNode;
  /**
   * Which of Khayt's semantic colours this is an instance of. Defaults to
   * `brand`. See `Tone` — these are sentences, not a palette to pick from.
   */
  tone?: Tone;
  /** An optional leading glyph. */
  icon?: ReactNode;
}

/**
 * A small fact, worn by whatever it belongs to.
 *
 * The background is **a wash of the chip's own hue**, never a second colour, so
 * a chip can never introduce a colour the palette has not accounted for. That
 * is the whole trick: one tone, at full strength for the text and at 13% for
 * the ground behind it.
 *
 * Mirrors the Mac app's `Chip` — same 10px semibold text, same 6/2 padding,
 * same capsule, same 0.13 wash.
 */
export function Chip({ children, tone = 'brand', icon }: ChipProps) {
  return (
    <span className="khayt-chip" style={{ ['--khayt-chip-tone' as string]: `var(${TONE_VAR[tone]})` }}>
      {icon ? <span className="khayt-chip__icon">{icon}</span> : null}
      {children}
    </span>
  );
}
