"""Drop slide layouts no deck slide uses, plus their now-orphaned parts.

The master references every layout the template shipped with, so clean.py keeps
them all -- along with several megabytes of brand artwork only they use. Run
this on an unpacked package BEFORE clean.py.
"""
import os, re, sys
from lxml import etree

RELS = 'http://schemas.openxmlformats.org/package/2006/relationships'
PML  = 'http://schemas.openxmlformats.org/presentationml/2006/main'
ODR  = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
CT   = 'http://schemas.openxmlformats.org/package/2006/content-types'

root = sys.argv[1].rstrip('/')

def load(p): return etree.parse(os.path.join(root, p))
def save(t, p): t.write(os.path.join(root, p), xml_declaration=True, encoding='UTF-8', standalone=True)

# --- which layouts do the slides still in the presentation actually use?
pres = load('ppt/presentation.xml')
prels = load('ppt/_rels/presentation.xml.rels')
rid2t = {r.get('Id'): r.get('Target') for r in prels.getroot()}
live_slides = [rid2t[e.get(f'{{{ODR}}}id')].split('/')[-1]
               for e in pres.getroot().find(f'{{{PML}}}sldIdLst')]

used = set()
for s in live_slides:
    rp = f'ppt/slides/_rels/{s}.rels'
    if not os.path.exists(os.path.join(root, rp)): continue
    for r in load(rp).getroot():
        t = r.get('Target') or ''
        if 'slideLayout' in t: used.add(t.split('/')[-1])

# --- prune the master's list and relationships
mrels_p = 'ppt/slideMasters/_rels/slideMaster1.xml.rels'
mrels = load(mrels_p); mroot = mrels.getroot()
lay_rids = {r.get('Id'): (r.get('Target') or '').split('/')[-1]
            for r in mroot if 'slideLayout' in (r.get('Target') or '')}
drop_rids = {rid for rid, fn in lay_rids.items() if fn not in used}
drop_files = {lay_rids[r] for r in drop_rids}

master = load('ppt/slideMasters/slideMaster1.xml')
lst = master.getroot().find(f'{{{PML}}}sldLayoutIdLst')
for e in list(lst):
    if e.get(f'{{{ODR}}}id') in drop_rids: lst.remove(e)
save(master, 'ppt/slideMasters/slideMaster1.xml')

for r in list(mroot):
    if r.get('Id') in drop_rids: mroot.remove(r)
save(mrels, mrels_p)

# --- delete the layout parts and their rels
removed = []
for fn in sorted(drop_files):
    for p in (f'ppt/slideLayouts/{fn}', f'ppt/slideLayouts/_rels/{fn}.rels'):
        ap = os.path.join(root, p)
        if os.path.exists(ap): os.remove(ap); removed.append(p)

# --- drop their content-type overrides
ctp = '[Content_Types].xml'
ct = load(ctp); croot = ct.getroot()
gone = {f'/ppt/slideLayouts/{fn}' for fn in drop_files}
for o in list(croot):
    if o.get('PartName') in gone: croot.remove(o)
save(ct, ctp)

print(f"layouts kept   ({len(used)}): {', '.join(sorted(used, key=lambda s:int(re.search(r'(\d+)',s).group(1))))}")
print(f"layouts pruned ({len(drop_files)}): {', '.join(sorted(drop_files, key=lambda s:int(re.search(r'(\d+)',s).group(1))))}")
