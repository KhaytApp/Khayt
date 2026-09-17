import { TONE_VAR, type Tone } from '../tone';

/**
 * The stages a job moves through, in the order work moves through them.
 *
 * `shipped` and `delivered` are NOT statuses a job carries — both are a date
 * stamped on a job that stays `completed`, and the app derives the stage from
 * the pair. They are stages all the same: they are what the board draws.
 */
export type Stage =
  | 'quote' | 'pending' | 'on_hold' | 'printing' | 'post' | 'qc'
  | 'completed' | 'shipped' | 'delivered' | 'cancelled';

export const STAGES: Stage[] = [
  'quote', 'pending', 'on_hold', 'printing', 'post', 'qc',
  'completed', 'shipped', 'delivered', 'cancelled',
];

/** How each stage is written on screen. */
export const STAGE_LABEL: Record<Stage, string> = {
  quote: 'Quote', pending: 'Queue', on_hold: 'On hold', printing: 'Printing',
  post: 'Post', qc: 'QC', completed: 'Completed', shipped: 'Shipped',
  delivered: 'Delivered', cancelled: 'Cancelled',
};

/**
 * The colour a stage is drawn in, where the palette has a word for it.
 *
 * ── WHY MOST STAGES HAVE NO COLOUR ────────────────────────────────────────
 *
 * Ten stages given ten colours is a rainbow, and a rainbow is what a colour
 * scheme looks like when it has stopped meaning anything. Only the stages that
 * are an instance of one of the palette's own sentences get one. Quote,
 * pending, post and QC are the ordinary course of a job — nothing about them is
 * news, and they stay the colour of ordinary text.
 */
export const STAGE_TONE: Partial<Record<Stage, Tone>> = {
  printing: 'hot',        // "something is being made right now"
  on_hold: 'attention',   // "wants a person, and will keep working if it does not get one"
  completed: 'done',      // "finished, paid, sent, agreed"
  shipped: 'done',
  delivered: 'done',
  cancelled: 'late',      // "late, failed, refused"
};

export interface StagePillProps {
  /** Which stage. */
  stage: Stage;
  /** Override the label, e.g. for a shop that calls its own stages something else. */
  label?: string;
}

/**
 * Where a job is, as a pill.
 *
 * A stage with no colour draws in ordinary text on the quiet ground, which is
 * the common case and is meant to be: the pill says where the job is, and the
 * colour is reserved for the few stages that are actually news.
 */
export function StagePill({ stage, label }: StagePillProps) {
  const tone = STAGE_TONE[stage];
  return (
    <span
      className="khayt-stage"
      data-stage={stage}
      style={tone ? { ['--khayt-stage-tone' as string]: `var(${TONE_VAR[tone]})` } : undefined}
    >
      {label ?? STAGE_LABEL[stage]}
    </span>
  );
}
