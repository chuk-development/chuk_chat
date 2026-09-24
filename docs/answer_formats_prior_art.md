# Antwortformate jenseits von Markdown: Prior Art

Stand: 2026-09-24. Recherche per WebSearch/WebFetch. Grundlage für die vier
Konzepte aus `docs/` (Regler-Antwort, Weiche, Gewichtungs-Duell, Tagesband).

Legende "Art der UI":

- **Modell-generiert (Code)**: Das Modell schreibt HTML/JS, der Client zeigt es in einer Sandbox.
- **Modell-generiert (Katalog)**: Das Modell schreibt eine JSON-Beschreibung, der Client rendert sie mit handgebauten Komponenten.
- **Handgebaut**: Ein Mensch hat die UI entworfen. Das Modell liefert höchstens Daten.

---

## 1. Übersicht der Prior Art

### 1.1 Große Chat-Produkte

| Produkt | Jahr | Wie es funktioniert | Art der UI | Link |
|---|---|---|---|---|
| Google Gemini "Generative UI": **Dynamic View** und **Visual Layout** | 11/2025 (mit Gemini 3) | Dynamic View: Gemini 3 schreibt pro Prompt eine eigene interaktive Web-App (HTML/CSS/JS). Das System besteht aus Tools (Bildgenerierung, Suche), einem langen System-Prompt und einer Nachbearbeitung, die typische Fehler repariert. Visual Layout: magazinartige Seite mit Fotos und Modulen, die weitere Eingaben abfragen. Die Generierung kann über eine Minute dauern. | Modell-generiert (Code) | https://research.google/blog/generative-ui-a-rich-custom-visual-interactive-user-experience-for-any-prompt/ |
| Google Search AI Mode / AI Overviews, Generative UI | AI Mode 11/2025, AI Overviews 2026 (I/O 2026: für alle) | Eingebettete Rechner und Simulationen in der Suche, z. B. ein **Hypothekenrechner zum Vergleich von Kreditlaufzeiten** und eine interaktive pH-Skala. Eine Folgefrage erweitert **dieselbe** Visualisierung, z. B. "trag Zitrusfrüchte auf der pH-Skala ein". | Modell-generiert (Code) | https://www.searchenginejournal.com/google-expands-generative-ui-beyond-ai-mode-into-ai-overviews/586452/ |
| Google AI Mode **Canvas** für Reisen | 11/2025 | Planer im Seitenpanel: Flüge, Hotels, Maps-Daten und Tagespläne in einem editierbaren Reiseplan. Folgefragen ändern den Plan. | Handgebaut, mit Modelldaten | https://9to5google.com/2025/11/17/google-ai-mode-travel/ |
| ChatGPT **Interactive Learning** (Mathe/Physik) | 03/2026 | Bei über 70 festen Konzepten (Zinseszins, Ohmsches Gesetz, Gasgesetze, Pythagoras ...) erscheint ein Modul mit **Reglern für Variablen**. Graph und Ergebnis ändern sich sofort. | Handgebaut. Pro Konzept ein fertiges Modul, das Modell wählt es aus. | https://techcrunch.com/2026/03/10/chatgpt-can-now-create-interactive-visuals-to-help-you-understand-math-and-science-concepts |
| ChatGPT **Shopping Research** | 11/2025 | Vor der Recherche stellt ChatGPT ein **kurzes Quiz mit Auswahl-Buttons** zu Budget, Größe und Prioritäten. Danach kommt ein Kaufratgeber mit Vergleich. Ein eigenes Modell (GPT-5 mini mit RL) steckt dahinter. | Handgebaut, Inhalt vom Modell | https://help.openai.com/en/articles/12911370-using-shopping-research-in-chatgpt |
| OpenAI **Apps SDK** (ChatGPT-Apps/Widgets) | 10/2025 | Ein MCP-Server liefert ein Widget (HTML in einem iframe). Es gibt drei Anzeigemodi: **Inline-Karte**, **Vollbild** (für Karten und Diagramme, das Eingabefeld bleibt sichtbar) und **Bild-in-Bild** (bleibt beim Weiterchatten sichtbar). `window.openai.requestDisplayMode()` wechselt den Modus. | Handgebaut von Drittanbietern | https://developers.openai.com/apps-sdk/concepts/ui-guidelines |
| Claude **Artifacts** | 06/2024 | Code, Dokumente oder React/HTML-Apps erscheinen in einem Seitenpanel. Sie sind dauerhaft und teilbar. | Modell-generiert (Code) | https://claude.com/blog/claude-builds-visuals (Abgrenzung) |
| **Imagine with Claude** | Herbst 2025 | Forschungsvorschau: Claude baut UI in Echtzeit auf einem virtuellen Desktop. | Modell-generiert (Code) | (siehe nächste Zeile) |
| Claude **interaktive Inline-Visuals** | 03/2026 (Update 04/2026) | Inline im Chat, nicht dauerhaft, HTML/SVG. Anthropic nennt selbst **"calculators, sliders, decision trees"**, Vergleiche, Zeitleisten und Karten, z. B. eine Zinseszins-Kurve zum Verstellen oder ein klickbares Periodensystem. Das Modell entscheidet selbst, wann es ein Visual zeigt. | Modell-generiert (Code) | https://claude.com/blog/claude-builds-visuals |
| Perplexity Antwortkarten / Finance / Wetter | 2024–2026 | Für bestimmte Themen (Aktien, Wetter mit AccuWeather-Daten, Sport) erscheinen feste Karten mit Live-Kurs, interaktivem Chart und Tabs. | Handgebaut, Daten live | https://www.perplexity.ai/finance/workflows |
| WolframAlpha + CDF / Manipulate | 2009 / CDF 08/2011 | Ergebnisse mit symbolischen Parametern bekommen **automatisch Regler**. Der Plot aktualisiert sich laufend. In Mathematica macht `Manipulate[...]` aus jedem Ausdruck mit Parametern eine UI. | Automatisch aus der Formel erzeugt (regelbasiert, kein LLM) | https://writings.stephenwolfram.com/2011/08/wolframalpha-comes-alive-with-cdf/ |

