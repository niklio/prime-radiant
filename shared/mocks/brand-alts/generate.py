#!/usr/bin/env python3
"""Five brand alternates for Prime Radiant — each sheet: name, palette, type sample, canvas preview."""
import pathlib, math, random

OUT = pathlib.Path("/mnt/user-data/outputs/radiant-brand-alts"); OUT.mkdir(exist_ok=True)
W, H = 390, 844

BRANDS = [
 dict(key="A-coldfusion", name="COLD FUSION", tag="oscilloscope precision · Vision-Pro glass",
      void="#0A0E13", fil="#39D6C8", hot="#D9FFFB", dim="#274B4F", text="#E9F4F3", accent="#39D6C8",
      serif=False, mood="One hue. Hierarchy is luminance, not color. Payoff classes render as brightness + core shape (dot / ring / cross). Feels like a scientific instrument someone paid too much for.",
      type_display="Inter / Neue Haas (tight, -2% tracking)", type_data="SF Mono light"),
 dict(key="B-boneink", name="BONE & INK", tag="the future institute's lab notebook",
      void="#F4F2ED", fil="#17171A", hot="#17171A", dim="#B9B6AE", text="#17171A", accent="#2B3BF2",
      serif=True, mood="Light mode as the radical move: porcelain field, ink filaments, Klein-blue reserved for the realized path alone. Rams-plain chrome; the tree reads as drafted mathematics, not sci-fi.",
      type_display="Canela / Times (light serif)", type_data="IBM Plex Mono"),
 dict(key="C-signalred", name="SIGNAL", tag="mission control · Teenage Engineering",
      void="#060608", fil="#8B9096", hot="#E8EAEE", dim="#2A2C30", text="#D9DCE1", accent="#FF4433",
      serif=False, mood="Graphite silver tree on true black; the single red exists only for reality — realized branches and the mark ring. Everything else grayscale. Severity as luxury.",
      type_display="Helvetica Now / SF (medium)", type_data="SF Mono"),
 dict(key="D-deepfield", name="DEEP FIELD", tag="JWST ultraviolet · spectral depth",
      void="#070312", fil="#6E5BFF", hot="#EFE9FF", dim="#2A2354", text="#E8E4F6", accent="#B48CFF",
      serif=True, mood="Indigo→violet spectral ramp encodes depth itself: near branches warm violet, far branches cool indigo, cores white-hot. The one alt that keeps 'cosmic' and earns it through restraint.",
      type_display="Light serif italic titles", type_data="Space Mono"),
 dict(key="E-phosphor", name="PHOSPHOR", tag="Nostromo instrument, rebuilt premium",
      void="#04070A", fil="#57E68F", hot="#D8FFE9", dim="#123122", text="#CDEFDD", accent="#57E68F",
      serif=False, mood="Single phosphor-green luminance ramp, scanline-free, no nostalgia kitsch: modern glass, CRT soul. All-mono type, one family, two weights. The tree hums.",
      type_display="Berkeley Mono (semibold)", type_data="Berkeley Mono (light)"),
]

def sheet(b):
    MONO="Menlo, 'SF Mono', monospace"
    SERIF="Georgia, serif" if b["serif"] else "Helvetica, Arial, sans-serif"
    s=f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<defs><radialGradient id="g"><stop offset="0%" stop-color="{b['hot']}" stop-opacity=".95"/><stop offset="35%" stop-color="{b['fil']}" stop-opacity=".45"/><stop offset="100%" stop-color="{b['fil']}" stop-opacity="0"/></radialGradient>
