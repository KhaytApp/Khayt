import type { ReactNode } from 'react';
import { STAGE_LABEL, STAGE_TONE, type Stage } from './Stage';
import { TONE_VAR } from '../tone';

export interface BoardColumnProps {
  /** Which stage this column holds. */
  stage: Stage;
  /** How many cards are in it. Drawn beside the name. */
  count?: number;
  /** Override the column's name. */
  label?: string;
  /** The cards. */
  children?: ReactNode;
}

/**
 * One lane of the board.
 *
 * Narrow on purpose — enough for a two-line job name, and no more, so that a
 * shop with eight stages gets a short scroll rather than a long one. An empty
 * column says so in words rather than being a blank rectangle, because a column
 * that might not have loaded and a column with nothing in it look identical
 * otherwise.
 */
export function BoardColumn({ stage, count, label, children }: BoardColumnProps) {
  const tone = STAGE_TONE[stage];
  const empty = children == null || (Array.isArray(children) && children.length === 0);
  return (
    <section
      className="khayt-lane"
      data-stage={stage}
      style={tone ? { ['--khayt-lane-tone' as string]: `var(${TONE_VAR[tone]})` } : undefined}
    >
      <header className="khayt-lane__head">
        <span className="khayt-lane__dot" aria-hidden="true" />
        <span className="khayt-lane__name">{label ?? STAGE_LABEL[stage]}</span>
        {count !== undefined ? <span className="khayt-lane__count">{count}</span> : null}
      </header>
      <div className="khayt-lane__body">
        {empty ? <p className="khayt-lane__empty">Nothing here</p> : children}
      </div>
    </section>
  );
}

export interface JobCardProps {
  /** What the job is. The line a shop scans for. */
  project: string;
  /** Who it is for. Omitted for a job with no customer. */
  client?: string;
  /** What it is being printed in, in the shop's own words. */
  material?: string;
  /** Flagged by the shop as urgent. */
  priority?: boolean;
  /** A thumbnail of the model, when the library has one. */
  thumbnail?: ReactNode;
  /** Chips, a stage pill, anything the card carries along the bottom. */
  footer?: ReactNode;
}

/**
 * A job, on the board.
 *
 * A column of cards is **scanned rather than read**, which is why the picture
 * comes first: the thing itself is found faster than its name. The priority
 * flag sits on the first baseline beside the title rather than floating at the
 * middle of a title that wrapped.
 */
export function JobCard({ project, client, material, priority, thumbnail, footer }: JobCardProps) {
  return (
    <article className="khayt-job">
      <div className="khayt-job__top">
        {thumbnail ? <div className="khayt-job__thumb">{thumbnail}</div> : null}
        <div className="khayt-job__text">
          <h4 className="khayt-job__title">
            {priority ? <span className="khayt-job__flag" aria-label="Priority">⚑</span> : null}
            {project}
          </h4>
          {client ? <p className="khayt-job__client">{client}</p> : null}
          {material ? <p className="khayt-job__material">{material}</p> : null}
        </div>
      </div>
      {footer ? <div className="khayt-job__footer">{footer}</div> : null}
    </article>
  );
}
