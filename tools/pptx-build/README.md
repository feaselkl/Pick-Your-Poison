# PowerPoint build

Regenerates `Pick-Your-Poison.pptx` from `index.html` using the PASS Summit 2026
speaker template. Run it whenever the reveal.js deck changes.

## Requirements

- `python-pptx` and `markitdown[pptx]` (a virtualenv is fine — they are not
  installable system-wide under PEP 668)
- LibreOffice (`soffice`) only if the decision flowchart SVG needs re-rasterising
- The template, as `template.pptx` in the working directory

## Steps

```bash
python make_flowchart.py   # SVG -> flowchart.png with a dark backdrop
python extract.py          # index.html -> slides.json
python build.py            # slides.json + template.pptx -> Pick-Your-Poison.pptx
```

Then strip what the deck does not use. This takes it from ~34 MB to ~10 MB:

```bash
python -c "import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall('unpacked')" Pick-Your-Poison.pptx
python prune_layouts.py unpacked/        # drop the 19 unused slide layouts
python <pptx-skill>/scripts/clean.py unpacked/   # then their orphaned media
(cd unpacked && rm -f ../Pick-Your-Poison.pptx && zip -Xqr ../Pick-Your-Poison.pptx .)
```

`prune_layouts.py` must run **before** `clean.py`. The master references every
layout the template shipped, so `clean.py` alone considers them all live and
keeps several megabytes of artwork only they use.

## Mapping

| Reveal section | PowerPoint treatment |
|---|---|
| Title | Template "Title Slide C" |
| Who Am I | Template "Speaker bio" |
| Agenda (x7) | "Title and Content_dark" — dark, for rhythm |
| Demo Time (x3) | "Breaker page" with centred 54pt text |
| The Framework (flowchart) | Dark layout, full-width image |
| Everything else | "Title and Content" |
| — | Template evaluation slide (required by PASS) |
| — | Template "Thank you" slide |

## Notes

- The content title placeholder is resized to span the navy bar (0 -> 1.66in,
  0.65in from the left, 11.90in wide) with the text vertically centred, so one-
  and two-line headings both sit correctly. The dark agenda layout uses the same
  title geometry, so the two match.
- **Set all four of left/top/width/height together.** python-pptx writes an
  `<a:xfrm>` for whichever you set and defaults the rest to zero rather than
  inheriting from the layout. Setting only left and width once pinned every
  title at y=0 with no height; setting only top and height collapsed a body
  placeholder to zero width and made its text vanish.
- The layout fills content titles with a **gradient** (mint `#33FF99` to yellow
  `#FFFF00`), which LibreOffice cannot render — it falls back to near-black on
  the navy band. `build.py` overrides it with a solid `#FF8A33`, the template's
  own `accent2` orange, which is also what the template uses on its breaker
  pages. This is a run-level override on generated slides; the master and
  layouts are untouched.
- Agenda and flowchart slides sit on the dark layout and keep the layout's white
  titles, which already have good contrast.
- The flowchart SVG is designed for a dark background, so `build.py` expects a
  `flowchart.png` rasterised from a copy of the SVG with a `#110449` backdrop
  rectangle added — that is the slide's exact background colour, so it blends.
- Speaker notes carry across from the reveal deck's `<aside class="notes">`.