### 1.2 Protokolle und SDKs für Generative UI

| Produkt | Jahr | Wie es funktioniert | Art der UI | Link |
|---|---|---|---|---|
| **A2UI** (Google, Apache 2.0) | 12/2025, v0.9 2026 | Der Agent streamt JSON mit Komponenten, Properties und einem **Datenmodell**. Der Client bildet das auf eigene native Widgets ab (Flutter, Angular, React, SwiftUI). Es wird **kein Code ausgeführt**. Nutzeraktionen gehen als Events zurück an den Agenten, der die UI dann aktualisiert. Der Basiskatalog enthält u. a. `Slider` (min/max), `MultipleChoice` und `DateTimeInput`. | Modell-generiert (Katalog) | https://developers.googleblog.com/introducing-a2ui-an-open-project-for-agent-driven-interfaces/ , https://a2ui.org/ |
| **Flutter GenUI SDK** | ab 2025 (Alpha) | Nutzt A2UI als Format. Das Modell stellt die UI aus **deinem Flutter-Widget-Katalog** zusammen (Regler, Balkendiagramme, Mehrfachauswahl). | Modell-generiert (Katalog) | https://docs.flutter.dev/ai/genui |
| **MCP-UI** (Ido Salomon, Liad Yosef) | 2025 | UI-Ressourcen in MCP-Tool-Antworten: HTML, externe URL oder **Remote DOM**. Remote DOM (von Shopify) rendert host-native Komponenten aus einer Beschreibung. Genutzt von Shopify, Postman, HuggingFace, Goose, ElevenLabs. | Handgebaut vom Server-Anbieter | https://shopify.engineering/mcp-ui-breaking-the-text-wall |
| **MCP Apps** (SEP-1865, Anthropic + OpenAI + MCP-UI) | Vorschlag 11/2025, offiziell 01/2026 | Erste offizielle MCP-Erweiterung. Vorab deklarierte `ui://`-Templates, iframe-Sandbox und bidirektionales JSON-RPC zwischen UI und Host. | Handgebaut vom Server-Anbieter | https://blog.modelcontextprotocol.io/posts/2025-11-21-mcp-apps/ |
| Vercel AI SDK 3.0, `streamUI` (RSC) | 03/2024 | Tool-Calls des Modells werden auf React-Server-Komponenten abgebildet und gestreamt. **Die Entwicklung ist pausiert.** Vercel empfiehlt AI SDK UI. Bekannte Probleme: Flackern und Remounts während des Streams. | Modell wählt handgebaute Komponenten | https://ai-sdk.dev/docs/reference/ai-sdk-rsc/stream-ui |
| Vercel **json-render** | 01/2026 | Katalog mit Zod-Schemas. Das Modell erzeugt JSON, das nur Katalog-Komponenten nutzen darf, und das wird progressiv gerendert. Renderer für React, Vue, Svelte und React Native. | Modell-generiert (Katalog) | https://json-render.dev/ |
| **Thesys C1** (+ Crayon) | 04/2025 | API zwischen App und LLM. Statt Text kommt UI (Charts, Formulare, Karten) aus dem Crayon-React-Komponentenset. | Modell-generiert (Katalog) | https://www.thesys.dev/blogs/generative-ui-architecture |
| **CopilotKit** / AG-UI | 2023 / AG-UI 05/2025 | `useCopilotAction` mit `render`: Ein Tool-Call wird als eigene Komponente angezeigt. Unterstützt "Controlled GenUI" (handgebaut, das Modell füllt Daten), A2UI und MCP Apps. | Beides | https://docs.copilotkit.ai/concepts/generative-ui-overview |

