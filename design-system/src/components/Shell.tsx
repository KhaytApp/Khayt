import type { ReactNode } from 'react';
import { TONE_VAR, type Tone } from '../tone';

export interface ThemeProps {
  /**
   * Which set of colours. Omit to follow the viewer's own setting — the token
   * file redefines every colour under `prefers-color-scheme: dark`, so a page
   * that never sets this still works in both.
   */
  mode?: 'light' | 'dark';
  children?: ReactNode;
}

/**
 * The ground everything sits on, and the colours it sits in.
 *
 * **Wrap the page in this.** Every Khayt component reads its colour, radius and
 * type from custom properties, and this is what puts them in scope. Without it
 * a component still renders — it just renders in whatever the host page happens
 * to define, which is how a design ends up looking like something else.
 *
 * Setting `mode` pins the theme; leaving it off follows the viewer.
 */
export function Theme({ mode, children }: ThemeProps) {
  return (
    <div className="khayt-theme" data-theme={mode}>
      {children}
    </div>
  );
}

export interface StatProps {
  /** What the figure is, set small and tracked open above it. */
  label: string;
  /** The figure, already formatted. */
  value: string;
  /** A unit beside the figure. */
  unit?: string;
  /** A semantic colour, when the figure is news. Most are not. */
  tone?: Tone;
  /** A line under the figure — a comparison, a note, a count. */
  note?: ReactNode;
}

/**
 * One figure with its name, on a card.
 *
 * The label goes **above** the figure, not below it: a column of these is read
 * downward, and a shop scanning for "revenue" should not have to find the
 * number first and then look under it.
 */
export function Stat({ label, value, unit, tone, note }: StatProps) {
  return (
    <div className="khayt-stat">
      <span className="khayt-caps khayt-stat__label">{label}</span>
      <span
        className="khayt-figure khayt-stat__figure"
        style={tone ? { ['--khayt-figure-tone' as string]: `var(${TONE_VAR[tone]})` } : undefined}
      >
        <span className="khayt-figure__value">{value}</span>
        {unit ? <span className="khayt-figure__unit">{unit}</span> : null}
      </span>
      {note ? <p className="khayt-stat__note">{note}</p> : null}
    </div>
  );
}

export interface SidebarRowProps {
  /** The screen's name. */
  label: string;
  /** How many things are on it. Omitted where a count is not a thing it has. */
  count?: number;
  /** Currently showing. */
  selected?: boolean;
  /** A leading glyph. */
  icon?: ReactNode;
}

/**
 * One destination in the sidebar.
 *
 * The count is on the right, tabular, so a column of rows lines up down the
 * edge. A row with no count leaves the space empty rather than drawing a zero:
 * "nothing here" and "this is not a thing you count" are different facts.
 */
export function SidebarRow({ label, count, selected, icon }: SidebarRowProps) {
  return (
    <div className="khayt-navrow" data-selected={selected ? '' : undefined}>
      {icon ? <span className="khayt-navrow__icon">{icon}</span> : null}
      <span className="khayt-navrow__label">{label}</span>
      {count !== undefined ? <span className="khayt-navrow__count">{count}</span> : null}
    </div>
  );
}

export interface EmptyStateProps {
  /** What is not here. */
  title: string;
  /** What to do about it, in a sentence. */
  children?: ReactNode;
}

/**
 * A screen with nothing on it yet.
 *
 * Says what would be here and how it gets here. An empty screen that only says
 * "no data" is indistinguishable from one that failed to load, and a shop that
 * has just opened the app sees a lot of these.
 */
export function EmptyState({ title, children }: EmptyStateProps) {
  return (
    <div className="khayt-empty">
      <p className="khayt-empty__title">{title}</p>
      {children ? <p className="khayt-empty__body">{children}</p> : null}
    </div>
  );
}
