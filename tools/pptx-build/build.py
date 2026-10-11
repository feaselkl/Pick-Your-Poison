"""Build the PASS Summit PowerPoint deck from the reveal.js slides."""
import json, copy, re, os
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR

SLIDES = json.load(open('slides.json'))
TPL    = 'template.pptx'
OUT    = 'Pick-Your-Poison.pptx'

NAVY   = RGBColor(0x1B, 0x14, 0x464 % 256)
NAVY   = RGBColor(0x1B, 0x14, 0x46)
WHITE  = RGBColor(0xFF, 0xFF, 0xFF)
INK    = RGBColor(0x20, 0x20, 0x30)
GREY   = RGBColor(0xE9, 0xE9, 0xEF)
ORANGE = RGBColor(0xFF, 0x8A, 0x33)      # the template's own accent2
BAR_H  = 1.66                            # navy header bar height, from slideLayout9

prs = Presentation(TPL)
L = {l.name: l for l in prs.slide_masters[0].slide_layouts}
LAY_CONTENT = L['Title and Content']
LAY_DARK    = L['Title and Content_dark']
LAY_BREAK   = L['Breaker page']

# ---------------------------------------------------------------- helpers
def ph_by_idx(slide, idx):
    for sh in slide.placeholders:
        if sh.placeholder_format.idx == idx: return sh
    return None

def drop(shape):
    shape._element.getparent().remove(shape._element)

def set_line(shape, text):
    """Replace a single-line placeholder, keeping its run formatting."""
    tf = shape.text_frame
    p = tf.paragraphs[0]
    if not p.runs: p.add_run()
    p.runs[0].text = text
    for r in p.runs[1:]: r._r.getparent().remove(r._r)
    for extra in tf.paragraphs[1:]: extra._p.getparent().remove(extra._p)

def add_runs(para, runs, size=None, color=None):
    for r in runs:
        t = r['t']
        if not t: continue
        run = para.add_run(); run.text = t
        f = run.font
        if r.get('b'): f.bold = True
        if r.get('i'): f.italic = True
        if r.get('c'): f.name = 'Courier New'
        if size:  f.size = size
        if color: f.color.rgb = color

def body_size(blocks):
    n = sum(len(''.join(x['t'] for x in b.get('runs', []))) for b in blocks)
    bullets = sum(1 for b in blocks if b['kind'] in ('bullet','num'))
    if n > 900 or bullets > 6: return Pt(14)
    if n > 620: return Pt(16)
    if n > 380: return Pt(18)
    return Pt(20)

def fill_body(tf, blocks, color=None):
    tf.word_wrap = True
    size = body_size(blocks)
    first = True
    for b in blocks:
        if b['kind'] == 'table': continue
        p = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        p.level = 0
        if b['kind'] in ('bullet','num'):
            pass                      # bullet formatting inherits from layout
        else:
            # plain paragraph: suppress the inherited bullet
            pPr = p._p.get_or_add_pPr()
            from pptx.oxml.ns import qn
            for tag in ('a:buChar','a:buAutoNum'):
                for e in pPr.findall(qn(tag)): pPr.remove(e)
            bn = pPr.makeelement(qn('a:buNone'), {}); pPr.append(bn)
        add_runs(p, b['runs'], size=size, color=color)
        p.space_after = Pt(8)
    return size

def add_table(slide, rows, top, height=None):
    cols = max(len(r) for r in rows)
    rows = [r + ['']*(cols-len(r)) for r in rows]
    left, width = Inches(0.65), Inches(11.9)
    height = height or Inches(min(0.42*len(rows)+0.1, 4.6))
    gf = slide.shapes.add_table(len(rows), cols, left, top, width, height)
    tbl = gf.table
    tbl.first_row = True
    fs = Pt(14) if len(rows) <= 7 else Pt(12)
    for ri, row in enumerate(rows):
        for ci, val in enumerate(row):
            cell = tbl.cell(ri, ci)
            cell.margin_left = Inches(0.10); cell.margin_right = Inches(0.08)
            cell.margin_top  = Inches(0.03); cell.margin_bottom = Inches(0.03)
            cell.vertical_anchor = MSO_ANCHOR.MIDDLE
            tf = cell.text_frame; tf.word_wrap = True
            p = tf.paragraphs[0]; r = p.add_run(); r.text = val
            r.font.size = fs
            r.font.bold = (ri == 0)
            r.font.color.rgb = WHITE if ri == 0 else INK
            cell.fill.solid()
            cell.fill.fore_color.rgb = NAVY if ri == 0 else (WHITE if ri % 2 else GREY)
    return gf