### 1.3 Reaktive Dokumente und Rechen-Notizen (vor den LLMs)

| Produkt | Jahr | Wie es funktioniert | Art der UI | Link |
|---|---|---|---|---|
| Bret Victor, "Explorable Explanations" + **Tangle.js** | 2011 | Zahlen **im Fließtext** lassen sich ziehen. Alle abhängigen Zahlen und Sätze im Dokument rechnen sofort neu. | Handgebaut | https://worrydream.com/Tangle/ |
| **Idyll** (Conlen/Heer, UIST 2018) | 2018 | Markup-Sprache für interaktive Artikel: Variablen, Regler und reaktive Komponenten direkt im Text. | Handgebaut (deklarativ) | https://idyll-lang.org/ |
| Nicky Case, Explorables | ab ca. 2014 | Spielbare Simulationen mit geführter Erklärung (z. B. "Parable of the Polygons"). | Handgebaut | https://en.wikipedia.org/wiki/Explorable_explanation |
| **Observable** | ca. 2018 | Notebook, in dem `viewof x = Inputs.range([0,100])` einen Regler zur reaktiven Variable macht. Alle Zellen, die `x` nutzen, rechnen neu. | Handgebaut | https://observablehq.com/documentation/inputs/overview |
| **Soulver** / **Numi** | Soulver ca. 2005, Numi ca. 2013 | Rechenzettel in natürlicher Sprache: Zeile für Zeile mit Variablen, Einheiten und Währungen. Das Ergebnis steht rechts daneben und wird beim Tippen live neu berechnet. | Handgebaut | https://soulver.app/ |
| **Guesstimate** | 2015 | Tabelle, in der Eingaben **Bereiche statt Punktwerte** sind (z. B. "25 bis 35" als 90-%-Intervall). Eine Monte-Carlo-Rechnung mit 5000 Samples liefert eine Verteilung als Ergebnis. | Handgebaut | https://docs.getguesstimate.com/docs/Introduction |

### 1.4 Forschung

| Arbeit | Jahr | Kern | Link |
|---|---|---|---|
| Chen, Zhang, Shao, Yang (Stanford SALT): "Generative Interfaces for Language Models" | 08/2025, ACL 2026 Findings | Das LLM erzeugt statt Chattext eine aufgabenspezifische UI. Es arbeitet mit strukturierten Zwischenrepräsentationen und iterativer Verfeinerung. Menschen bevorzugen die generierten Oberflächen in über 70 % der Fälle. Code: SALT-NLP/GenUI. | https://arxiv.org/abs/2508.19227 |
| Leviathan, Valevski et al. (Google): "Generative UI: LLMs are Effective UI Generators" | 2026 | Das Paper hinter Gemini Dynamic View. Robuste Generative UI ist eine emergente Fähigkeit großer Modelle. Von Experten gebaute Seiten schneiden am besten ab, Generative UI klar auf Platz 2. | https://arxiv.org/abs/2604.09577 |
| **LineUp** (Gratzl et al., InfoVis 2013) | 2013 | Ranking nach mehreren Attributen. **Gewichte werden über die Spaltenbreite gezogen.** Rangwechsel werden animiert und farbig markiert (grün = gestiegen, rot = gefallen). Mehrere Gewichtungen lassen sich nebeneinander vergleichen. | https://jku-vds-lab.at/tools/lineup/ |
| **ValueCharts** (Carenini & Loyd) | 2004 | Gestapelte Balken aus Gewichten und Scores mit sofortigem Ranking-Feedback. Group ValueCharts zeigt die Gewichte mehrerer Personen nebeneinander. | https://www.cs.ubc.ca/group/iui/VALUECHARTS/ |

