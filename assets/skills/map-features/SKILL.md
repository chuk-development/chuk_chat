---
name: map-features
description: Use when asked about road closures, roadworks or detours (Sperrung, Baustelle, Umleitung) or when a map should show a street or an area. Draws them as coloured lines and polygons in a <map>.
allowed-tools: road_closures web_search web_crawl geocode
metadata:
  version: "1.0"
---

# Map features: closures, roadworks, detours, areas

A `<map>` block with a `"features"` list draws each item as what it is: a
closed road stretch as a red line, roadworks orange, a detour as a dashed
blue line, an area as a filled polygon, a point as a pin. Every item gets an
icon on the map and a row under it; a tap opens its details (what, dates,
detour, source). You do NOT write coordinates for roads: name the road and
the app finds its real course.

## Workflow for "Sperrungen / Baustellen / closures in <town>"

1. Call `road_closures` with `place` (e.g. `{"place":"Preetz"}`). It
   returns the official feed (federal, state, county roads, motorways,
   detour routes) with a ready `Map feature` object per entry.
2. Municipal streets are mostly NOT in that feed. Also `web_search`
   "<town> Sperrung" / "<town> Vollsperrung" (town website, local paper),
   and `web_crawl` the best hit for street names, cross streets and dates.
3. Write one short answer (what is closed today, what starts soon), then
   ONE `<map>` with all items: copy the tool's `Map feature` objects
   unchanged, and add the web findings as `road` + `town` + `from`/`to`.
4. Never invent closures. If nothing is found, say so; no empty map.

## Format

<map>
{"title":"Sperrungen Preetz","town":"Preetz","features":[
{"kind":"closure","road":"Wakendorfer Straße","from":"Rethwischer Weg","to":"Urnenweg","label":"Vollsperrung Wakendorfer Straße","dates":"26.10. – 30.10.2026","info":"Asphaltarbeiten der Stadtwerke","detour":"über Kührener Straße","url":"https://www.preetz.de/..."},
{"kind":"detour","road":"Kührener Straße","label":"Umleitung"},
{"kind":"roadworks","ref":"sh:8:445,447","label":"L39 Alleebaumpflanzungen","dates":"06.11.2026 – 05.11.2027","info":"Halbseitige Sperrung mit Ampel"},
{"kind":"closure","area":"Marktplatz","label":"Wochenmarkt","dates":"Sa 7-13 Uhr"}
]}
</map>

## Fields (all optional except one geometry)

- `kind`: `closure` (red), `roadworks` (orange), `detour` (dashed blue),
  `info` (grey pin). German words work too (Sperrung, Baustelle, Umleitung).
- Geometry, pick ONE:
  - `ref`: copied from a `road_closures` result. Best: exact official line.
  - `road` + `town` (+ `from`, `to` = the two cross streets that bound the
    stretch). Without `from`/`to` the whole street is drawn. `from`/`to`
    may also be `[lat,lon]`.
  - `area`: a place name ("Marktplatz") or a polygon `[[lat,lon],...]`.
  - `line`: `[[lat,lon],...]`, only when you have real coordinates.
  - `lat` + `lon`: a single point.
- `town` on the map object is the default for every feature.
- `label`: short title. `dates`: free text ("26.10. – 30.10.2026").
  `info`: what happens. `detour`: the detour in words. `url`: the source page.

## Rules

- Street names exactly as on the source (with "Straße", not "Str.").
- One `<map>` per answer for all closures of a place.
- Coordinates only from tool results; never guess them. Prefer `road`.
