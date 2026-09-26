#!/usr/bin/env python3
"""Builds board.html: title (the legend), the real meeting board from a --demo-render run with DEMO_VIEW=board
(../board/events.json + board.mp4), and an outro. Every number comes from that run."""
import json, statistics
from pathlib import Path

HERE = Path(__file__).parent
events = json.loads((HERE.parent / "board" / "events.json").read_text())
SPEED, REAL = 1.5, 72.0
T0 = 4.5
CLIP = REAL / SPEED
OUT = T0 + CLIP
OUT_DUR = 7.0
TOTAL = round(OUT + OUT_DUR, 2)
v = lambda t: round(T0 + t / SPEED, 3)
judged = [e for e in events if e["type"] == "judged"]
median = int(statistics.median(e["ms"] for e in judged))
answered = len({e["text"] for e in events if e["type"] == "card-update" and e.get("kind") == "Open question"})
says = [e for e in events if e["type"] == "card" and e.get("kind") == "Say" and e["t"] < REAL]
MARK = '<svg viewBox="0 0 22 17" fill="none"><rect x="1.2" y="1.8" width="19.6" height="13.4" rx="2.2" stroke="currentColor" stroke-width="1.6"/><rect x="1.2" y="4.6" width="19.6" height="1.3" fill="currentColor"/><rect x="4" y="8.2" width="13" height="2.4" rx="1.2" fill="currentColor"/><rect x="4" y="11.6" width="8" height="1.3" rx=".65" fill="currentColor"/></svg>'
audio = [f'<audio id="tick{n}" class="clip" data-start="{v(j["t"])}" data-duration="0.4" data-track-index="5" src=".media/audio/sfx/sfx_001.mp3" data-volume="0.35"></audio>'
         for n, j in enumerate(j for j in judged if j["t"] < REAL)]
audio += [f'<audio id="chime{n}" class="clip" data-start="{v(s["t"])}" data-duration="2.5" data-track-index="{6 + n % 2}" src=".media/audio/sfx/sfx_002.mp3" data-volume="0.45"></audio>'
          for n, s in enumerate(says[:4])]
