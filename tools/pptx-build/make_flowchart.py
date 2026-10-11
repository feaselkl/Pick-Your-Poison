"""Rasterise the decision flowchart for the PowerPoint deck.

The SVG is drawn for reveal.js's dark theme -- light grey edge labels, amber
headings -- so it needs a dark backdrop. #110449 is the exact background of the
template's dark layout, so the image blends instead of sitting on a white card.

    python make_flowchart.py            # -> flowchart.png
"""
import os, subprocess, sys, shutil

SVG  = '../../presentation/assets/image/edition-decision-flowchart.svg'
NAVY = '#110449'

src_path = sys.argv[1] if len(sys.argv) > 1 else SVG
src = open(src_path).read()
if 'data-pptx-bg' not in src:
    i = src.index('>') + 1
    src = src[:i] + f'\n\t<rect data-pptx-bg="1" x="0" y="0" width="1400" height="880" fill="{NAVY}"/>' + src[i:]
open('flowchart-dark.svg', 'w').write(src)

soffice = shutil.which('soffice') or shutil.which('libreoffice')
if not soffice:
    raise SystemExit("LibreOffice not found; needed to rasterise the SVG")
subprocess.run([soffice, '--headless', '--convert-to', 'png', '--outdir', '.', 'flowchart-dark.svg'],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

from PIL import Image
im = Image.open('flowchart-dark.png').convert('RGB')
im.resize((im.width * 2, im.height * 2), Image.LANCZOS).save('flowchart.png')
print(f"flowchart.png written ({im.width*2}x{im.height*2}), backdrop {NAVY}")
