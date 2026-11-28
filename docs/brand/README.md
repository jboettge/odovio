# odovio – Marke

Gewählt am 28.11.2026 aus den Entwürfen (Design-Canvas «odovio Logo-Entwürfe»): **Logo B «Doppelanzeige»**,
**App-Icon A «Instrument-O»**.

| Datei | Verwendung |
|---|---|
| `odovio-mark.svg` | Bildmarke B (Tacho + Tankuhr) auf hellem Grund |
| `odovio-mark-dark.svg` | Bildmarke B auf dunklem Grund (`#12213A`) |
| `odovio-app-icon.svg` | App-Icon A, randlos (iOS maskiert die Ecken selbst) |
| `odovio-app-icon-1024.png` | App-Icon A, 1024 px, RGB ohne Alpha (App Store) |

Eingebaut:
- iOS: `ios/Fahrzeugbuch/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (aus `odovio-app-icon.svg`)
- Web: `web/public/favicon.svg` (App-Icon A, vereinfacht für 16–32 px), `web/public/apple-touch-icon.png` (180 px),
  Bildmarke B als Komponente `web/src/components/BrandMark.vue` (Navigation, Anmeldeseite; hell/dunkel)

## Farben

| Token | Wert | Rolle |
|---|---|---|
| Ink | `#12213A` | Linien, App-Icon-Grund |
| Amber | `#F2A541` | Nadeln, Tankstand (an die Tankwarnleuchte angelehnt) – nur Grafik, nicht für Text auf Weiss |
| Weiss | `#FFFFFF` | Grund / Linien auf dunkel |

## Schrift

Wortmarke «odovio» klein geschrieben, halbfett, leicht enger Buchstabenabstand (−0.02 bis −0.03 em).
Entwürfe in Space Grotesk 600; im Web die Systemschrift (keine externen Fonts wegen CSP).

## Regeln

- Bildmarke nicht verzerren, Nadeln immer im Akzent, Mindestgrösse der Bildmarke 24 px Höhe.
- Unter 40 px App-Icon ohne Zapfsäule (Favicon-Variante).

PNG neu erzeugen (Chromium/Playwright): SVG im Browser in der Zielgrösse rendern, ohne Alpha speichern.