page = f'''<!doctype html>
<html lang="en"><head><meta charset="UTF-8" /><meta name="viewport" content="width=1920, height=1080" />
<script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
<style>
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
html, body {{ width: 1920px; height: 1080px; overflow: hidden; background: #111215; }}
#root {{ position: relative; width: 1920px; height: 1080px; font-family: "Inter", sans-serif; color: #ECE9E4;
  background: radial-gradient(1000px 700px at 70% 30%, rgba(247,186,82,0.08), rgba(247,186,82,0) 70%), #111215; }}
.scene {{ position: absolute; inset: 0; }}
.scene-content {{ display: flex; flex-direction: column; justify-content: center; width: 100%; height: 100%; padding: 0 170px; gap: 30px; }}
.brand {{ display: flex; align-items: center; gap: 14px; font-weight: 700; font-size: 30px; }}
.brand svg {{ width: 40px; height: 31px; color: #F7BA52; }}
h1 {{ font-size: 88px; line-height: 1.04; font-weight: 700; letter-spacing: -0.03em; }}
h1 em {{ font-style: normal; color: #F7BA52; }}
.legend {{ display: flex; flex-direction: column; gap: 18px; margin-top: 10px; }}
.leg {{ display: flex; align-items: baseline; gap: 18px; font-size: 34px; }}
.leg b {{ font-size: 34px; font-weight: 800; min-width: 190px; }}
.leg .jev {{ color: #F7BA52; }} .leg .cl {{ color: #EDDBBD; }}
.leg span {{ color: #C9C5BE; }}
.boxes {{ display: flex; gap: 14px; margin-top: 6px; }}
.box {{ font-size: 24px; font-weight: 700; padding: 8px 16px; border-radius: 12px; }}
.small {{ font-size: 24px; color: #A7A39C; }}
#board {{ position: absolute; inset: 0; width: 1920px; height: 1080px; }}
.stats {{ display: flex; gap: 80px; }}
.stat b {{ display: block; font-size: 104px; font-weight: 700; letter-spacing: -0.03em; color: #F7BA52; }}
.stat span {{ font-size: 28px; color: #A7A39C; }}
.foot {{ display: flex; justify-content: space-between; align-items: center; font-size: 30px; margin-top: 16px; }}
.mono {{ font-family: "JetBrains Mono", monospace; color: #66D6C7; }}
</style></head>
<body>
<div id="root" data-composition-id="main" data-start="0" data-duration="{TOTAL}" data-width="1920" data-height="1080">
  <div id="title" class="scene clip" data-start="0" data-duration="{T0 + 0.5}" data-track-index="1">
    <div class="scene-content">
      <div class="brand" id="t0">{MARK} Cuecard</div>
      <h1 id="t1">Your meeting, <em>sorted as it's said.</em></h1>
      <div class="legend">
        <div class="leg" id="t2"><b class="jev">⚡ Jev</b><span>judges every turn in ~{median} ms and files it</span></div>
        <div class="boxes" id="t3"><div class="box" style="color:#B79CF2;background:rgba(183,156,242,.14)">Decisions</div><div class="box" style="color:#6BD68C;background:rgba(107,214,140,.14)">Tasks</div><div class="box" style="color:#7FB6F5;background:rgba(127,182,245,.14)">Questions</div><div class="box" style="color:#F2877A;background:rgba(242,135,122,.14)">Risks</div></div>
        <div class="leg" id="t4"><b class="cl">✦ Claude</b><span>writes only when words are needed: what to say, what to ask, clean notes</span></div>
      </div>
      <div class="small" id="t5">A fictional meeting, run live through the real app · {SPEED}× speed</div>
    </div>
  </div>
  <video id="board" class="clip" data-start="{T0}" data-duration="{round(CLIP, 2)}" data-track-index="2" src="board.mp4" muted playsinline></video>
  <div id="outro" class="scene clip" data-start="{round(OUT, 2)}" data-duration="{OUT_DUR}" data-track-index="1">
    <div class="scene-content">
      <div class="stats">
        <div class="stat" id="o1"><b>{len(judged)}</b><span>turns judged by Jev</span></div>
        <div class="stat" id="o2"><b>{median} ms</b><span>median verdict</span></div>
        <div class="stat" id="o3"><b>{answered}</b><span>questions answered, ticked off live</span></div>
      </div>
      <div class="small" id="o4" style="font-size:32px;color:#ECE9E4">Afterwards: recap, transcript and recording filed to Notion.</div>
      <div class="foot"><div class="brand" id="o5">{MARK} Cuecard · open source</div><div class="mono" id="o6">github.com/abhitsian/cuecard · classification by Jev</div></div>
    </div>
  </div>
  {"".join(audio)}
</div>
<script>
window.__timelines = window.__timelines || {{}};
const tl = gsap.timeline({{ paused: true }});
tl.from("#t0", {{opacity: 0, y: 20, duration: 0.5, ease: "power3.out"}}, 0.2);
tl.from("#t1", {{opacity: 0, y: 50, duration: 0.8, ease: "expo.out"}}, 0.35);
tl.from("#t2", {{opacity: 0, x: -30, duration: 0.5, ease: "power3.out"}}, 1.1);
tl.from("#t3 .box", {{opacity: 0, y: 16, duration: 0.4, ease: "back.out(1.8)", stagger: 0.1}}, 1.5);
tl.from("#t4", {{opacity: 0, x: -30, duration: 0.5, ease: "power2.out"}}, 2.2);
tl.from("#t5", {{opacity: 0, duration: 0.5, ease: "power1.out"}}, 2.8);
tl.from("#board", {{opacity: 0, duration: 0.5, ease: "power1.out"}}, {T0});
tl.from("#outro", {{opacity: 0, duration: 0.5, ease: "power1.out"}}, {round(OUT, 2)});
tl.from("#o1", {{opacity: 0, y: 40, duration: 0.6, ease: "expo.out"}}, {round(OUT + 0.3, 2)});
tl.from("#o2", {{opacity: 0, y: 40, duration: 0.6, ease: "expo.out"}}, {round(OUT + 0.45, 2)});
tl.from("#o3", {{opacity: 0, y: 40, duration: 0.6, ease: "expo.out"}}, {round(OUT + 0.6, 2)});
tl.from("#o4", {{opacity: 0, x: -30, duration: 0.5, ease: "power3.out"}}, {round(OUT + 1.3, 2)});
tl.from("#o5", {{opacity: 0, y: 20, duration: 0.5, ease: "power2.out"}}, {round(OUT + 2.0, 2)});
tl.from("#o6", {{opacity: 0, y: 20, duration: 0.5, ease: "power2.out"}}, {round(OUT + 2.15, 2)});
tl.to("#outro", {{opacity: 0, duration: 0.8, ease: "power2.in"}}, {round(TOTAL - 0.8, 2)});
window.__timelines["main"] = tl;
</script>
</body></html>
'''
(HERE / "index.html").write_text(page)
print(f"index.html: {TOTAL}s, {len(judged)} verdicts, median {median} ms, {answered} answered")
