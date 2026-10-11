"""Parse the reveal.js deck into structured slide data."""
import re, json, html
from html.parser import HTMLParser
WS = re.compile(r'\s+')

SRC = '/home/kevin/SourceCode/Pick-Your-Poison/index.html'

class Deck(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.slides=[]; self.cur=None
        self.stack=[]           # open tag names
        self.buf=[]             # runs for current text block
        self.fmt={'b':0,'i':0,'code':0}
        self.in_notes=False; self.notes=[]
        self.row=None; self.cell=None

    # ---- helpers
    def flush(self, kind):
        runs=[r for r in self.buf if r['t'].strip() or r['t']==' ']
        self.buf=[]
        if not runs: return
        txt=''.join(r['t'] for r in runs).strip()
        if not txt: return
        while runs and not runs[-1]['t'].strip(): runs.pop()
        if runs: runs[-1]=dict(runs[-1], t=runs[-1]['t'].rstrip())
        if runs: runs[0]=dict(runs[0], t=runs[0]['t'].lstrip())
        # collapse runs of spaces that span run boundaries (e.g. around <br>)
        norm=[]
        for r in runs:
            t=WS.sub(' ', r['t'])
            if norm and norm[-1]['t'].endswith(' ') and t.startswith(' '):
                t=t.lstrip()
            if not t: continue
            if norm and (norm[-1]['b'],norm[-1]['i'],norm[-1]['c'])==(r['b'],r['i'],r['c']):
                norm[-1]=dict(norm[-1], t=norm[-1]['t']+t)
            else:
                norm.append(dict(r, t=t))
        runs=norm
        if not runs: return
        self.cur['blocks'].append({'kind':kind,'runs':runs})

    def handle_starttag(self, tag, attrs):
        a=dict(attrs)
        if tag=='section':
            self.cur={'bg':a.get('data-background-image'),'blocks':[],'notes':'','title':None,'subtitle':None,
                      'fragments':[], 'img':None}
            self.slides.append(self.cur); return
        if self.cur is None: return
        if tag=='aside' and 'notes' in (a.get('class') or ''):
            self.in_notes=True; self.notes=[]; return
        if tag=='br':
            if self.buf: self.buf.append({'t':' ','b':False,'i':False,'c':False})
            return
        if tag in ('strong','b'): self.fmt['b']+=1
        elif tag in ('em','i'):   self.fmt['i']+=1
        elif tag=='code':         self.fmt['code']+=1
        elif tag=='img':
            self.cur['img']=a.get('src')
        elif tag=='tr':  self.row=[]
        elif tag in ('td','th'): self.cell=[]; self.buf=[]
        elif tag in ('h2','h3','p','li'):
            self.buf=[]
            self.pending_frag = 'fragment' in (a.get('class') or '')
        self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag=='section':
            self.cur=None
        if self.cur is None:
            if self.stack and self.stack[-1]==tag: self.stack.pop()
            return
        if tag=='aside' and self.in_notes:
            self.cur['notes']=' '.join(''.join(self.notes).split()); self.in_notes=False
        elif tag in ('strong','b'): self.fmt['b']=max(0,self.fmt['b']-1)
        elif tag in ('em','i'):     self.fmt['i']=max(0,self.fmt['i']-1)
        elif tag=='code':           self.fmt['code']=max(0,self.fmt['code']-1)
        elif tag=='h2':
            self.cur['title']=''.join(r['t'] for r in self.buf).strip(); self.buf=[]
        elif tag=='h3':
            t=''.join(r['t'] for r in self.buf).strip(); self.buf=[]
            if self.cur['title'] is None: self.cur['title']=t
            else: self.cur['subtitle']=t
        elif tag=='p':  self.flush('p')
        elif tag=='li':
            parent = 'ol' if 'ol' in self.stack else 'ul'
            self.flush('num' if parent=='ol' else 'bullet')
        elif tag in ('td','th'):
            self.cell=''.join(r['t'] for r in self.buf).strip(); self.buf=[]
            if self.row is not None: self.row.append(self.cell)
        elif tag=='tr':
            if self.row: self.cur['blocks'].append({'kind':'row','cells':self.row})
            self.row=None
        if self.stack and self.stack[-1]==tag: self.stack.pop()

    def handle_data(self, data):
        if self.in_notes: self.notes.append(data); return
        if self.cur is None: return
        if not self.stack: return
        data = WS.sub(' ', data)          # HTML source indentation is not content
        if not data: return
        if not self.buf and data == ' ': return          # no leading space on a block
        self.buf.append({'t':data,'b':self.fmt['b']>0,'i':self.fmt['i']>0,'c':self.fmt['code']>0})

d=Deck(); d.feed(open(SRC).read())
# merge consecutive row blocks into table blocks
for s in d.slides:
    out=[]; tbl=None
    for b in s['blocks']:
        if b['kind']=='row':
            tbl = tbl or {'kind':'table','rows':[]}
            tbl['rows'].append(b['cells'])
        else:
            if tbl: out.append(tbl); tbl=None
            out.append(b)
    if tbl: out.append(tbl)
    s['blocks']=out
json.dump(d.slides, open('slides.json','w'), indent=1)

print(f"{len(d.slides)} slides\n")
for i,s in enumerate(d.slides,1):
    kinds={}
    for b in s['blocks']: kinds[b['kind']]=kinds.get(b['kind'],0)+1
    bg=(s['bg'] or '').split('/')[-1].replace('.jpg','')
    extra=[]
    if s['img']: extra.append('IMG')
    if s['notes']: extra.append('notes')
    print(f"{i:>2} {str(s['title'])[:40]:<42} bg={bg:<16} {str(kinds):<40} {' '.join(extra)}")
