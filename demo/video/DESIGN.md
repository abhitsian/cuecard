# Cuecard demo — design

## Style Prompt
Calm, precise product film. A dark room with one warm light: Cuecard's charcoal panel and amber accent, cream text for other people, teal for you. Motion is quick and exact, like the app: things land, they don't float. The meeting reads like a well-set transcript; Jev's labels snap onto each sentence with a measured millisecond count. No glitter, no gradients across the whole frame.

## Colors
- Canvas: #121316 (charcoal, the panel's surroundings)
- Surface: #1c1d21 (rows, cards)
- Amber accent: #F7BA52 (Cuecard, SAY, highlights)
- Them / cream: #EDDBBD (other speakers' names and text)
- You / teal: #66D6C7 (Sam, "You")
- Label colours from the app: Action #6BD68C, Decision #B79CF2, Next step #7FB6F5, Risk #F2877A, Open question #7FB6F5, Key fact #D9D2C6, Asked you #F7BA52
- Body text: #ECE9E4; secondary: #A7A39C

## Typography
- Inter (600/700 headlines, 400/500 body)
- JetBrains Mono (millisecond counts, scores)

## What NOT to Do
- No full-frame linear gradients (banding); one radial amber glow at most.
- No invented numbers: every label and ms value comes from events.json of a real run.
- No real people, companies or products besides Cuecard and Jev: the meeting is fictional (Northwind).
- No bouncy/elastic eases on data; labels snap (expo/power4 out).
- No text under 20px except mono labels (16px+).
