# The model library

Every model you print, with its picture, what it is made of, and what it costs
to run.

## Bringing models in

Three ways in, all the same underneath:

- The **Import models** button on the library.
- Dragging files or whole folders onto the library.
- **Book → Add model…**, or ⇧⌘I.

Folders are walked, so you can point Khayt at a download and let it find the
models inside. Anything that is not a model is passed over in silence.

## Folders become groups

**The folder a model came from becomes the group it is filed under.** A download
of seven models in seven folders arrives as seven groups, not as a flat pile.

Packaging folders are seen through. A model at

`Saudi Kings/King Abdulaziz/STL/presupported/crown.stl`

is filed under **King Abdulaziz** — not under *presupported*, *STL* or *files*,
because those describe the file rather than name the thing.

A file you pick on its own is not grouped. One file is not a set.

## Duplicates

A model you already have is recognised by the contents of the file, not its
name, and is refused rather than added twice. Renaming a file does not fool it;
re-exporting the same model from a slicer usually does change the bytes, and
then it is genuinely a new file.

## Looking at models

The library is a grid because a print shop recognises a model by looking at it.
Space opens Quick Look, as it does in the Finder. The arrow keys walk the grid,
and in an Arabic window they walk it the right way round.
