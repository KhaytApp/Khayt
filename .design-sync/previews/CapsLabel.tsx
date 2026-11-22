import { CapsLabel, BigFigure, Card, Theme } from '@khayt/design-system';

/**
 * Where it is actually used: naming the figure under it.
 *
 * The label goes ABOVE, not below. A column of these is read downward, and a
 * shop scanning for "takings" should not have to find the number first and
 * then look under it.
 */
export function InUse() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'flex', gap: 10 }}>
        <Card><CapsLabel>Takings</CapsLabel><div><BigFigure value="4,820" unit="SAR" /></div></Card>
        <Card rail="hot"><CapsLabel tone="hot">Printing</CapsLabel><div><BigFigure value="3" tone="hot" /></div></Card>
        <Card rail="late"><CapsLabel tone="late">Late</CapsLabel><div><BigFigure value="2" tone="late" /></div></Card>
      </div>
    </Theme>
  );
}

/**
 * Tracked open, because uppercase at nine and a half pixels closes up and
 * stops being readable. The spec writes tracking in ems, so a label set larger
 * opens proportionally rather than staying at a fixed pixel gap.
 */
export function Tones() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'grid', gap: 7, width: 260 }}>
        <CapsLabel>This month</CapsLabel>
        <CapsLabel tone="hot">Printing now</CapsLabel>
        <CapsLabel tone="attention">Wants a person</CapsLabel>
        <CapsLabel tone="done">Finished</CapsLabel>
        <CapsLabel size={13}>Set larger, tracking scales</CapsLabel>
      </div>
    </Theme>
  );
}

export function Dark() {
  return (
    <Theme mode="dark">
      <div style={{ padding: 16, display: 'flex', gap: 10 }}>
        <Card><CapsLabel>Takings</CapsLabel><div><BigFigure value="4,820" unit="SAR" /></div></Card>
        <Card rail="done"><CapsLabel tone="done">Finished</CapsLabel><div><BigFigure value="12" tone="done" /></div></Card>
      </div>
    </Theme>
  );
}
