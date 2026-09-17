import { TONE_VAR, type Tone } from '../tone';

export interface BigFigureProps {
  /** The figure itself, already formatted — this draws it, it does not round it. */
  value: string;
  /** A unit or suffix, set smaller and quieter beside it. */
  unit?: string;
  /** A semantic colour, when the figure is news. Most figures are not. */
  tone?: Tone;
  /** Type size for the value. The unit is set at 42% of it. */
  size?: number;
}

/**
 * The one number a card is about.
 *
 * **Semibold, not bold.** At this size bold is shouting, and everything else on
 * the screen would then have to shout back. The digits are tabular so a figure
 * that ticks upward does not jitter, and the face is rounded because the app's
 * mark is a drawn letter with no sharp terminals and the numbers should belong
 * to it.
 *
 * Mirrors the Mac app's `BigFigure`: 34px default, unit at 0.42 of that,
 * baseline-aligned with 5px between them.
 */
export function BigFigure({ value, unit, tone, size = 34 }: BigFigureProps) {
  return (
    <span
      className="khayt-figure"
      style={{
        ['--khayt-figure-size' as string]: `${size}px`,
        ...(tone ? { ['--khayt-figure-tone' as string]: `var(${TONE_VAR[tone]})` } : null),
      }}
    >
      <span className="khayt-figure__value">{value}</span>
      {unit ? <span className="khayt-figure__unit">{unit}</span> : null}
    </span>
  );
}