### 1.5 Nischenprodukte zu den einzelnen Konzepten

| Produkt | Jahr | Wie es funktioniert | Art der UI | Link |
|---|---|---|---|---|
| **Zingtree** (+ "Author Assist AI") | Plattform seit ca. 2013, KI-Autorenhilfe neuer | Interaktive Entscheidungsbäume für Support und Selbsthilfe, ein Schritt pro Bildschirm mit Buttons. Das LLM erzeugt den Baum aus einem Prompt oder einem hochgeladenen Dokument. **Zur Laufzeit ist der Baum fest.** | Vom Modell verfasst, zur Laufzeit statisch | https://zingtree.com/blog/interactive-decision-tree-software |
| Chatbot-Entscheidungsbäume (Yellow.ai, LiveChatAI u. a.) | seit ca. 2016 | Quick-Reply-Buttons, mehrstufige Troubleshooting-Bäume. Heute oft ein Hybrid: Baum für die häufigsten 80 % der Fälle, LLM-Fallback für den Rest. | Handgebaut | https://livechatai.com/blog/chatbot-decision-tree |
| MyMap Decision Matrix Maker | 2025 | Die KI baut aus einer Beschreibung eine gewichtete Entscheidungsmatrix. Der Nutzer ändert Gewichte und Scores und kann eine **Sensitivitätsanalyse** anfordern. | Modell füllt eine handgebaute Matrix | https://www.mymap.ai/tools/decision-matrix-maker |
| Decidit | – | Kriterien mit Sternen gewichten, Optionen per Regler von 1 bis 10 bewerten, Ranking sofort sichtbar. | Handgebaut | https://www.decidit.de/ |
| **Mindtrip** | 2024 | KI-Reiseplaner: Der Chat steht neben einer Karte, die sich live aktualisiert. Der Tagesplan zeigt die Orte in Reihenfolge mit Routen. | Handgebaut, Modelldaten | https://mindtrip.ai/ |
| **Knight Lab StoryMapJS** | ca. 2014 | Folien sind an Kartenpunkte gebunden. Beim Blättern schwenkt und zoomt die Karte. Auch als Zeitleiste mit Ortsbezug nutzbar. | Handgebaut | https://storymap.knightlab.com/ |
| Polarsteps / Wanderlog | 2015 / 2019 | Polarsteps: Reise-Logbuch mit Zeitleiste und aufgezeichneter Route auf der Karte. Wanderlog: Tagesplanung mit Karte, Drag & Drop. | Handgebaut | https://www.wandrly.app/comparisons/wanderlog-vs-polarsteps |

---

## 2. Die vier Konzepte im Abgleich

### (1) Regler-Antwort: **gibt es schon**

- **ChatGPT Interactive Learning (03/2026)** macht genau das: Variablen als Regler, Ergebnis und Graph live. Es ist aber auf rund 70 handgebaute Schul- und Uni-Konzepte beschränkt.
- **Claude Inline-Visuals (03/2026)** und **Google Generative UI** (Hypothekenrechner, 2025/26) erzeugen beliebige Rechner mit Reglern. Beide lassen dafür jedes Mal HTML/JS generieren. Das ist langsam, nicht nativ und verhält sich nicht gleich.
- Das Muster ist alt: **WolframAlpha/CDF (2011)** erzeugt Regler automatisch aus Formelparametern. Weitere Vorläufer sind **Tangle (2011)**, **Observable** und **Soulver/Numi**.
- **Was an unserer Variante neu bleibt:** Das Modell gibt nur Formel und Variablen als Spezifikation aus. Der Client rechnet und rendert nativ in Flutter. Das ist die Katalog-Variante (wie A2UI/json-render), nur für **beliebige** Formeln statt für feste Konzepte. Einen verbreiteten Standard für ein solches "Formel-Spec" haben wir nicht gefunden. Die Idee selbst ist aber bekannt und hat keinen Neuheitswert.

