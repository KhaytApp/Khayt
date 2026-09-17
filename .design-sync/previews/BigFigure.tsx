import { BigFigure, Card, CapsLabel, Theme } from '@khayt/design-system';

/**
 * Semibold, not bold. At this size bold is shouting, and everything else on
 * the screen would then have to shout back.
 */
export function Figures() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'flex', gap: 10 }}>
        <Card><CapsLabel>Takings</CapsLabel><div><BigFigure value="4,820" unit="SAR" /></div></Card>
        <Card><CapsLabel>Late</CapsLabel><div><BigFigure value="2" tone="late" /></div></Card>
        <Card><CapsLabel>Printing</CapsLabel><div><BigFigure value="3" tone="hot" /></div></Card>
      </div>
    </Theme>
  );
}

/** Sizes. The unit stays at 42% of the value, so it scales with it. */
export function Sizes() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'flex', alignItems: 'baseline', gap: 18 }}>
        <BigFigure value="128" unit="g" size={20} />
        <BigFigure value="128" unit="g" />
        <BigFigure value="128" unit="g" size={48} />
      </div>
    </Theme>
  );
}
