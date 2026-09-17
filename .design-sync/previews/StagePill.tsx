import { StagePill, STAGES, Theme } from '@khayt/design-system';

/**
 * Every stage, in the order work moves through them.
 *
 * Most have no colour, and that is the point: ten stages given ten colours is
 * a rainbow. Only the ones that are an instance of a palette sentence get one
 * — printing is "being made right now", on hold "wants a person", completed
 * and shipped and delivered are "finished", cancelled is "failed".
 */
export function AllStages() {
  return (
    <Theme>
      <div style={{ padding: 16, display: 'flex', flexWrap: 'wrap', gap: 6, width: 420 }}>
        {STAGES.map((s) => <StagePill key={s} stage={s} />)}
      </div>
    </Theme>
  );
}

export function Dark() {
  return (
    <Theme mode="dark">
      <div style={{ padding: 16, display: 'flex', flexWrap: 'wrap', gap: 6, width: 420 }}>
        {STAGES.map((s) => <StagePill key={s} stage={s} />)}
      </div>
    </Theme>
  );
}