<radialGradient id="ga"><stop offset="0%" stop-color="{b['hot']}" stop-opacity=".95"/><stop offset="35%" stop-color="{b['accent']}" stop-opacity=".5"/><stop offset="100%" stop-color="{b['accent']}" stop-opacity="0"/></radialGradient></defs>
<rect width="{W}" height="{H}" fill="{b['void']}"/>
'''
    def T(x,y,t,size=10,fill=None,font=MONO,ls=1.2,anchor="start",op=1):
        return f'<text x="{x}" y="{y}" font-family="{font}" font-size="{size}" fill="{fill or b["text"]}" letter-spacing="{ls}" text-anchor="{anchor}" opacity="{op}">{t}</text>\n'
    # header
    s+=T(26,54,b["name"],21,b["text"],SERIF,4)
    s+=T(26,76,b["tag"],9,b["accent"],MONO,1.6)
    # palette chips
    chips=[("VOID",b["void"]),("FILAMENT",b["fil"]),("HOT",b["hot"]),("DIM",b["dim"]),("ACCENT",b["accent"])]
    for i,(lab,c) in enumerate(chips):
        x=26+i*70
        stroke = b["text"] if c.lower()==b["void"].lower() else "none"
        s+=f'<rect x="{x}" y="96" rx="6" width="56" height="30" fill="{c}" stroke="{stroke}" stroke-opacity=".25"/>'
        s+=T(x,140,lab,6.5,b["text"],MONO,1,op=.6)
        s+=T(x,151,c,6.5,b["text"],MONO,.4,op=.4)
    # type sample
    s+=T(26,186,"She accepts the terms",17,b["text"],SERIF,.3)
    s+=T(26,205,f'{b["type_display"]}  ·  {b["type_data"]}',7.5,b["text"],MONO,.8,op=.5)
    s+=f'<line x1="26" y1="222" x2="364" y2="222" stroke="{b["text"]}" stroke-opacity=".12" stroke-width=".6"/>'
    # canvas preview — same tree geometry across all alts for fair comparison
    random.seed(4)
    oy=250; ROOT=(195,oy+400)
    L1=[(88,oy+300),(160,oy+280),(250,oy+288),(316,oy+312)]
    L2=[[(52,oy+192),(120,oy+178)],[(150,oy+160),(198,oy+172)],[(246,oy+170),(292,oy+186)],[(330,oy+210)]]
    realized={0}  # branch A realized -> accent
    def fil(p1,p2,w,op,color):
        mx,my=(p1[0]+p2[0])/2,(p1[1]+p2[1])/2
        nx,ny=-(p2[1]-p1[1]),(p2[0]-p1[0]); L=math.hypot(nx,ny) or 1
        return f'<path d="M{p1[0]} {p1[1]} Q{mx+nx/L*14:.0f} {my+ny/L*14:.0f} {p2[0]} {p2[1]}" stroke="{color}" stroke-width="{w}" fill="none" opacity="{op}" stroke-linecap="round"/>\n'
    def node(x,y,r,grad="g",core=None,op=1.0):
        return (f'<circle cx="{x}" cy="{y}" r="{r*3}" fill="url(#{grad})" opacity="{op:.2f}"/>'
                f'<circle cx="{x}" cy="{y}" r="{r}" fill="{core or b["fil"]}" opacity="{min(1,op+.1):.2f}"/>\n')
    for i,(x,y) in enumerate(L1):
        on = i in realized
        col = b["accent"] if on else b["fil"]
        s+=fil(ROOT,(x,y),2.4 if on else 1.3,.95 if on else .4,col)
        for (cx,cy) in L2[i]:
            childon = on and (cx,cy)==L2[i][0]
            s+=fil((x,y),(cx,cy),2.0 if childon else 1.0,.9 if childon else .35,b["accent"] if childon else b["fil"])
            s+=node(cx,cy,3,"ga" if childon else "g",b["accent"] if childon else None,1 if childon else .7)
        s+=node(x,y,4.4,"ga" if on else "g",b["accent"] if on else None,1 if on else .8)
    s+=node(*ROOT,6)
    # footer sample in-brand
    fy=oy+452
    s+=T(26,fy,"DECISION",7.5,b["accent"],MONO,3)
    s+=T(26,fy+22,"She accepts the terms",18,b["text"],SERIF,.3)
    s+=T(26,fy+42,"Confirm scope in writing before the kickoff call.",9.5,b["text"],MONO,.3,op=.8)
    s+=T(26,fy+64,"EV ≈ +$12k",12,b["accent"],MONO,1)
    s+=T(118,fy+64,"▸ DISTRIBUTION",8,b["text"],MONO,1.6,op=.45)
    s+=T(26,fy+88,b["mood"],7.6,b["text"],MONO,.4,op=.55)
    # wrap mood text manually
    words=b["mood"].split(); lines=[]; cur=""
    for w_ in words:
        if len(cur)+len(w_)+1<=62: cur=(cur+" "+w_).strip()
        else: lines.append(cur); cur=w_
    lines.append(cur)
    s=s[:s.rindex("<text")]  # drop the unwrapped mood line
    for j,ln in enumerate(lines[:4]):
        s+=T(26,fy+88+j*12,ln,7.6,b["text"],MONO,.4,op=.55)
    return s+"</svg>"

for b in BRANDS:
    (OUT/f"{b['key']}.svg").write_text(sheet(b))
print("wrote", len(BRANDS), "brand alts")
