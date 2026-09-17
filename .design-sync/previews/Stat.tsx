import { Stat, Card, Theme } from '@khayt/design-system';

/** What a dashboard row of figures looks like. */
export function Figures() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, width: 480 }}>
        <Card><Stat label="This month" value="4,820" unit="SAR" note="18 jobs" /></Card>
        <Card><Stat label="On the floor" value="6" note="2 printing" /></Card>
        <Card><Stat label="Owed" value="1,150" unit="SAR" tone="attention" note="3 unpaid" /></Card>
      </div>
    </Theme>
  );
}

/** A figure that is news, and one that is not. Most are not. */
export function Toned() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, width: 340 }}>
        <Card><Stat label="Finished" value="12" tone="done" /></Card>
        <Card><Stat label="Late" value="2" tone="late" note="oldest 4 days" /></Card>
      </div>
    </Theme>
  );
}

export function Dark() {
  return (
    <Theme mode="dark">
      <div style={{ padding: 16, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, width: 340 }}>
        <Card><Stat label="This month" value="4,820" unit="SAR" /></Card>
        <Card><Stat label="Late" value="2" tone="late" /></Card>
      </div>
    </Theme>
  );
}