### (2) Weiche: **teilweise**

- Entscheidungsbäume mit Buttons und "ein Schritt pro Bildschirm" sind seit Jahren Standard im Support (**Zingtree**, Chatbot-Quick-Replies). Diese Bäume sind aber **vorab verfasst**, auch wenn ein LLM beim Verfassen hilft.
- **ChatGPT Shopping Research (11/2025)** stellt vor der Antwort Auswahlfragen mit Buttons. Es ist aber ein Quiz vorab, kein Diagnosepfad.
- **A2UI/MCP Apps** haben den nötigen Mechanismus: Ein Button-Klick geht als Event zurück an den Agenten, der den nächsten Schritt erzeugt.
- Claude nennt "decision trees" als Visual. Gemeint sind aber eher Baum-Diagramme als ein geführter Schritt-für-Schritt-Ablauf.
- **Was fehlt:** Wir haben kein Chat-Produkt gefunden, in dem das Modell **zur Laufzeit** jeweils nur den nächsten Knoten mit Ergebnis-Buttons zeigt und dazu eine **Brotkrumen-Spur** mit Rücksprung führt. Das ist der verteidigbare Teil.

### (3) Gewichtungs-Duell: **teilweise**

- In der Visualisierungsforschung gibt es das seit Jahren: **ValueCharts (2004)** und **LineUp (2013)** mit Gewichten per Ziehen, animierten Rangwechseln und Vergleich mehrerer Gewichtungen. Consumer-Tools wie **Decidit** und **MyMap** (die KI füllt die Matrix, der Nutzer ändert die Gewichte) auch.
- **In einem KI-Chat, inline und aus der Antwort erzeugt**, haben wir es nicht als festes Format gefunden. ChatGPT Shopping Research zeigt Vergleiche, aber keine verstellbaren Gewichte. Claude und Gemini könnten so etwas ad hoc als HTML bauen.
- **Unsere Kombination ist nicht belegt:** Produkte als Punkte auf Attributachsen, Gewichte, die den Sieger live bestimmen, im Chat-Verlauf.

### (4) Tagesband: **teilweise (eher neu im Chat)**

- Das Muster "Zeitleiste ist mit der Karte verbunden" gibt es als handgebautes Tool: **StoryMapJS** (Folie → Karte schwenkt), **Polarsteps** (Zeitleiste und Route). KI-Reiseplaner (**Mindtrip**, **Google AI Mode Canvas**) verbinden Tagesplan und Karte, aber als eigene App oder Seitenpanel und nicht als Scrubber.
- **Einen stufenlosen Zeit-Scrubber** (Uhrzeit ziehen, Position, Weg und Aktivität folgen auf der Karte) **als Chat-Antwort** haben wir nirgends gefunden.

---

## 3. Architektur-Erkenntnis für chuk_chat

Der Markt hat sich 2025/26 in zwei Lager geteilt:

1. **Code-Generierung** (Gemini Dynamic View, Claude Visuals, Artifacts): Das Modell schreibt HTML/JS. Das ist maximal flexibel, aber langsam (Google: teils über 1 Minute), fehleranfällig (Google braucht Nachbearbeitung) und in Flutter nur über eine WebView darstellbar.
2. **Katalog / deklarativ** (A2UI, Flutter GenUI SDK, json-render, Thesys C1, CopilotKit Controlled GenUI, ChatGPT Interactive Learning): Das Modell gibt JSON aus, der Client rendert es mit eigenen Widgets. Das ist schnell, sicher, im Design einheitlich und streamfähig.

chuk_chat liegt mit seinen Tags `<chart>`, `<map>` und `<email>` schon im zweiten Lager. Die vier neuen Formate passen genau dazu. **A2UI + Flutter GenUI SDK** ist das Format, das Google selbst für Flutter vorsieht. Es lohnt sich zu prüfen, ob unsere Tag-Schemas A2UI-kompatibel sein sollten oder ob wir nur dessen Event-Rückkanal übernehmen: Eine UI-Aktion wird zu einem neuen Turn, das braucht die Weiche.

