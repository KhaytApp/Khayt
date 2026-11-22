# The companion's typefaces

The website's three faces (khaytapp.com, the published Figma library), so the
app, the Mac and the site read as one product:

- **Archivo** (display: large titles, big numbers) — Copyright 2020 The Archivo
  Project Authors (https://github.com/Omnibus-Type/Archivo). `OFL-archivo.txt`.
- **Hanken Grotesk** (text) — Copyright 2021 The Hanken Grotesk Project Authors
  (https://github.com/marcologous/hanken-grotesk). `OFL-hanken-grotesk.txt`.
- **JetBrains Mono** (data, eyebrows) — Copyright 2020 The JetBrains Mono
  Project Authors (https://github.com/JetBrains/JetBrainsMono).
  `OFL-jetbrains-mono.txt`.

All three are under the SIL Open Font License, Version 1.1. The full text of
each licence ships in the app bundle beside the fonts, as the licence's
condition 2 requires of any copy that is redistributed.

The TrueType files are static instances (one weight each) cut from the variable
fonts in google/fonts with fontTools' instancer, unmodified in design: Archivo
Bold and ExtraBold at width 100; Hanken Grotesk Regular, Medium, SemiBold and
Bold; JetBrains Mono Regular and Medium. The names were set so each file's
PostScript name is `<Family>-<Style>`, which is what `KhaytType` asks for.
