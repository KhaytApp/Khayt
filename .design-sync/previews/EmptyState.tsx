import { EmptyState, Card, Theme } from '@khayt/design-system';

/**
 * What a shop sees before it has done anything.
 *
 * Says what would be here and how it gets here — an empty screen that only
 * says "no data" is indistinguishable from one that failed to load.
 */
export function Empty() {
  return (
    <Theme>
      <div style={{ padding: 16, width: 360 }}>
        <Card>
          <EmptyState title="No jobs yet">
            A job appears here once you take one. Press ⌘N, or use the plus in the toolbar.
          </EmptyState>
        </Card>
      </div>
    </Theme>
  );
}

export function Dark() {
  return (
    <Theme mode="dark">
      <div style={{ padding: 16, width: 360 }}>
        <Card>
          <EmptyState title="Nothing on the shelf">
            Spools you add show up here, with what is left on each.
          </EmptyState>
        </Card>
      </div>
    </Theme>
  );
}