def set_notes(slide, text):
    if text:
        slide.notes_slide.notes_text_frame.text = text

# ---------------------------------------------------------------- classify
AGENDA = {5,13,18,23,28,33,38}
DEMO   = {12,27,32}
IMAGE  = {40}

built = []   # (kind, slide_object)

for i, s in enumerate(SLIDES, 1):
    if i in (1, 2):       # handled by the template's own title / bio slides
        continue
    blocks = s['blocks']
    tables = [b for b in blocks if b['kind'] == 'table']

    if i in DEMO:
        sl = prs.slides.add_slide(LAY_BREAK)
        tb = sl.shapes.add_textbox(Inches(0.9), Inches(2.9), Inches(11.5), Inches(1.7))
        tf = tb.text_frame; tf.word_wrap = True
        p = tf.paragraphs[0]; p.alignment = PP_ALIGN.CENTER
        r = p.add_run(); r.text = s['title']
        r.font.size = Pt(54); r.font.bold = True; r.font.color.rgb = WHITE
        set_notes(sl, s['notes']); built.append(('demo', sl)); continue

    lay = LAY_DARK if (i in AGENDA or i in IMAGE) else LAY_CONTENT
    sl = prs.slides.add_slide(lay)
    title = ph_by_idx(sl, 0) or sl.shapes.title
    if title is not None:
        set_line(title, s['title'])
        # Set ALL FOUR of left/top/width/height together. Setting only some of
        # them makes python-pptx write an <a:xfrm> whose unset values default to
        # zero rather than inheriting from the layout -- which pins the box at
        # y=0 with no height and throws the text to the very top of the slide.
        #
        # The navy bar runs 0 -> 1.66in, so span it exactly and centre the text
        # in it. That holds whether the heading takes one line or two, and the
        # dark agenda layout uses the same title geometry, so both match.
        title.left,  title.top    = Inches(0.65), Inches(0.0)
        title.width, title.height = Inches(11.90), Inches(BAR_H)
        title.text_frame.vertical_anchor = MSO_ANCHOR.MIDDLE
        if i not in AGENDA and i not in IMAGE:
            # The layout fills titles with a mint-to-yellow gradient. Replace it
            # with a solid accent2 orange on the light content slides. This is a
            # run-level override on our own slides -- the master is untouched.
            for p in title.text_frame.paragraphs:
                for r in p.runs:
                    r.font.color.rgb = ORANGE
    body = ph_by_idx(sl, 10)

    if i in IMAGE:
        if body is not None: drop(body)
        png = 'flowchart.png'
        if not os.path.exists(png):
            # Silently shipping a blank slide is worse than stopping.
            raise SystemExit(
                "MISSING flowchart.png -- rasterise it first:\n"
                "  1. copy presentation/assets/image/edition-decision-flowchart.svg here\n"
                "  2. insert <rect x='0' y='0' width='1400' height='880' fill='#110449'/> after <svg ...>\n"
                "  3. soffice --headless --convert-to png that copy, then upscale 2x to flowchart.png")
        if True:
            from PIL import Image
            w, h = Image.open(png).size
            maxw, maxh = Inches(12.4), Inches(5.85)
            scale = min(maxw / w, maxh / h)
            pw, ph_ = int(w*scale), int(h*scale)
            sl.shapes.add_picture(png, int((prs.slide_width - pw)/2), Inches(1.25), pw, ph_)
    elif tables:
        non = [b for b in blocks if b['kind'] != 'table']
        top = Inches(2.0)
        if non and body is not None:
            fill_body(body.text_frame, non)
            body.left, body.width = Inches(0.65), Inches(11.50)
            body.top,  body.height = Inches(2.0), Inches(1.15)
            top = Inches(3.25)
        elif body is not None:
            drop(body)
        add_table(sl, tables[0]['rows'], top)
    else:
        if body is not None:
            fill_body(body.text_frame, blocks, color=WHITE if i in AGENDA else None)
        
    set_notes(sl, s['notes'])
    built.append(('agenda' if i in AGENDA else 'content', sl))


