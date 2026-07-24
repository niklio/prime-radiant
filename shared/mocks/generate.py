#!/usr/bin/env python3
"""Generate Prime Radiant screen mocks as SVGs (iPhone 390x844 logical)."""
import random, pathlib, math

OUT = pathlib.Path("/mnt/user-data/outputs/radiant-mocks"); OUT.mkdir(exist_ok=True)
W, H = 390, 844
VOID="#050510"; AMBER="#E8A33D"; GOLD="#FFD98A"; BLUE="#6DB8FF"; EMBER="#FF6B5E"; CYAN="#9FE8FF"; PARCH="#F3ECD8"
SERIF="Georgia, 'Times New Roman', serif"; MONO="Menlo, 'SF Mono', 'Courier New', monospace"
random.seed(7)

def head(title):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<title>{title}</title>
<defs>
  <radialGradient id="glow"><stop offset="0%" stop-color="#fff" stop-opacity=".95"/><stop offset="30%" stop-color="{GOLD}" stop-opacity=".5"/><stop offset="100%" stop-color="{GOLD}" stop-opacity="0"/></radialGradient>
  <radialGradient id="glowB"><stop offset="0%" stop-color="#fff" stop-opacity=".9"/><stop offset="30%" stop-color="{BLUE}" stop-opacity=".5"/><stop offset="100%" stop-color="{BLUE}" stop-opacity="0"/></radialGradient>
  <radialGradient id="glowE"><stop offset="0%" stop-color="#fff" stop-opacity=".9"/><stop offset="30%" stop-color="{EMBER}" stop-opacity=".5"/><stop offset="100%" stop-color="{EMBER}" stop-opacity="0"/></radialGradient>
  <linearGradient id="gauge" x1="0" y1="0" x2="1" y2="0"><stop offset="0%" stop-color="{EMBER}"/><stop offset="50%" stop-color="{AMBER}"/><stop offset="100%" stop-color="{BLUE}"/></linearGradient>