---

## 4. Ideen zum Übernehmen (zusätzliche Visualisierungstypen)

Jeder Punkt ist ein möglicher eigener Tag bzw. eine Erweiterung der vier Konzepte.

1. **Zahl im Satz ziehen** (Tangle, Idyll): Statt separater Regler stehen die Variablen der Regler-Antwort als ziehbare, unterstrichene Zahlen im Fließtext ("Bei **3,5 %** Zins zahlst du **1.240 €** im Monat"). Der Text rechnet mit.
2. **Bereichs-Regler mit Unsicherheitsband** (Guesstimate): Eine Variable darf ein Bereich sein ("Miete 800 bis 1.100 €"). Das Ergebnis wird als Band oder Verteilung gezeigt statt als eine Zahl. Das passt gut zu Schätzfragen.
3. **Rechenzettel** (Soulver/Numi): Die Antwort ist eine Liste von Rechenzeilen mit benannten Zwischenergebnissen und Summe rechts. Jede Zeile ist editierbar, alle folgenden Zeilen rechnen neu. Das ist die "Budget/Nebenkosten"-Variante der Regler-Antwort.
4. **Szenario anheften** (LineUp, Mehrfach-Rankings): Ein aktueller Reglerstand oder eine Gewichtung wird als "Szenario A" gespeichert und neben B gestellt, mit Differenz. Das gilt für Regler-Antwort und Gewichtungs-Duell.
5. **Kipppunkt-Anzeige** (Sensitivitätsanalyse, LineUp, MyMap): Beim Gewichtungs-Duell steht an jedem Gewichtsregler, **ab welchem Wert der Sieger wechselt**. Bei der Regler-Antwort wird markiert, wo eine Schwelle überschritten wird (z. B. "ab hier lohnt sich Kaufen statt Mieten").
6. **Rangpfeile mit Animation** (LineUp): Nach jeder Gewichtsänderung rutschen die Produkte animiert. Grün heißt gestiegen, rot heißt gefallen.
7. **Präferenz-Quiz als Einstieg** (ChatGPT Shopping Research): Vor dem Gewichtungs-Duell kommen 2 bis 4 Auswahlfragen mit Buttons. Die Antworten setzen die Startgewichte. Das ist technisch dieselbe Komponente wie die Weiche.
8. **Folgefrage schreibt das Visual fort** (Google pH-Skala → Zitrusfrüchte): Eine Folgefrage im Chat ändert das **bestehende** Widget (z. B. einen Punkt einfügen oder ein Produkt ergänzen), statt ein neues zu erzeugen.
9. **Anzeigemodi inline / Vollbild / angeheftet** (OpenAI Apps SDK): Das Tagesband startet als kompakte Inline-Karte und öffnet im Vollbild mit großer Karte. Das Eingabefeld bleibt sichtbar. Ein angeheftetes Mini-Widget bleibt beim Weiterchatten oben stehen.
10. **Kapitel-Karte** (StoryMapJS): Eine Erzählung in Stationen (Geschichte, Biografie, Lieferkette). Jede Station ist ein Absatz, die Karte fliegt beim Blättern mit. Das ist die "Folien"-Schwester des Tagesbands für Nicht-Reise-Themen.
11. **Prozess-Stepper / Stufen-Simulation** (Gemini-Beispiel RNA-Polymerase, Nicky Case): Ein Ablauf in nummerierten Stufen mit Vor/Zurück und einem animierten Zustandsbild. Das passt für "wie funktioniert X".
12. **Klickbare Erkundungstafel** (Claude Periodensystem): Ein Raster oder Diagramm, bei dem ein Tippen auf ein Element dessen Details aufklappt. Das passt für Übersichten wie Tarife, Modelle oder Vitamine.
13. **Magazin-Layout** (Gemini Visual Layout): Überblicksantworten als Karten mit Bild, Kernzahl und "mehr dazu"-Button. Jeder Button stellt eine Folgefrage.
14. **Weiche mit Rückkanal und Spur** (A2UI-Events, Zingtree): Jeder Ergebnis-Button wird zum Nutzer-Turn. Die Spur oben erlaubt einen Rücksprung. Beim Rücksprung wird der Ast verworfen, nicht der ganze Chat. Optional wird am Ende ein fertiger Pfad als wiederverwendbarer "Leitfaden" gespeichert, wie ein Zingtree-Baum.

