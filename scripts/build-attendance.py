#!/usr/bin/env python3
"""Builds the standalone attendance site (attendance/) from the main index.html.
Run after every change to index.html or sw.js:  python3 scripts/build-attendance.py
Same code, same database and accounts; ATT_ONLY switches the app to attendance only."""
import json, os, shutil
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, 'attendance'); os.makedirs(out, exist_ok=True)
s = open(os.path.join(root, 'index.html'), encoding='utf-8').read()
def rep(o, n):
    global s
    assert s.count(o) == 1, 'pattern not found once: ' + o[:60]
    s = s.replace(o, n)
rep('<title>نظام شركة المنصور</title>', '<title>حضور العمال — شركة المنصور</title>')
rep('<meta name="apple-mobile-web-app-title" content="شركة المنصور">', '<meta name="apple-mobile-web-app-title" content="حضور العمال">')
rep('<div id="app" dir="rtl" lang="ar"></div>', '<script>window.ATT_ONLY=true</script>\n<div id="app" dir="rtl" lang="ar"></div>')
open(os.path.join(out, 'index.html'), 'w', encoding='utf-8').write(s)
m = json.load(open(os.path.join(root, 'manifest.json'), encoding='utf-8'))
m.update(name='حضور العمال — شركة المنصور', short_name='حضور العمال', start_url='./', scope='./', id='./attendance/')
json.dump(m, open(os.path.join(out, 'manifest.json'), 'w', encoding='utf-8'), ensure_ascii=False)
for f in ('icon-192.png', 'icon-512.png'): shutil.copyfile(os.path.join(root, f), os.path.join(out, f))
sw = open(os.path.join(root, 'sw.js'), encoding='utf-8').read()
assert "const CACHE = 'mansour-shell-v1';" in sw and "k.startsWith('mansour-shell-')" in sw
sw = sw.replace("const CACHE = 'mansour-shell-v1';", "const CACHE = 'mansour-att-v1';").replace("k.startsWith('mansour-shell-')", "k.startsWith('mansour-att-')")
open(os.path.join(out, 'sw.js'), 'w', encoding='utf-8').write(sw)
print('built attendance/ from index.html')
