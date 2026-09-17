import { BoardColumn, JobCard, StagePill, Chip, Theme } from '@khayt/design-system';

/** The board as a shop stands in front of it. */
export function Lanes() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'flex', gap: 10, alignItems: 'flex-start' }}>
        <BoardColumn stage="printing" count={2}>
          <JobCard project="Falcon hood" client="Acme Robotics" material="PLA · Ink" priority
                   footer={<><StagePill stage="printing" /><Chip tone="hot">2h left</Chip></>} />
          <JobCard project="Bracket ×12" client="Bolt Co" material="PETG"
                   footer={<StagePill stage="printing" />} />
        </BoardColumn>
        <BoardColumn stage="qc" count={1}>
          <JobCard project="Dragon, 4 colour" client="Walk-in" material="PLA ×4"
                   footer={<StagePill stage="qc" />} />
        </BoardColumn>
        <BoardColumn stage="shipped" count={1}>
          <JobCard project="Portrait relief" client="Athar" material="PLA"
                   footer={<><StagePill stage="shipped" /><Chip tone="done">Paid</Chip></>} />
        </BoardColumn>
      </div>
    </Theme>
  );
}

/** A lane with nothing in it says so, rather than being a blank rectangle. */
export function EmptyLane() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'flex', gap: 10, alignItems: 'flex-start' }}>
        <BoardColumn stage="post" count={0} />
        <BoardColumn stage="on_hold" count={1}>
          <JobCard project="Sign, backlit" client="Bolt Co" material="PETG"
                   footer={<><StagePill stage="on_hold" /><Chip tone="attention">Waiting on part</Chip></>} />
        </BoardColumn>
      </div>
    </Theme>
  );
}

export function Dark() {
  return (
    <Theme mode="dark">
      <div style={{ padding: 16, display: 'flex', gap: 10, alignItems: 'flex-start' }}>
        <BoardColumn stage="printing" count={1}>
          <JobCard project="Falcon hood" client="Acme Robotics" material="PLA" priority
                   footer={<><StagePill stage="printing" /><Chip tone="hot">2h left</Chip></>} />
        </BoardColumn>
        <BoardColumn stage="completed" count={1}>
          <JobCard project="Bracket ×12" client="Bolt Co" material="PETG"
                   footer={<StagePill stage="completed" />} />
        </BoardColumn>
      </div>
    </Theme>
  );
}
