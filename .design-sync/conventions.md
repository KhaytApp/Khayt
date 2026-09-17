# Building with Khayt

Khayt is a 3D print shop's book: jobs, machines, spools, customers, money. This
is the Mac app's design language for the web. Every colour, type step and the
card's geometry are read out of the app's own Swift source, so a design built
here matches the product.

## Wrap the page in `<Theme>`

Every component reads its colour, radius and type from custom properties, and
`<Theme>` is what puts them in scope. Without it a component still renders — it
renders in whatever the host page happens to define, which is how a design ends
up looking like something else.

```jsx
<Theme>                      {/* or <Theme mode="dark"> to pin it */}
  <Card rail="hot">
    <CapsLabel tone="hot">Printing</CapsLabel>
    <Stat label="On the floor" value="3" tone="hot" note="2h left on the U1" />
  </Card>
</Theme>
```

Omitting `mode` follows the viewer's own setting: the token file redefines every
colour under `prefers-color-scheme: dark`. Geometry and type do not change
between the two — only colour does.

## Colour is semantic. There are seven, and each is a sentence.

Never pick one because it looks right. Pick the one whose sentence is true:

| Tone | Means |
|---|---|
| `hot` | something is being made right now |
| `done` | finished, paid, sent, agreed |
| `attention` | wants a person, and will keep working if it does not get one |
| `late` | late, failed, refused |
| `note` | a remark, an aside, something the shop wrote down |
| `marked` | flagged by the shop itself |
| `brand` | the one action a screen is for |

**Most things have no tone at all**, and that is deliberate. The ordinary course
of a job is not news. Ten stages given ten colours is a rainbow, and a rainbow
is what a colour scheme looks like when it has stopped meaning anything. If
something seems to need a colour it does not have, work out which of those
sentences it is an instance of; if it is none, it stays the colour of ordinary
text.

Tones are accepted by `Card` (as `rail`), `Chip`, `BigFigure`, `CapsLabel` and
`Stat`.

## Styling your own layout

There are no utility classes. Components take props; anything you add around
them uses the tokens directly:

```css
background: var(--khayt-ground);     /* the ground a screen sits on */
background: var(--khayt-surface);    /* a card's own surface */
border: 1px solid var(--khayt-hairline);
border-radius: var(--khayt-radius);
color: var(--khayt-note);            /* quiet text */
```

Colours: `--khayt-brand`, `--khayt-on-brand`, `--khayt-hot`, `--khayt-done`,
`--khayt-attention`, `--khayt-late`, `--khayt-note`, `--khayt-marked`,
`--khayt-surface`, `--khayt-ground`, `--khayt-hairline`.

Card: `--khayt-radius`, `--khayt-card-padding`, `--khayt-rail-width`,
`--khayt-rail-inset`, `--khayt-hairline-width`.

Type: `--khayt-font-brand` (Space Grotesk, for figures, titles and labels),
`--khayt-font-system` (body), with `--khayt-size-display` / `-title` / `-row` /
`-body` / `-label`, matching `--khayt-weight-*` and `--khayt-track-display` /
`-label`.

Read `styles.css` and `tokens/khayt.css` before styling anything — they are
short, and they are the truth.

## Two rules worth keeping

**A card with nothing to say gets no rail.** The rail is worth looking at
because most cards do not have one; put one on everything and it becomes
wallpaper. A railed card always carries a title saying the same thing in words,
so the colour is never the only signal.

**Figures are semibold, not bold.** At 34px bold is shouting, and everything
else on the screen then has to shout back.

## A screen, put together

```jsx
<Theme>
  <div style={{ display: 'flex', gap: 12, background: 'var(--khayt-ground)', padding: 16 }}>
    <nav style={{ width: 180, display: 'grid', gap: 1 }}>
      <SidebarRow label="Board" count={6} selected />
      <SidebarRow label="Library" count={152} />
      <SidebarRow label="Reports" />
    </nav>

    <BoardColumn stage="printing" count={2}>
      <JobCard
        project="Falcon hood" client="Acme Robotics" material="PLA · Ink" priority
        footer={<><StagePill stage="printing" /><Chip tone="hot">2h left</Chip></>}
      />
    </BoardColumn>

    <Card rail="attention" style={{ width: 200 }}>
      <Stat label="Owed" value="1,150" unit="SAR" tone="attention" note="3 unpaid" />
    </Card>
  </div>
</Theme>
```

`SidebarRow` leaves the count blank rather than drawing a zero where a count is
not a thing that screen has — Reports above. `BoardColumn` with nothing in it
says so in words rather than being a blank rectangle.

## Stages

`quote · pending · on_hold · printing · post · qc · completed · shipped ·
delivered · cancelled`, in the order work moves through them. `STAGES`,
`STAGE_LABEL` and `STAGE_TONE` are exported.

`shipped` and `delivered` are not statuses a job carries — both are a date
stamped on a job that stays `completed`, and the app derives the stage from the
pair. They are stages all the same: they are what the board draws.
