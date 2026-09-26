#!/usr/bin/env python3
"""Builds index.html for the Cuecard demo from a real --demo-render run (../out/events.json).
Every line, label and millisecond on screen comes from that run. The meeting plays at SPEED x."""
import html, json, statistics
from pathlib import Path

HERE = Path(__file__).parent
events = json.loads((HERE.parent / "out" / "events.json").read_text())

SPEED = 1.6          # meeting playback speed (the panel clip is made at the same speed)
T0 = 3.5             # meeting starts here in the video
REAL_END = 58.0      # seconds of the real run shown
MEET = REAL_END / SPEED
OUT = T0 + MEET      # outro start
OUT_DUR = 7.5
TOTAL = round(OUT + OUT_DUR, 2)
ROW_H = 188
ROWS_VISIBLE = 4

LABELS = {"action_item": ("Action item", "#6BD68C"), "decision": ("Decision", "#B79CF2"), "next_step": ("Next step", "#7FB6F5"),
          "risk": ("Risk", "#F2877A"), "open_question": ("Open question", "#8EC5FF"), "key_fact": ("Key fact", "#D9D2C6"),
          "asked_you": ("Asked you", "#F7BA52")}
ORDER = ["asked_you", "action_item", "decision", "next_step", "risk", "open_question", "key_fact"]
PEOPLE = {"Priya": "#EDDBBD", "Marcus": "#EDDBBD", "Sam": "#66D6C7"}


def v(t):
    return round(T0 + t / SPEED, 3)


lines = [e for e in events if e["type"] == "line" and e["t"] < REAL_END]
judged = [e for e in events if e["type"] == "judged" and e["t"] < REAL_END + 3]
says = [e for e in events if e["type"] == "card" and e.get("kind") == "Say" and e["t"] < REAL_END]
median_ms = int(statistics.median(e["ms"] for e in events if e["type"] == "judged"))
turns = len([e for e in events if e["type"] == "judged"])

rows_html, tweens = [], []
for i, line in enumerate(lines):
    words = line["text"].split()
    dur = min(6, max(2.2, len(words) / 2.6))
    verdict = next((j for j in judged if j["text"] == line["text"]), None)
    word_spans = " ".join(f'<span class="w" id="w{i}-{k}">{html.escape(w)}</span>' for k, w in enumerate(words))
    chips = ""
    if verdict:
        keys = [k for k in ORDER if k in verdict["scores"]][:3]
        chips = f'<span class="chip jev" id="c{i}-ms">Jev · {verdict["ms"]} ms</span>' + "".join(
            f'<span class="chip" id="c{i}-{n}" style="--c:{LABELS[k][1]}">{LABELS[k][0]} <b>{verdict["scores"][k]:.2f}</b></span>'
            for n, k in enumerate(keys))
    color = PEOPLE.get(line["name"], "#EDDBBD")
    rows_html.append(f'''<div class="row" id="r{i}" style="top:{i * ROW_H}px">
  <div class="who" style="color:{color}">{html.escape(line["name"])}{' <span class="you">you</span>' if line["speaker"] == "You" else ''}</div>
  <div class="said">{word_spans}</div>
  <div class="chips">{chips}</div>
</div>''')
    start = v(line["t"])
    tweens.append(f'tl.from("#r{i}", {{opacity: 0, y: 24, duration: 0.35, ease: "power3.out"}}, {round(start - 0.05, 3)});')
    for k in range(len(words)):
        tweens.append(f'tl.from("#w{i}-{k}", {{opacity: 0, duration: 0.12, ease: "none"}}, {round(start + dur * (k + 1) / len(words) / SPEED, 3)});')
    if verdict:
        at = v(verdict["t"])
        tweens.append(f'tl.from("#c{i}-ms", {{opacity: 0, scale: 0.8, duration: 0.22, ease: "back.out(2)"}}, {at});')
        for n in range(len([k for k in ORDER if k in verdict["scores"]][:3])):
            tweens.append(f'tl.from("#c{i}-{n}", {{opacity: 0, y: 10, duration: 0.28, ease: "expo.out"}}, {round(at + 0.08 + n * 0.07, 3)});')
    if i >= ROWS_VISIBLE:
        tweens.append(f'tl.to("#rows", {{y: {-(i - ROWS_VISIBLE + 1) * ROW_H}, duration: 0.45, ease: "power3.inOut"}}, {round(start - 0.1, 3)});')
    # speaking highlight on the participant tile
    tweens.append(f'tl.to("#p-{line["name"]}", {{borderColor: "{color}", boxShadow: "0 0 0 6px {color}33", duration: 0.2}}, {start});')
    tweens.append(f'tl.to("#p-{line["name"]}", {{borderColor: "rgba(255,255,255,0.10)", boxShadow: "0 0 0 0px {color}00", duration: 0.3}}, {round(start + dur / SPEED + 0.1, 3)});')

