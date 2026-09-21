import { Card, Chip, CapsLabel, BigFigure, Theme } from '@khayt/design-system';

/** The ordinary case, which is most cards: no rail. */
export function Plain() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'grid', gap: 10, width: 280 }}>
        <Card>
          <CapsLabel>This month</CapsLabel>
          <div style={{ marginTop: 4 }}><BigFigure value="4,820" unit="SAR" /></div>
        </Card>
      </div>
    </Theme>
  );
}

/**
 * Railed, one per meaning. A card with nothing to say gets no rail — that is
 * the half that makes it work, and why the plain card above comes first.
 */
export function Railed() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'grid', gap: 10, width: 280 }}>
        <Card rail="hot">
          <CapsLabel tone="hot">Printing</CapsLabel>
          <p style={{ margin: '4px 0 0' }}>Falcon hood, 2h left</p>
        </Card>
        <Card rail="attention">
          <CapsLabel tone="attention">Wants a person</CapsLabel>
          <p style={{ margin: '4px 0 0' }}>Spool below 200g</p>
        </Card>
        <Card rail="late">
          <CapsLabel tone="late">Late</CapsLabel>
          <p style={{ margin: '4px 0 0' }}>Due yesterday</p>
        </Card>
      </div>
    </Theme>
  );
}

/**
 * A card that OPENS something. Opt-in, and the reason it is opt-in is the
 * whole point: most cards do not lift, so the ones that do read as pressable.
 * It takes a focus ring from the keyboard as well as the pointer.
 */
export function Pressable() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'grid', gap: 10, width: 280 }}>
        <Card pressable>
          <CapsLabel>Opens the job</CapsLabel>
          <p style={{ margin: '4px 0 0' }}>Falcon hood &times; 4</p>
        </Card>
        <Card>
          <CapsLabel tone="note">Opens nothing</CapsLabel>
          <p style={{ margin: '4px 0 0' }}>This one must not lift.</p>
        </Card>
      </div>
    </Theme>
  );
}

/** Dark, which is one token swap and no geometry change. */
export function Dark() {
  return (
    <Theme mode="dark">
      <div style={{ padding: 16, display: 'grid', gap: 10, width: 280 }}>
        <Card rail="done">
          <CapsLabel tone="done">Completed</CapsLabel>
          <div style={{ marginTop: 4, display: 'flex', gap: 6 }}>
            <Chip tone="done">Paid</Chip>
            <Chip tone="note">PLA</Chip>
          </div>
        </Card>
      </div>
    </Theme>
  );
}
