import type { ReactNode } from 'react';
import { TONE_VAR, type Tone } from '../tone';

export interface CapsLabelProps {
  /** The text. It is uppercased by the component, so pass it in sentence case. */
  children: ReactNode;
  /** A semantic colour. Defaults to the quiet one a label should usually be. */
  tone?: Tone;
  /** Type size. Tracking scales with it, as the spec writes it in ems. */
  size?: number;
}

/**
 * The small caps label above a figure or a group.
 *
 * Tracked open, because uppercase at nine and a half pixels closes up and stops
 * being readable. The spec writes tracking in ems and the size multiplies it,
 * so a label set larger opens proportionally rather than staying at a fixed
 * pixel gap.
 *
 * Mirrors the Mac app's `CapsLabel`.
 */
export function CapsLabel({ children, tone, size = 9.5 }: CapsLabelProps) {
  return (
    <span
      className="khayt-caps"
      style={{
        ['--khayt-caps-size' as string]: `${size}px`,
        ...(tone ? { ['--khayt-caps-tone' as string]: `var(${TONE_VAR[tone]})` } : null),
      }}
    >
      {children}
    </span>
  );
}
