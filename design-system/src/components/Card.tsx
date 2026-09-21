import type { ReactNode, CSSProperties } from 'react';
import { TONE_VAR, type Tone } from '../tone';

export interface CardProps {
  /**
   * The colour of what the card is about, or omitted for the ordinary case.
   *
   * **A card with nothing to say gets no rail**, and that is the half that
   * makes it work: a device on everything is wallpaper, and the eye stops
   * reading it. The rail is worth looking at because most cards do not have
   * one. It is also never the only signal — every railed card in Khayt sits
   * beside a title saying the same thing in words, so a shop reading this
   * screen colour-blind loses nothing.
   */
  rail?: Tone;
  /** Inner padding. Defaults to the app's one card padding. */
  padding?: number;
  /**
   * Stretch to the height offered instead of hugging the content — for a card
   * in a grid row where the row is already as tall as its tallest card, and a
   * short one would otherwise leave the rest of that height as a gap.
   */
  fills?: boolean;
  /**
   * This card OPENS something, so it answers the pointer.
   *
   * Opt-in, exactly as in the Mac app: `Motion.swift` gives `liftsOnHover` as
   * "the whole vocabulary for 'this is yours to press', used on every card and
   * tile that opens something" — which means a card that opens nothing must
   * not lift. A board where everything moves under the pointer teaches a shop
   * that movement means nothing.
   */
  pressable?: boolean;
  children?: ReactNode;
  className?: string;
  style?: CSSProperties;
}

/**
 * Khayt's card. One corner radius, one border, one padding.
 *
 * Set in one place so that "a panel" is a decision made once rather than at
 * ninety call sites with slightly different numbers. This mirrors the Mac
 * app's `.card(rail:padding:fills:)` modifier, and takes its geometry from the
 * same source: radius 10, a 1px hairline border, 12pt padding, and a 3pt rail
 * inset 5pt from the leading edge when one is asked for.
 */
export function Card({ rail, padding, fills, pressable, children, className, style }: CardProps) {
  return (
    <div
      className={['khayt-card', fills ? 'khayt-card--fills' : '',
                  pressable ? 'khayt-card--pressable' : '', className].filter(Boolean).join(' ')}
      style={{
        ...(padding !== undefined ? { ['--khayt-card-padding' as string]: `${padding}px` } : null),
        ...(rail ? { ['--khayt-card-rail' as string]: `var(${TONE_VAR[rail]})` } : null),
        ...style,
      }}
      data-rail={rail ? '' : undefined}
      tabIndex={pressable ? 0 : undefined}
    >
      {children}
    </div>
  );
}
