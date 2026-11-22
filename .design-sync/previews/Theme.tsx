import { Theme, Card, Stat, Chip, SidebarRow, StagePill } from '@khayt/design-system';

function Sample() {
  return (
    <div style={{ display: 'flex', gap: 12, padding: 14, alignItems: 'flex-start' }}>
      <div style={{ width: 150, display: 'grid', gap: 1 }}>
        <SidebarRow label="Board" count={6} selected />
        <SidebarRow label="Library" count={152} />
      </div>
      <Card rail="hot" style={{ width: 200 }}>
        <Stat label="Printing" value="3" tone="hot" note="2h left on the U1" />
        <div style={{ marginTop: 8, display: 'flex', gap: 5 }}>
          <StagePill stage="printing" />
          <Chip tone="note">PLA</Chip>
        </div>
      </Card>
    </div>
  );
}

/**
 * The ground everything sits on. Wrap the page in this.
 *
 * Every Khayt component reads its colour, radius and type from custom
 * properties, and this is what puts them in scope. Without it a component still
 * renders — it just renders in whatever the host page happens to define, which
 * is how a design ends up looking like something else.
 */
export function Light() { return <Theme mode="light"><Sample /></Theme>; }

/** The same markup, one token swap. No geometry changes between the two. */
export function Dark() { return <Theme mode="dark"><Sample /></Theme>; }
