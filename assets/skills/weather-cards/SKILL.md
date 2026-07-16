---
name: weather-cards
description: Renders weather data as a <weather> card with current conditions, daily forecast and hourly outlook. Use when the user asks about weather, forecast, temperature, rain, wind, storm, Wetter, Vorhersage, Regen, Temperatur — load this before emitting a <weather> block.
allowed-tools: weather geocode
metadata:
  version: "1.0"
---

# Weather cards

The app renders a `<weather>` block as a polished weather card. It is an
output tag, not a tool: write the JSON directly in your response text.

## Workflow

1. Call the `weather` tool first. If the user named a place the tool cannot
   resolve, use `geocode` to get coordinates, then call `weather` again.
2. Emit exactly one `<weather>` block, populated **only** from the tool
   output.
3. Do not also dump the raw tool text — the card already contains everything.
   A short sentence above the block is fine.

## Format

<weather>
{"location":"Kiel, Schleswig-Holstein, Germany","current":{"temp":8,"feels_like":5,"condition":"Partly cloudy","code":2,"humidity":72,"wind_speed":14,"wind_dir":"W","precipitation":0,"unit_temp":"C","unit_wind":"km/h","unit_precip":"mm"},"daily":[{"date":"2026-04-24","code":2,"temp_max":10,"temp_min":3,"precip_prob":20,"condition":"Partly cloudy"}],"hourly":[{"time":"14:00","code":2,"temp":8,"precip_prob":10}]}
</weather>

## Fields

- `location`: display name (required)
- `current`: `{temp, feels_like, condition, code (WMO 0-99), humidity,
  wind_speed, wind_dir (N/NE/.../NW), precipitation, unit_temp ("C"|"F"),
  unit_wind, unit_precip}` (required)
- `daily`: array of `{date (YYYY-MM-DD), code, temp_max, temp_min,
  precip_prob, condition}` (optional, recommended for forecast queries)
- `hourly`: array of `{time (HH:MM or ISO), code, temp, precip_prob}`
  (optional, include when the user asks for the next hours)

## WMO codes

`0`=clear, `1-2`=partly cloudy, `3`=overcast, `45`/`48`=fog, `51-57`=drizzle,
`61-67`=rain, `71-77`=snow, `80-82`=rain showers, `85-86`=snow showers,
`95-99`=thunderstorm.

## Rules

- Only include fields that came from `weather` tool results in this
  conversation. Never fabricate temperatures, codes, or forecasts.
- Emit at most one `<weather>` block per response.
- Put the block at the very END of your answer and stop after `</weather>`.
- Match `unit_temp` to the user's locale expectation: "C" for German and
  European queries, "F" only when the user is clearly using Fahrenheit.
