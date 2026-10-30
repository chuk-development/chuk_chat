#!/usr/bin/env python3
"""Finds reference photos and a short fact text for a subject. No key, neutral agent.
refs.py <subject> <out_dir> [n]"""
import json, re, sys, threading, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path
UA = {'User-Agent': 'chalk-refs/1.0'}
LOCK = threading.Lock()


def raw(url):
    # One request at a time, and patience: Wikimedia answers 429 to bursts.
    with LOCK:
        for attempt in range(6):
            try:
                time.sleep(1.2)
                return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30).read()
            except urllib.error.HTTPError as e:
                if e.code != 429 or attempt == 5:
                    raise
                time.sleep(6 * (attempt + 1))


def get(url):
    return json.loads(raw(url))
def photos(subject, n=3):
    q = urllib.parse.urlencode({'action': 'query', 'format': 'json', 'generator': 'search', 'gsrsearch': f'{subject} filetype:bitmap', 'gsrnamespace': 6, 'gsrlimit': 12, 'prop': 'imageinfo', 'iiprop': 'url|size|mime', 'iiurlwidth': 900})
    pages = get('https://commons.wikimedia.org/w/api.php?' + q).get('query', {}).get('pages', {})
    out = []
    for p in sorted(pages.values(), key=lambda x: x.get('index', 99)):
        i = (p.get('imageinfo') or [{}])[0]
        if i.get('mime') in ('image/jpeg', 'image/png') and i.get('width', 0) >= 600:
            out.append(i['thumburl'])
    return out[:n]
def facts(subject):
    q = urllib.parse.urlencode({'action': 'query', 'format': 'json', 'list': 'search', 'srsearch': subject, 'srlimit': 1})
    hit = get('https://en.wikipedia.org/w/api.php?' + q)['query']['search']
    if not hit:
        return ''
    q = urllib.parse.urlencode({'action': 'query', 'format': 'json', 'prop': 'extracts', 'explaintext': 1, 'exchars': 2500, 'titles': hit[0]['title']})
    pages = get('https://en.wikipedia.org/w/api.php?' + q)['query']['pages']
    return next(iter(pages.values())).get('extract', '')
def fetch(subject, d, n=3):
    d = Path(d); d.mkdir(parents=True, exist_ok=True)
    files = []
    for i, u in enumerate(photos(subject, n)):
        f = d / f'ref{i}.jpg'
        try:
            f.write_bytes(raw(u))
            files.append(f)
        except Exception:
            pass
    try:
        return files, facts(subject)
    except Exception:
        return files, ''
if __name__ == '__main__':
    fs, t = fetch(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 3)
    print(len(fs), t[:300])