# ---------------------------------------------------------------- template slides
TITLE_S, BIO_S, EVAL_S, THANKS_S = prs.slides[18], prs.slides[21], prs.slides[22], prs.slides[23]

# --- title
set_line(ph_by_idx(TITLE_S, 0), "Pick Your Poison: Choosing the Right Edition of SQL Server")
set_line(ph_by_idx(TITLE_S, 11), "Kevin Feasel")
set_line(ph_by_idx(TITLE_S, 14), "Catallaxy Services")
for idx in (12, 13):                      # pronouns, job title -- not mine to invent
    sh = ph_by_idx(TITLE_S, idx)
    if sh is not None: drop(sh)

# --- speaker bio
set_line(ph_by_idx(BIO_S, 0), "Kevin")
set_line(ph_by_idx(BIO_S, 20), "Feasel")
set_line(ph_by_idx(BIO_S, 17), "Catallaxy Services")
bio = ph_by_idx(BIO_S, 18)
bio.text_frame.word_wrap = True
p0 = bio.text_frame.paragraphs[0]
if not p0.runs: p0.add_run()
p0.runs[0].text = ("I run Catallaxy Services and curate Curated SQL, and I wrote "
                   "Finding Ghosts in Your Data.")
for r in p0.runs[1:]: r._r.getparent().remove(r._r)
for extra in bio.text_frame.paragraphs[1:]: extra._p.getparent().remove(extra._p)
p1 = bio.text_frame.add_paragraph()
from pptx.oxml.ns import qn as _qn
_pPr = p1._p.get_or_add_pPr(); _pPr.append(_pPr.makeelement(_qn('a:buNone'), {}))
r = p1.add_run(); r.text = "Slides, scripts and handouts for this session: https://csmore.info/on/editions"
r.font.size = p0.runs[0].font.size
for idx in (19, 13):                      # pronouns, LinkedIn handle -- not mine to invent
    sh = ph_by_idx(BIO_S, idx)
    if sh is not None: drop(sh)
sh = ph_by_idx(BIO_S, 1)
if sh is not None: drop(sh)               # job title
for sp in list(BIO_S.shapes):             # the now-orphaned LinkedIn icon
    if not sp.is_placeholder and sp.left is not None and Emu(sp.left).inches < 1.3 and Emu(sp.top).inches > 5.5:
        drop(sp)
pic = ph_by_idx(BIO_S, 15)
if pic is not None:
    try:
        from PIL import Image
        import io
        im = Image.open('/home/kevin/SourceCode/WebsiteAssets/HeadShot.jpg').convert('RGB')
        side = min(im.size)                      # centre-crop square to match the frame
        l = (im.width - side)//2; t = (im.height - side)//2
        im = im.crop((l, t, l+side, t+side)).resize((900, 900), Image.LANCZOS)
        buf = io.BytesIO(); im.save(buf, 'JPEG', quality=92)
        rId = pic._element.blipFill.blip.rEmbed
        part = pic.part.related_part(rId)
        part._blob = buf.getvalue()
        print("  headshot swapped in")
    except Exception as e:
        print("  headshot FAILED:", e)

if BIO_S.has_notes_slide:                 # template residue ("Peter")
    BIO_S.notes_slide.notes_text_frame.text = ""

# --- thank you
set_line(ph_by_idx(THANKS_S, 15), "Slides, scripts and handouts: https://csmore.info/on/editions")
set_line(ph_by_idx(THANKS_S, 0), "Kevin Feasel")
set_line(ph_by_idx(THANKS_S, 16), "@feaselkl")
set_line(ph_by_idx(THANKS_S, 17), "feasel@catallaxyservices.com")
set_line(ph_by_idx(THANKS_S, 18), "https://csmore.info")

# ---------------------------------------------------------------- order & prune
from pptx.oxml.ns import qn
sldIdLst = prs.slides._sldIdLst
ids = list(sldIdLst)
N_TPL = 24                                   # the template's own slides come first
gen   = ids[N_TPL:]                          # generated slides, in `built` order
assert len(gen) == len(built), f"{len(gen)} generated ids vs {len(built)} built"
keep  = [ids[18], ids[21]] + gen + [ids[22], ids[23]]
for e in ids: sldIdLst.remove(e)
for e in keep: sldIdLst.append(e)

print(f"generated {len(built)} content slides; final deck = {len(keep)} slides")
prs.save(OUT)
print("saved", OUT)
