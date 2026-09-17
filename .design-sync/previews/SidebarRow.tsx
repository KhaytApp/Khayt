import { SidebarRow, Theme } from '@khayt/design-system';

/**
 * The sidebar as Khayt draws it.
 *
 * The count sits on the right, tabular, so the column lines up down the edge.
 * A row with no count leaves the space empty rather than drawing a zero —
 * "nothing here" and "this is not a thing you count" are different facts, and
 * Reports is the second.
 */
export function Nav() {
  return (
    <Theme>
      <div style={{ padding: 12, width: 210, display: 'grid', gap: 1 }}>
        <SidebarRow label="Dashboard" />
        <SidebarRow label="Jobs" count={19} selected />
        <SidebarRow label="Board" count={6} />
        <SidebarRow label="Library" count={152} />
        <SidebarRow label="Customers" count={0} />
        <SidebarRow label="Machines" count={2} />
        <SidebarRow label="Inventory" count={3} />
        <SidebarRow label="Reports" />
      </div>
    </Theme>
  );
}

export function Dark() {
  return (
    <Theme mode="dark">
      <div style={{ padding: 12, width: 210, display: 'grid', gap: 1 }}>
        <SidebarRow label="Dashboard" />
        <SidebarRow label="Board" count={6} selected />
        <SidebarRow label="Library" count={152} />
        <SidebarRow label="Reports" />
      </div>
    </Theme>
  );
}
