"""The control panel's How to use card: four steps, each a small animation.

Markup and script only, spliced into PANEL_HTML by templates.py like the
Layout card. The script sets one attribute, the step, and switches Back off
on the first step; which stage and words show, how the small phone is drawn
in the chosen layout, and every animation live in howto.css.
"""
from __future__ import annotations

# The small phone, in the pad's language: two pads, the wheel between them and
# the power pill. howto.css places them for whichever layout body carries.
_PHONE = ('<div class="ph{cls}"><div class="pad"><i class="l"></i><i class="w"></i>'
          '<i class="r"></i><i class="p"><b></b></i></div>{extra}</div>')
_FINGER = '<span class="fg"></span>'
_CURSOR = ('<span class="cur"><svg viewBox="0 0 10 14"><path d="M1 1 L1 12 L3.8 9.6 L5.6 13.3 '
           'L7.2 12.6 L5.4 8.9 L9 8.9 Z"/></svg></span>')
_CHEVRON = ('<svg viewBox="0 0 10 16"><path d="{d}" fill="none" stroke="currentColor" '
            'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>')

HOWTO_CARD = ("""<div class="card howto" id="howto" data-step="1">
  <b class="t">How to use</b>
  <div class="walk">
    <div class="stage" aria-hidden="true">
      <!-- 1 · tap the pill: the lamp goes green, then red again -->
      <div class="pg s-tap">""" + _PHONE.format(cls="", extra=_FINGER) + """</div>
      <!-- 2 · the desk: a laptop, and the phone lying face up in the hand, pointing at it -->
      <div class="pg s-desk"><div class="scene">
        <div class="lap"><div class="base"></div><div class="lip"></div>
          <div class="lid"><div class="scr"></div>""" + _CURSOR + """</div></div>
        <div class="held"><div class="beam"></div><div class="palm"></div>
          <div class="slab"><div class="edge"></div><div class="endcap"></div>
            """ + _PHONE.format(cls=" small", extra="") + """</div>
          <div class="thumb"></div></div>
      </div></div>
      <!-- 3 · hold the pill: the finger stays, a ring fills round it -->
      <div class="pg s-hold">""" + _PHONE.format(cls="", extra=_FINGER) + """</div>
      <!-- 4 · left pad, right pad, then a finger slides the wheel -->
      <div class="pg s-click">""" + _PHONE.format(cls="", extra=_FINGER) + """</div>
    </div>
    <div class="words">
      <p class="eyebrow"><span id="howto-n">1</span> of 4</p>
      <p class="cap" data-n="1">Tap the power button to toggle on and off</p>
      <p class="cap" data-n="2">Turn the phone to move the cursor</p>
      <p class="cap" data-n="3">Hold the power button to recenter the cursor</p>
      <p class="cap" data-n="4">Use like a normal<br>mouse</p>
      <div class="nav">
        <button class="arrow prev" id="howto-prev" aria-label="Back">"""
               + _CHEVRON.format(d="M7 2 L3 8 L7 14") + """</button>
        <button class="arrow next" id="howto-next" aria-label="Next">"""
               + _CHEVRON.format(d="M3 2 L7 8 L3 14") + """</button>
      </div>
    </div>
  </div>
</div>

""")

HOWTO_SCRIPT = """// How to use: four steps, moved by the arrows and by nothing else. The script
// sets data-step on the card and switches Back off on the first step, so a
// fresh card cannot be stepped back from 1 to 4; which stage and words show,
// and how the arrows move, is howto.css's business.
const howto = document.getElementById("howto");
const prev = document.getElementById("howto-prev");
let step = 1;
function goStep(k) {
  step = ((k - 1 + 4) % 4) + 1;
  howto.dataset.step = String(step);
  document.getElementById("howto-n").textContent = String(step);
  prev.disabled = step === 1;
}
prev.onclick = () => goStep(step - 1);
document.getElementById("howto-next").onclick = () => goStep(step + 1);
goStep(1);

"""
