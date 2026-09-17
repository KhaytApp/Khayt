/**
 * Khayt's design language, for the web.
 *
 * The colours, the type scale and the card geometry are the Mac app's own,
 * read out of `Palette.swift`, `TypeScale.swift` and `Surface.swift` by
 * `.design-sync/extract-tokens.mjs`. Nothing here invents a value.
 */
export { Card, type CardProps } from './components/Card';
export { Chip, type ChipProps } from './components/Chip';
export { BigFigure, type BigFigureProps } from './components/BigFigure';
export { CapsLabel, type CapsLabelProps } from './components/CapsLabel';
export { StagePill, type StagePillProps, STAGES, STAGE_LABEL, STAGE_TONE, type Stage } from './components/Stage';
export { BoardColumn, type BoardColumnProps, JobCard, type JobCardProps } from './components/Board';
export { Theme, type ThemeProps, Stat, type StatProps, SidebarRow, type SidebarRowProps, EmptyState, type EmptyStateProps } from './components/Shell';
export { TONES, TONE_VAR, type Tone } from './tone';
