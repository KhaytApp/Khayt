import { Chip, Theme, TONES } from '@khayt/design-system';

/**
 * Every tone. The ground behind each is a wash of the chip's OWN hue, never a
 * second colour — so a chip can never introduce a colour the palette has not
 * accounted for.
 */
export function AllTones() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'flex', flexWrap: 'wrap', gap: 6, width: 380 }}>
        {TONES.map((t) => <Chip key={t} tone={t}>{t}</Chip>)}
      </div>
    </Theme>
  );
}

/** In use: the facts a job card carries along its bottom edge. */
export function OnAJob() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'flex', gap: 6 }}>
        <Chip tone="hot">2h left</Chip>
        <Chip tone="done">Paid</Chip>
        <Chip tone="note">PLA ×4</Chip>
        <Chip tone="attention">Low spool</Chip>
      </div>
    </Theme>
  );
}

export function Dark() {
  return (
    <Theme mode="dark">
      <div style={{ padding: 16, display: 'flex', flexWrap: 'wrap', gap: 6, width: 380 }}>
        {TONES.map((t) => <Chip key={t} tone={t}>{t}</Chip>)}
      </div>
    </Theme>
  );
}