</defs>
<rect width="{W}" height="{H}" fill="{VOID}"/>
''' + motes()

def motes(n=42):
    s=""
    for _ in range(n):
        x,y=random.uniform(0,W),random.uniform(0,H); r=random.uniform(.4,1.1)
        s+=f'<circle cx="{x:.0f}" cy="{y:.0f}" r="{r:.1f}" fill="#9FB4E8" opacity="{random.uniform(.06,.22):.2f}"/>\n'
    return s

def node(x,y,r,grad="glow",core=GOLD,op=1.0):
    return (f'<circle cx="{x}" cy="{y}" r="{r*3.2}" fill="url(#{grad})" opacity="{op:.2f}"/>'
            f'<circle cx="{x}" cy="{y}" r="{r}" fill="{core}" opacity="{min(1,op+.1):.2f}"/>\n')

def fil(x1,y1,x2,y2,w=1.4,op=.5,color=AMBER,bow=18):
    mx,my=(x1+x2)/2,(y1+y2)/2
    nx,ny=-(y2-y1),(x2-x1); L=math.hypot(nx,ny) or 1
    qx,qy=mx+nx/L*bow,my+ny/L*bow
    return f'<path d="M{x1} {y1} Q{qx:.0f} {qy:.0f} {x2} {y2}" stroke="{color}" stroke-width="{w}" fill="none" opacity="{op:.2f}" stroke-linecap="round"/>\n'

def T(x,y,s,size=10,fill=PARCH,font=MONO,ls=1.5,anchor="start",weight="normal",op=1):
    return f'<text x="{x}" y="{y}" font-family="{font}" font-size="{size}" fill="{fill}" letter-spacing="{ls}" text-anchor="{anchor}" font-weight="{weight}" opacity="{op}">{s}</text>\n'

# a reusable illustrative tree (positions hand-placed for 390x844 canvas region)
ROOT=(195,668)
L1=[(88,560,"A",.9),(160,540,"B",.55),(250,548,"C",.4),(316,572,"D",.28)]
L2={"A":[(52,452,.7),(120,438,.5)],"B":[(150,420,.5),(198,432,.35)],"C":[(246,430,.4),(292,446,.3)],"D":[(330,470,.25)]}
L3={"A0":[(34,348,.5),(78,336,.4)],"A1":[(126,330,.4)],"B0":[(158,318,.35)],"C0":[(240,326,.3),(272,338,.25)]}
def tree(dim=False, ignite=None, realized=None):
    """ignite: set of keys like {'A','A0','A0x0'} for path; realized draws solid bright"""
    base_op = .16 if dim else .5
    s=""
    def eop(key): return .95 if (ignite and key in ignite) else base_op
    def ecol(key): return GOLD if (ignite and key in ignite) else AMBER
    def ew(key,w): return w*2.1 if (ignite and key in ignite) else w
    for (x,y,k,p) in L1:
        s+=fil(*ROOT,x,y,w=ew(k,1.1+p*1.6),op=eop(k),color=ecol(k))
    for k,(x,y,_,p) in zip("ABCD",L1):
        for i,(cx,cy,cp) in enumerate(L2[k]):
            key=f"{k}{i}"; s+=fil(x,y,cx,cy,w=ew(key,.9+cp*1.4),op=eop(key),color=ecol(key))
    for pk,kids in L3.items():
        px,py=None,None
        pkkey=pk[:1]; idx=int(pk[1])
        px,py,_=L2[pkkey][idx]
        for j,(cx,cy,cp) in enumerate(kids):
            key=f"{pk}x{j}"; s+=fil(px,py,cx,cy,w=ew(key,.8+cp*1.2),op=eop(key),color=ecol(key))
    # nodes
    s+=node(*ROOT,7,op=1 if not dim else .5)
    for (x,y,k,p) in L1:
        on = ignite and k in ignite
        s+=node(x,y,4+p*4,op=(1 if on else (.9 if not dim else .3)))
    for k in "ABCD":
        for i,(cx,cy,cp) in enumerate(L2[k]):
            key=f"{k}{i}"; on=ignite and key in ignite
            s+=node(cx,cy,3+cp*3.4,op=(1 if on else (.8 if not dim else .25)))
    for pk,kids in L3.items():
        for j,(cx,cy,cp) in enumerate(kids):
            key=f"{pk}x{j}"; on=ignite and key in ignite
            g = "glowB" if (j+len(pk))%3==0 else ("glowE" if (j+len(pk))%5==0 else "glow")
            c = BLUE if g=="glowB" else (EMBER if g=="glowE" else GOLD)
            s+=node(cx,cy,2.6+cp*3,grad=g,core=c,op=(1 if on else (.75 if not dim else .22)))
    return s

def input_pill(y=796, placeholder="speak to the radiant…"):
    return (f'<rect x="20" y="{y}" rx="19" width="350" height="38" fill="rgba(10,12,26,.7)" stroke="{AMBER}" stroke-opacity=".28"/>'
            + T(38,y+24,placeholder,11,f"{PARCH}",MONO,1,op=.45)
            + f'<circle cx="{351}" cy="{y+19}" r="11" fill="none" stroke="{CYAN}" stroke-opacity=".5"/>'
            + T(351,y+23,"↑",11,CYAN,MONO,0,"middle",op=.8))

def legend(x=24,y=706):
    rows=[(GOLD,"FAVORABLE EXIT"),(BLUE,"STEADY STATE"),(EMBER,"ADVERSE"),(AMBER,"DECISION")]
    s=""
    for i,(c,l) in enumerate(rows):
        yy=y+i*15
        s+=f'<circle cx="{x}" cy="{yy}" r="3.5" fill="{c}"/><circle cx="{x}" cy="{yy}" r="7" fill="{c}" opacity=".25"/>'
        s+=T(x+14,yy+3,l,8.5,"rgba(220,224,240,.7)",MONO,1.6)
    return s

svgs={}

# ——— 1. Onboarding ———
s=head("Onboarding")
s+=f'<g opacity=".35">{tree(dim=True)}</g>'
s+=T(W/2,300,"PRIME RADIANT",26,PARCH,SERIF,7,"middle")
s+=T(W/2,336,"model the futures. choose the branch.",10.5,CYAN,MONO,1.5,"middle",op=.65)
s+=f'<rect x="55" y="470" rx="26" width="280" height="52" fill="rgba(232,163,61,.08)" stroke="{AMBER}" stroke-opacity=".55"/>'
s+=f'<rect x="55" y="470" rx="26" width="280" height="52" fill="none" stroke="{GOLD}" stroke-opacity=".25" stroke-width="3" filter="blur(0.001px)"/>'
s+=T(W/2,502,"SIGN IN WITH CHATGPT",12,GOLD,MONO,2.5,"middle")
s+=T(W/2,560,"use an API key instead",9.5,"rgba(220,224,240,.45)",MONO,1.2,"middle")
s+='<line x1="150" y1="566" x2="240" y2="566" stroke="rgba(220,224,240,.25)" stroke-width=".6"/>'
svgs["1-onboarding"]=s+"</svg>"

# ——— 2. Scenario list, empty ———
s=head("Scenario list — empty")
s+=T(26,64,"SCENARIOS",9.5,"rgba(232,163,61,.85)",MONO,3)
s+=T(364,66,"+",18,GOLD,MONO,0,"middle")
s+=node(195,420,11)
s+=f'<circle cx="195" cy="420" r="26" fill="none" stroke="{GOLD}" stroke-opacity=".3"/>'
s+=f'<circle cx="195" cy="420" r="40" fill="none" stroke="{GOLD}" stroke-opacity=".12"/>'
s+=T(195,486,"begin a scenario",10,"rgba(220,224,240,.5)",MONO,1.6,"middle")
svgs["2-list-empty"]=s+"</svg>"

# ——— 3. Scenario list, populated ———
s=head("Scenario list — populated")
s+=T(26,64,"SCENARIOS",9.5,"rgba(232,163,61,.85)",MONO,3)
s+=T(364,66,"+",18,GOLD,MONO,0,"middle")
rows=[("Vendor renewal","updated 2h ago","◐",AMBER),("Job offer — Berlin","updated yesterday","○","rgba(220,224,240,.5)"),("Launch timing","resolved · +$8k vs est.","●",BLUE)]
for i,(t,sub,g,gc) in enumerate(rows):
    y=130+i*118
    # micro-tree thumb
    tx,ty=52,y+36
    s+=fil(tx,ty+22,tx-16,ty-2,1,.5)+fil(tx,ty+22,tx+4,ty-6,1.4,.7)+fil(tx,ty+22,tx+20,ty,1,.45)
    s+=fil(tx+4,ty-6,tx-4,ty-24,1,.5)+fil(tx+4,ty-6,tx+14,ty-22,1,.4)
    s+=node(tx,ty+22,3)+node(tx-16,ty-2,2.2,op=.8)+node(tx+4,ty-6,2.6)+node(tx+20,ty,2.2,op=.7)
    s+=node(tx-4,ty-24,2,'glowB',BLUE,.8)+node(tx+14,ty-22,2,'glowE',EMBER,.7)
    s+=T(100,y+30,t,17,PARCH,SERIF,0.5)
    s+=T(100,y+50,sub,8.5,"rgba(220,224,240,.45)",MONO,1.2)
    s+=T(358,y+38,g,13,gc,MONO,0,"middle")
    s+=f'<line x1="24" y1="{y+86}" x2="366" y2="{y+86}" stroke="{AMBER}" stroke-opacity=".13" stroke-width=".6"/>'
svgs["3-list-populated"]=s+"</svg>"

# ——— 4. Canvas idle ———
s=head("Canvas — idle")
s+=tree()
s+=legend()
s+=input_pill()
svgs["4-canvas-idle"]=s+"</svg>"

# ——— 5. Canvas node selected (footer summary) ———
ign={"A","A0","A0x1"}
s=head("Canvas — node selected")
s+=tree(dim=True,ignite=ign)
fy=592
s+=T(24,fy,"DECISION",8,GOLD,MONO,3)
s+=T(24,fy+24,"She accepts the terms",20,PARCH,SERIF,0.4)
s+=T(232,fy+24,"pricing locked · yr 1",9,"rgba(232,163,61,.9)",MONO,.8)
s+=T(24,fy+44,"Confirm scope in writing before the kickoff call.",10.5,"rgba(230,234,248,.85)",MONO,.4)
s+=T(24,fy+64,"62% CONDITIONAL · 31.0% OF ALL FUTURES · DEPTH 2/6",8.5,GOLD,MONO,1.2)
s+=T(24,fy+82,"PAYOFF ≈ +$12k EXPECTED · tap for distribution",8.5,CYAN,MONO,1.2)
gx,gy,gw=24,fy+96,220
s+=f'<rect x="{gx}" y="{gy}" rx="2" width="{gw}" height="4" fill="rgba(220,224,240,.14)"/>'
s+=f'<rect x="{gx}" y="{gy}" rx="2" width="{gw*.72:.0f}" height="4" fill="url(#gauge)"/>'
s+=f'<circle cx="{gx+gw*.72:.0f}" cy="{gy+2}" r="5" fill="{PARCH}"/>'
s+=T(gx,gy+18,"WORST",7.5,"rgba(200,205,230,.5)",MONO,1.2)
s+=T(gx+gw,gy+18,"BEST",7.5,"rgba(200,205,230,.5)",MONO,1.2,"end")
s+=f'<line x1="20" y1="{fy+128}" x2="370" y2="{fy+128}" stroke="{AMBER}" stroke-opacity=".18" stroke-width=".6"/>'
s+=T(W/2,fy+146,"ROOT › OPENING OFFER › SHE ACCEPTS",8.5,GOLD,MONO,1.4,"middle")
s+=input_pill(y=fy+164)
svgs["5-canvas-selected"]=s+"</svg>"

# ——— 6. Canvas distribution view ———
s=head("Canvas — payoff distribution")
s+=tree(dim=True,ignite=ign)
fy=560
s+=T(24,fy,"DECISION",8,GOLD,MONO,3)
s+=T(24,fy+24,"She accepts the terms",20,PARCH,SERIF,0.4)
s+=T(24,fy+46,"PAYOFF DISTRIBUTION",9,CYAN,MONO,2)
bars=[("+$4k",.14,BLUE),("+$8k",.22,BLUE),("+$12k",.38,GOLD),("+$16k",.18,GOLD),("+$22k",.08,GOLD)]
for i,(lab,p,c) in enumerate(bars):
    yy=fy+62+i*17
    s+=T(84,yy+6,lab,9,"rgba(230,234,248,.85)",MONO,.4,"end")
    s+=f'<rect x="94" y="{yy}" rx="3.5" width="200" height="7" fill="rgba(220,224,240,.1)"/>'
    s+=f'<rect x="94" y="{yy}" rx="3.5" width="{200*p*2.2:.0f}" height="7" fill="{c}" opacity=".9"/>'
    s+=T(346,yy+6,f"{int(p*100)}%",9,GOLD,MONO,.5,"end")
s+=T(24,fy+62+5*17+10,"mean ≈ +$12k · over 31.0% of futures · tap to return",8,"rgba(200,205,230,.5)",MONO,1)
s+=f'<line x1="20" y1="{fy+178}" x2="370" y2="{fy+178}" stroke="{AMBER}" stroke-opacity=".18" stroke-width=".6"/>'
s+=T(W/2,fy+196,"ROOT › OPENING OFFER › SHE ACCEPTS",8.5,GOLD,MONO,1.4,"middle")
s+=input_pill(y=fy+214)
svgs["6-canvas-distribution"]=s+"</svg>"

# ——— 7. Mark as reached (context ring) ———
s=head("Canvas — mark as reached")
s+=tree(dim=True,ignite={"A"})
nx,ny=52,452  # A0 node
s+=node(nx,ny,6)
s+=f'<circle cx="{nx}" cy="{ny}" r="22" fill="none" stroke="{GOLD}" stroke-opacity=".8" stroke-dasharray="3 4"/>'
s+=f'<rect x="{nx+34}" y="{ny-30}" rx="14" width="150" height="28" fill="rgba(10,12,26,.85)" stroke="{GOLD}" stroke-opacity=".5"/>'
s+=T(nx+109,ny-12,"MARK AS REACHED",9,GOLD,MONO,1.8,"middle")
s+=f'<rect x="{nx+34}" y="{ny+6}" rx="14" width="150" height="28" fill="rgba(10,12,26,.85)" stroke="rgba(159,232,255,.4)"/>'
s+=T(nx+109,ny+24,"VIEW DISTRIBUTION",9,CYAN,MONO,1.8,"middle")
s+=T(W/2,806,"long-press a node to update reality",9,"rgba(200,205,230,.45)",MONO,1.2,"middle")
svgs["7-mark-reached"]=s+"</svg>"

# ——— 8. Chat sheet mid-detent, tree reorganizing ———
s=head("Chat sheet — streaming")
s+=f'<g transform="translate(0,-120) scale(1)">{tree(ignite={"B","B0"})}</g>'
sy=470
s+=f'<rect x="0" y="{sy}" rx="22" width="{W}" height="{H-sy}" fill="rgba(10,12,26,.86)" stroke="{AMBER}" stroke-opacity=".22"/>'
s+=f'<rect x="{W/2-22}" y="{sy+10}" rx="2" width="44" height="4" fill="rgba(220,224,240,.25)"/>'
s+=f'<rect x="120" y="{sy+34}" rx="12" width="246" height="40" fill="rgba(232,163,61,.1)"/>'
s+=T(354,sy+51,'“She countered at 40. Make losing',10,PARCH,MONO,.2,"end")
s+=T(354,sy+66,'the client −80, not −40.”',10,PARCH,MONO,.2,"end")
s+=T(26,sy+104,"Reweighting. At −80, holding firm flips",10.5,"rgba(230,234,248,.9)",MONO,.3)
s+=T(26,sy+121,"negative: EV −$6k vs +$9k for the",10.5,"rgba(230,234,248,.9)",MONO,.3)
s+=T(26,sy+138,"counter-at-44 branch. The optimal line",10.5,"rgba(230,234,248,.9)",MONO,.3)
s+=T(26,sy+155,"is now counter, then concede scope. ▌",10.5,"rgba(230,234,248,.9)",MONO,.3)
s+=T(26,sy+184,"◈ the futures reorganize…",9,CYAN,MONO,1.4,op=.7)
s+=input_pill(y=H-58)
svgs["8-chat-streaming"]=s+"</svg>"

for name,content in svgs.items():
    (OUT/f"{name}.svg").write_text(content)
print("wrote", len(svgs), "mocks to", OUT)
