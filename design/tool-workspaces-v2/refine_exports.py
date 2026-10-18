"""Polish exported mockups only; unchanged Stitch originals live under .stitch/designs/."""
import re, json, html
from pathlib import Path
root=Path(__file__).parent
left={'name':'DontsTool','version':'1.0.0','enabled':True,'shortcuts':['json','uuid'],'preferences':{'wrap':True,'indent':2}}
right={'name':'DontsTool Studio','version':'1.0.1','enabled':True,'shortcuts':['json','uuid'],'theme':'system','preferences':{'wrap':True,'indent':2}}

def div_range(text,start):
    depth=0
    for token in re.finditer(r'<(/?)div\b[^>]*>',text[start:]):
        depth+=-1 if token.group(1) else 1
        if depth==0:
            return start+token.start(), start+token.end()
    raise ValueError('Missing div boundary')

for theme in ['linen','graphite']:
    source=(Path('.stitch/designs/tool-workspaces-v2')/(theme+'.html')).read_text()
    replacements=[]
    containers=list(re.finditer(r'<div\b[^>]*class="[^"]*\bwhitespace-pre\b[^"]*"[^>]*>',source))
    assert len(containers)==2, (theme,len(containers))
    for index, match in enumerate(containers):
        end,_=div_range(source,match.start())
        lines=json.dumps(left if index==0 else right,indent=2,ensure_ascii=False).splitlines()
        string_color='#A65B3E' if theme=='linen' else '#E4B28B'
        key_color='#18786F' if theme=='linen' else '#8BCDBB'
        literal_color='#765CAD' if theme=='linen' else '#B6A4DF'
        rows=[]
        for line in lines:
            escaped=html.escape(line)
            def token_color(m):
                value=m.group(0)
                color=key_color if value.startswith('&quot;') and escaped[m.end():].lstrip().startswith(':') else string_color if value.startswith('&quot;') else literal_color
                return f'<span style="color:{color}">{value}</span>'
            decorated=re.sub(r'&quot;.*?&quot;|\b(?:true|false|null|\d+)\b',token_color,escaped)
            added='"theme"' in line; changed='"name"' in line or '"version"' in line
            tint=('rgba(74,170,120,.14)' if added else 'rgba(190,145,53,.13)' if changed else 'transparent')
            rows.append(f'<div style="height:21px;white-space:pre;background:{tint}" data-source-line="{len(rows)+1}">{decorated}</div>')
        replacements.append((match.end(),end,''.join(rows)))
        # The preceding gutter is the div following the last gutter comment.
        gutter_comments=list(re.finditer(r'<!--[^>]*Gutter[^>]*-->',source[:match.start()],re.I))
        gutter_start=source.index('<div',gutter_comments[-1].end())
        open_end=source.index('>',gutter_start)+1
        close_start,_=div_range(source,gutter_start)
        numbers=''.join(f'<div style="height:21px;line-height:21px">{i}</div>' for i in range(1,len(lines)+1))
        replacements.append((open_end,close_start,numbers))
    for start,end,replacement in sorted(replacements,reverse=True):
        source=source[:start]+replacement+source[end:]
    bg='#D9D8D2' if theme=='linen' else '#171B1D'
    polish=f'''<style id="export-refinements">
    body {{ background:{bg}!important; min-height:100vh; height:auto!important; overflow:auto!important; padding:28px!important; }}
    body > div.relative {{ height:auto!important; min-height:700px; }}
    .whitespace-pre {{ white-space:normal!important; font-family:ui-monospace,SFMono-Regular,Menlo,monospace!important; line-height:21px!important; }}
    .whitespace-pre>div {{ white-space:pre!important; }}
    button:focus-visible {{ outline:2px solid {key_color};outline-offset:3px; }}
    @media(prefers-reduced-motion:reduce){{ *,*::before,*::after{{animation:none!important;transition:none!important;}} }}
    </style>'''
    source=source.replace('</head>',polish+'\n</head>')
    (root/(theme+'.html')).write_text(source)
print('Refined two exports: exact sample differences, matching line numbers, code whitespace and reduced motion.')