---

## 5. Quellen

- Google Research, Generative UI: https://research.google/blog/generative-ui-a-rich-custom-visual-interactive-user-experience-for-any-prompt/
- Generative UI in AI Overviews / Hypothekenrechner: https://www.searchenginejournal.com/google-expands-generative-ui-beyond-ai-mode-into-ai-overviews/586452/
- Google AI Mode Canvas Reisen: https://9to5google.com/2025/11/17/google-ai-mode-travel/
- A2UI: https://developers.googleblog.com/introducing-a2ui-an-open-project-for-agent-driven-interfaces/ , https://a2ui.org/ , v0.9: https://developers.googleblog.com/a2ui-v0-9-generative-ui/
- Flutter GenUI SDK: https://docs.flutter.dev/ai/genui
- OpenAI Apps SDK UI-Richtlinien: https://developers.openai.com/apps-sdk/concepts/ui-guidelines
- ChatGPT Interactive Learning: https://techcrunch.com/2026/03/10/chatgpt-can-now-create-interactive-visuals-to-help-you-understand-math-and-science-concepts , https://www.engadget.com/ai/chatgpt-will-now-generate-interactive-visuals-to-help-you-with-math-and-science-concepts-170000520.html
- ChatGPT Shopping Research: https://help.openai.com/en/articles/12911370-using-shopping-research-in-chatgpt
- MCP Apps: https://blog.modelcontextprotocol.io/posts/2025-11-21-mcp-apps/ , https://modelcontextprotocol.io/seps/1865-mcp-apps-interactive-user-interfaces-for-mcp
- MCP-UI bei Shopify: https://shopify.engineering/mcp-ui-breaking-the-text-wall
- Vercel streamUI: https://ai-sdk.dev/docs/reference/ai-sdk-rsc/stream-ui , AI SDK 3.0: https://vercel.com/blog/ai-sdk-3-generative-ui
- Vercel json-render: https://json-render.dev/ , https://www.infoq.com/news/2026/03/vercel-json-render/
- Thesys C1: https://www.thesys.dev/blogs/generative-ui-architecture
- CopilotKit Generative UI: https://docs.copilotkit.ai/concepts/generative-ui-overview
- Claude Inline-Visuals: https://claude.com/blog/claude-builds-visuals
- Perplexity Finance: https://www.perplexity.ai/finance/workflows
- WolframAlpha CDF: https://writings.stephenwolfram.com/2011/08/wolframalpha-comes-alive-with-cdf/
- Tangle: https://worrydream.com/Tangle/
- Idyll: https://idyll-lang.org/
- Observable Inputs: https://observablehq.com/documentation/inputs/overview
- Soulver: https://soulver.app/
- Guesstimate: https://docs.getguesstimate.com/docs/Introduction
- Generative Interfaces for LMs: https://arxiv.org/abs/2508.19227
- Generative UI: LLMs are Effective UI Generators: https://arxiv.org/abs/2604.09577
- LineUp: https://jku-vds-lab.at/tools/lineup/
- ValueCharts: https://www.cs.ubc.ca/group/iui/VALUECHARTS/
- Zingtree: https://zingtree.com/blog/interactive-decision-tree-software
- Chatbot-Entscheidungsbäume: https://livechatai.com/blog/chatbot-decision-tree
- MyMap Decision Matrix: https://www.mymap.ai/tools/decision-matrix-maker
- Decidit: https://www.decidit.de/
- Mindtrip: https://mindtrip.ai/
- StoryMapJS: https://storymap.knightlab.com/
- Wanderlog vs. Polarsteps: https://www.wandrly.app/comparisons/wanderlog-vs-polarsteps

Hinweis zur Genauigkeit: Die Jahreszahlen für Soulver (ca. 2005), Numi (ca. 2013), Observable (ca. 2018) und Nicky Case (ca. 2014) stammen nicht aus einer geprüften Quelle, sondern aus allgemeinem Wissen.