audio = []
for n, j in enumerate(j for j in judged if j["t"] < REAL_END):
    audio.append(f'<audio id="tick{n}" class="clip" data-start="{v(j["t"])}" data-duration="0.4" data-track-index="5" src=".media/audio/sfx/sfx_001.mp3" data-volume="0.35"></audio>')
for n, s_ in enumerate(says[:2]):
    audio.append(f'<audio id="chime{n}" class="clip" data-start="{v(s_["t"])}" data-duration="2.5" data-track-index="{6 + n}" src=".media/audio/sfx/sfx_002.mp3" data-volume="0.5"></audio>')

beats = [(8.1, "Jev reads each sentence the moment it ends"),
         (23.8, "A commitment becomes an action item: owner, due date"),
         (30.7, "Asked directly? Claude drafts what to say"),
         (46.2, "Decisions and next steps, captured as they happen")]
beat_html = "".join(f'<div class="beat" id="b{n}" style="top:{n * 64}px">{html.escape(text)}</div>' for n, (_, text) in enumerate(beats))
for n, (t, _) in enumerate(beats):
    tweens.append(f'tl.from("#b{n}", {{opacity: 0, y: 24, duration: 0.45, ease: "power4.out"}}, {v(t)});')
    if n:
        tweens.append(f'tl.to("#beats", {{y: {-n * 64}, duration: 0.45, ease: "power3.inOut"}}, {v(t)});')

for s in says[:2]:
    tweens.append(f'tl.to("#ring", {{opacity: 1, duration: 0.25, ease: "power2.out"}}, {v(s["t"])});')
    tweens.append(f'tl.to("#ring", {{opacity: 0.0, duration: 0.8, ease: "power2.in"}}, {round(v(s["t"]) + 1.4, 3)});')

MARK = '<svg viewBox="0 0 22 17" fill="none" aria-hidden="true"><rect x="1.2" y="1.8" width="19.6" height="13.4" rx="2.2" stroke="currentColor" stroke-width="1.6"/><rect x="1.2" y="4.6" width="19.6" height="1.3" fill="currentColor"/><rect x="4" y="8.2" width="13" height="2.4" rx="1.2" fill="currentColor"/><rect x="4" y="11.6" width="8" height="1.3" rx=".65" fill="currentColor"/></svg>'

page = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=1920, height=1080" />
<script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
<style>
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
html, body {{ width: 1920px; height: 1080px; overflow: hidden; background: #121316; }}
#root {{ position: relative; width: 1920px; height: 1080px; font-family: "Inter", sans-serif; color: #ECE9E4;
  background: radial-gradient(900px 600px at 78% 40%, rgba(247,186,82,0.10), rgba(247,186,82,0) 70%), #121316; }}
.scene {{ position: absolute; inset: 0; }}
.mono {{ font-family: "JetBrains Mono", monospace; }}
.brand {{ display: flex; align-items: center; gap: 14px; font-weight: 700; font-size: 30px; color: #ECE9E4; }}
.brand svg {{ width: 40px; height: 31px; color: #F7BA52; }}

/* title */
#title .scene-content {{ display: flex; flex-direction: column; justify-content: center; width: 100%; height: 100%; padding: 0 180px; gap: 34px; }}
#title h1 {{ font-size: 92px; line-height: 1.04; font-weight: 700; letter-spacing: -0.03em; max-width: 1400px; }}
#title h1 em {{ font-style: normal; color: #F7BA52; }}
#title p {{ font-size: 34px; color: #A7A39C; }}

/* meeting */
#meeting .scene-content {{ position: absolute; left: 110px; top: 70px; width: 1030px; height: 940px; display: flex; flex-direction: column; gap: 26px; }}
.topbar {{ display: flex; align-items: center; justify-content: space-between; }}
.people {{ display: flex; gap: 14px; }}
.tile {{ display: flex; align-items: center; gap: 10px; padding: 10px 18px 10px 10px; border-radius: 16px; background: #1c1d21;
  border: 2px solid rgba(255,255,255,0.10); font-size: 22px; font-weight: 600; }}
.tile i {{ width: 40px; height: 40px; border-radius: 50%; display: grid; place-items: center; font-style: normal; font-weight: 700; color: #121316; }}
.meta {{ font-size: 20px; color: #A7A39C; }}
.beats {{ position: relative; height: 64px; overflow: hidden; }}
#beats {{ position: absolute; inset: 0; }}
.beat {{ position: absolute; left: 0; height: 64px; display: flex; align-items: center; font-size: 34px; font-weight: 650; color: #F7BA52; letter-spacing: -0.01em; }}
.feed {{ position: relative; flex: 1; overflow: hidden; }}
#rows {{ position: absolute; inset: 0; }}
.row {{ position: absolute; left: 0; width: 1020px; height: {ROW_H - 16}px; padding: 18px 22px; border-radius: 18px; background: #1c1d21;
  display: flex; flex-direction: column; gap: 8px; }}
.who {{ font-size: 21px; font-weight: 700; letter-spacing: 0.02em; }}
.who .you {{ font-size: 16px; font-weight: 600; color: #121316; background: #66D6C7; padding: 1px 8px; border-radius: 6px; margin-left: 6px; }}
.said {{ font-size: 27px; line-height: 1.32; color: #ECE9E4; }}
.chips {{ display: flex; gap: 10px; margin-top: auto; }}
.chip {{ font-family: "JetBrains Mono", monospace; font-size: 17px; font-weight: 600; padding: 5px 12px; border-radius: 999px;
  color: var(--c, #ECE9E4); background: color-mix(in srgb, var(--c, #ECE9E4) 16%, transparent); }}
.chip b {{ font-weight: 500; opacity: 0.75; margin-left: 4px; }}
.chip.jev {{ color: #121316; background: #F7BA52; }}
#frame {{ position: absolute; left: 1250px; top: 50px; width: 560px; height: 970px; }}
#crop {{ position: absolute; inset: 0; overflow: hidden; border-radius: 22px; box-shadow: 0 30px 80px rgba(0,0,0,0.55), 0 0 0 1px rgba(255,255,255,0.08); }}
#pan {{ position: absolute; left: 0; top: 0; width: 560px; height: 1400px; }}
#panel {{ width: 560px; height: 1400px; }}
#ring {{ position: absolute; inset: -10px; border-radius: 30px; border: 3px solid #F7BA52; box-shadow: 0 0 60px rgba(247,186,82,0.35); opacity: 0; }}
.panel-label {{ position: absolute; left: 1250px; top: 1034px; font-size: 18px; color: #A7A39C; }}

/* outro */
#outro .scene-content {{ display: flex; flex-direction: column; justify-content: center; width: 100%; height: 100%; padding: 0 180px; gap: 30px; }}
.stats {{ display: flex; gap: 70px; }}
.stat b {{ display: block; font-size: 110px; font-weight: 700; letter-spacing: -0.03em; color: #F7BA52; font-variant-numeric: tabular-nums; }}
.stat span {{ font-size: 28px; color: #A7A39C; }}
.bullets {{ display: flex; flex-direction: column; gap: 14px; font-size: 36px; }}
.bullets div::before {{ content: ""; display: inline-block; width: 14px; height: 14px; border-radius: 4px; background: #F7BA52; margin-right: 18px; vertical-align: middle; }}
.foot {{ display: flex; align-items: center; justify-content: space-between; margin-top: 20px; font-size: 30px; color: #ECE9E4; }}
.foot .mono {{ color: #66D6C7; }}
</style>
</head>
<body>
<div id="root" data-composition-id="main" data-start="0" data-duration="{TOTAL}" data-width="1920" data-height="1080">

  <div id="title" class="scene clip" data-start="0" data-duration="{T0 + 0.5}" data-track-index="1">
    <div class="scene-content">
      <div class="brand" id="t-brand">{MARK} Cuecard</div>
      <h1 id="t-h1">Every sentence of your meeting, <em>sorted as it's said.</em></h1>
      <p id="t-sub">Live meeting copilot · each turn classified by Jev in ~{median_ms} ms</p>
    </div>
  </div>

  <div id="meeting" class="scene clip" data-start="{T0}" data-duration="{MEET + 0.5}" data-track-index="2">
    <div class="scene-content">
      <div class="topbar">
        <div class="people">
          <div class="tile" id="p-Priya"><i style="background:#EDDBBD">P</i>Priya</div>
          <div class="tile" id="p-Marcus"><i style="background:#D9C39A">M</i>Marcus</div>
          <div class="tile" id="p-Sam"><i style="background:#66D6C7">S</i>Sam (you)</div>
        </div>
        <div class="meta">Fictional meeting · {SPEED}× speed</div>
      </div>
      <div class="beats"><div id="beats" data-layout-allow-overflow>{beat_html}</div></div>
      <div class="feed"><div id="rows" data-layout-allow-overflow>{"".join(rows_html)}</div></div>
    </div>
    <div class="panel-label">The real Cuecard panel, same run</div>
  </div>

  <div id="frame">
    <div id="crop"><div id="pan">
      <video id="panel" class="clip" data-start="{T0}" data-duration="{MEET}" data-track-index="3" src="panel.mp4" muted playsinline></video>
    </div></div>
    <div id="ring"></div>
  </div>
  {"".join(audio)}

  <div id="outro" class="scene clip" data-start="{OUT}" data-duration="{OUT_DUR}" data-track-index="1">
    <div class="scene-content">
      <div class="stats">
        <div class="stat" id="s1"><b>{turns}</b><span>turns judged, one by one</span></div>
        <div class="stat" id="s2"><b>{median_ms} ms</b><span>median Jev verdict</span></div>
      </div>
      <div class="bullets">
        <div id="o1">Actions, decisions, risks and questions, captured live</div>
        <div id="o2">Claude drafts what to say when you're asked</div>
        <div id="o3">Recap, transcript and recording filed to Notion afterwards</div>
      </div>
      <div class="foot"><div class="brand" id="o-brand">{MARK} Cuecard · open source</div><div class="mono" id="o-link">github.com/abhitsian/cuecard · classification by Jev</div></div>
    </div>
  </div>
</div>
<script>
window.__timelines = window.__timelines || {{}};
const tl = gsap.timeline({{ paused: true }});
// title
tl.from("#t-brand", {{opacity: 0, y: 20, duration: 0.5, ease: "power3.out"}}, 0.2);
tl.from("#t-h1", {{opacity: 0, y: 50, duration: 0.8, ease: "expo.out"}}, 0.35);
tl.from("#t-sub", {{opacity: 0, y: 20, duration: 0.6, ease: "power2.out"}}, 0.9);
// meeting enters over the title
tl.from("#meeting", {{opacity: 0, duration: 0.5, ease: "power1.out"}}, {T0});
tl.from("#frame", {{opacity: 0, x: 60, duration: 0.7, ease: "power3.out"}}, {T0});
tl.from(".tile", {{opacity: 0, y: -14, duration: 0.4, ease: "back.out(1.6)", stagger: 0.08}}, {T0 + 0.2});
{chr(10).join(tweens)}
// near the end, pan the panel down to the Captured list
tl.to("#pan", {{y: -430, duration: 1.4, ease: "power2.inOut"}}, {v(47.5)});
// outro enters over the meeting
tl.from("#outro", {{opacity: 0, duration: 0.5, ease: "power1.out"}}, {OUT});
tl.to("#frame", {{opacity: 0, duration: 0.4, ease: "power1.in"}}, {OUT});
tl.from("#s1", {{opacity: 0, y: 40, duration: 0.6, ease: "expo.out"}}, {OUT + 0.3});
tl.from("#s2", {{opacity: 0, y: 40, duration: 0.6, ease: "expo.out"}}, {OUT + 0.45});
tl.from("#o1", {{opacity: 0, x: -30, duration: 0.5, ease: "power3.out"}}, {OUT + 1.2});
tl.from("#o2", {{opacity: 0, x: -30, duration: 0.5, ease: "power3.out"}}, {OUT + 1.45});
tl.from("#o3", {{opacity: 0, x: -30, duration: 0.5, ease: "power3.out"}}, {OUT + 1.7});
tl.from("#o-brand", {{opacity: 0, y: 20, duration: 0.5, ease: "power2.out"}}, {OUT + 2.3});
tl.from("#o-link", {{opacity: 0, y: 20, duration: 0.5, ease: "power2.out"}}, {OUT + 2.45});
tl.to("#outro", {{opacity: 0, duration: 0.8, ease: "power2.in"}}, {round(TOTAL - 0.8, 2)});
window.__timelines["main"] = tl;
</script>
</body>
</html>
'''
(HERE / "index.html").write_text(page)
print(f"index.html: {TOTAL}s, {len(lines)} lines, {len(judged)} verdicts, median {median_ms} ms")
