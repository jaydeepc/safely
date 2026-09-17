#!/usr/bin/env python3
"""Builds docs/Safely-Guide.pdf — the illustrated "how it works and how to test it" guide.

    python3 scripts/make-guide.py        (needs: pip install reportlab pillow)
"""
from pathlib import Path

from reportlab.lib.colors import Color, HexColor, white
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas
from reportlab.platypus import Paragraph

ROOT = Path(__file__).resolve().parent.parent
IMG = ROOT / "docs" / "images"
OUT = ROOT / "docs" / "Safely-Guide.pdf"
FONTS = Path("/System/Library/Fonts/Supplemental")

pdfmetrics.registerFont(TTFont("Body", str(FONTS / "Arial.ttf")))
pdfmetrics.registerFont(TTFont("Body-Bold", str(FONTS / "Arial Bold.ttf")))
pdfmetrics.registerFont(TTFont("Display", str(FONTS / "Arial Rounded Bold.ttf")))
pdfmetrics.registerFont(TTFont("Mono", str(FONTS / "Courier New Bold.ttf")))
pdfmetrics.registerFontFamily("Body", normal="Body", bold="Body-Bold", italic="Body", boldItalic="Body-Bold")

INK, MUTED, LINE = HexColor("#0F172A"), HexColor("#64748B"), HexColor("#E2E8F0")
INDIGO, DEEP, MINT = HexColor("#6366F1"), HexColor("#4F46E5"), HexColor("#2DD4BF")
CANVAS, SOFT, GREEN, AMBER, ROSE = HexColor("#F6F7FD"), HexColor("#EEF2FF"), HexColor("#16A34A"), HexColor("#B45309"), HexColor("#E11D48")

W, H = A4
M = 44  # page margin

BODY = ParagraphStyle("body", fontName="Body", fontSize=10, leading=14.5, textColor=HexColor("#334155"))
SMALL = ParagraphStyle("small", parent=BODY, fontSize=8.6, leading=12, textColor=MUTED)
CENTER = ParagraphStyle("center", parent=SMALL, alignment=TA_CENTER)
LEAD = ParagraphStyle("lead", parent=BODY, fontSize=12, leading=17.5, textColor=HexColor("#475569"))
CODE = ParagraphStyle("code", fontName="Mono", fontSize=8.8, leading=12.5, textColor=HexColor("#E2E8F0"))


class Page:
    def __init__(self, c, number, title=None, kicker=None):
        self.c = c
        c.setFillColor(CANVAS)
        c.rect(0, 0, W, H, stroke=0, fill=1)
        for x, y, r, col in ((40, H - 30, 190, "#C7D2FE"), (W - 30, H - 260, 170, "#A7F3D0"), (W * 0.45, -40, 180, "#FBCFE8")):
            self.glow(x, y, r, HexColor(col))
        self.y = H - M
        if title:
            c.setFont("Body-Bold", 8.5)
            c.setFillColor(INDIGO)
            c.drawString(M, self.y - 4, kicker.upper())
            c.setFont("Display", 25)
            c.setFillColor(INK)
            c.drawString(M, self.y - 34, title)
            self.y -= 58
        c.setFont("Body", 8)
        c.setFillColor(MUTED)
        c.drawString(M, 24, "Safely · how it works and how to test it")
        c.drawRightString(W - M, 24, str(number))

    def glow(self, x, y, radius, color):
        c = self.c
        for i in range(26, 0, -1):
            c.setFillColor(Color(color.red, color.green, color.blue, alpha=0.028))
            c.circle(x, y, radius * i / 26, stroke=0, fill=1)

    def card(self, x, y, w, h, fill=white, radius=14, shadow=True):
        c = self.c
        if shadow:
            for i in range(6, 0, -1):
                c.setFillColor(Color(0.31, 0.27, 0.90, alpha=0.012))
                c.roundRect(x - i, y - i - 3, w + 2 * i, h + 2 * i, radius + i, stroke=0, fill=1)
        c.setFillColor(fill)
        c.roundRect(x, y, w, h, radius, stroke=0, fill=1)

    def text(self, html, x, y, width, style=BODY):
        """Draws a paragraph with its top at y; returns the y below it."""
        p = Paragraph(html, style)
        _, h = p.wrap(width, 2000)
        p.drawOn(self.c, x, y - h)
        return y - h

    def heading(self, text, x, y, size=13, color=INK):
        self.c.setFont("Display", size)
        self.c.setFillColor(color)
        self.c.drawString(x, y - size, text)
        return y - size - 7

    def image(self, name, x, y, width, radius=12, height=None, border=True):
        """Draws an image with its top-left at (x, y); returns the y below it."""
        img = ImageReader(str(IMG / name))
        iw, ih = img.getSize()
        h = height or width * ih / iw
        c = self.c
        c.saveState()
        path = c.beginPath()
        path.roundRect(x, y - h, width, h, radius)
        c.clipPath(path, stroke=0, fill=0)
        if height:  # cover-crop
            scale = max(width / iw, h / ih)
            dw, dh = iw * scale, ih * scale
            c.drawImage(img, x - (dw - width) / 2, y - h - (dh - h) / 2, dw, dh, mask="auto")
        else:
            c.drawImage(img, x, y - h, width, h, mask="auto")
        c.restoreState()
        if border:
            c.setStrokeColor(LINE)
            c.setLineWidth(0.8)
            c.roundRect(x, y - h, width, h, radius, stroke=1, fill=0)
        return y - h

    def badge(self, x, y, label, r=10, fill=INDIGO):
        c = self.c
        c.setFillColor(fill)
        c.circle(x + r, y - r, r, stroke=0, fill=1)
        c.setFillColor(white)
        c.setFont("Body-Bold", r)
        c.drawCentredString(x + r, y - r - r * 0.36, label)

    def code(self, lines, x, y, width):
        h = 12.5 * len(lines) + 14
        self.card(x, y - h, width, h, fill=INK, radius=9, shadow=False)
        self.text("<br/>".join(lines), x + 10, y - 7, width - 20, CODE)
        return y - h

    def pill(self, x, y, label, fill, color):
        c = self.c
        w = pdfmetrics.stringWidth(label, "Body-Bold", 8) + 16
        c.setFillColor(fill)
        c.roundRect(x, y - 15, w, 15, 7.5, stroke=0, fill=1)
        c.setFillColor(color)
        c.setFont("Body-Bold", 8)
        c.drawString(x + 8, y - 11, label)
        return x + w + 6


def gradient_box(c, x, y, w, h, radius=12):
    c.saveState()
    path = c.beginPath()
    path.roundRect(x, y, w, h, radius)
    c.clipPath(path, stroke=0, fill=0)
    c.linearGradient(x, y + h, x + w, y, (INDIGO, MINT))
    c.restoreState()


def arrow(c, x1, y1, x2, y2, color=INDIGO, dashed=False, width=1.6):
    import math
    c.setStrokeColor(color)
    c.setFillColor(color)
    c.setLineWidth(width)
    c.setDash(3, 3) if dashed else c.setDash()
    c.line(x1, y1, x2, y2)
    c.setDash()
    a = math.atan2(y2 - y1, x2 - x1)
    p = c.beginPath()
    p.moveTo(x2, y2)
    p.lineTo(x2 - 7 * math.cos(a - 0.4), y2 - 7 * math.sin(a - 0.4))
    p.lineTo(x2 - 7 * math.cos(a + 0.4), y2 - 7 * math.sin(a + 0.4))
    p.close()
    c.drawPath(p, stroke=0, fill=1)


# ───────────────────────────── page 1 · cover ─────────────────────────────

def cover(c):
    p = Page(c, 1)
    gradient_box(c, M, H - M - 30, 30, 30, 9)
    c.setFillColor(white)
    c.setFont("Display", 17)
    c.drawCentredString(M + 15, H - M - 21, "S")
    c.setFillColor(INK)
    c.setFont("Display", 17)
    c.drawString(M + 40, H - M - 21, "Safely")

    c.setFont("Display", 38)
    c.drawString(M, H - 150, "Your passwords live")
    c.drawString(M, H - 194, "on your phone.")
    c.setFillColor(INDIGO)
    c.drawString(M, H - 238, "A key in your pocket")
    c.drawString(M, H - 282, "does the rest.")

    y = p.text("Safely is a password vault on your iPhone, a thumbnail-sized Bluetooth key (a Seeed Studio XIAO ESP32C3), "
               "and a Chrome extension. Open a login page with the key and phone nearby and the form fills itself. "
               "Walk away, and the browser knows nothing — because it never stored anything.", M, H - 306, W - 2 * M - 60, LEAD)

    y = p.image("hero.jpg", M, y - 18, W - 2 * M, radius=18, height=236)

    col = (W - 2 * M - 24) / 3
    blocks = [
        ("The phone", "Holds every login in one AES-256 encrypted file. The key to it never leaves the iPhone. Light, animated SwiftUI app with Face ID, approvals and an activity log."),
        ("The key", "A BLE relay the size of a stamp. Phone and computer both connect to it. It forwards sealed messages, stores nothing and can read nothing."),
        ("The browser", "A Chrome extension spots login forms, asks the phone through the key, and fills. A tiny helper keeps the Bluetooth link alive and reconnects when you return."),
    ]
    top = y - 18
    for i, (title, body) in enumerate(blocks):
        x = M + i * (col + 12)
        p.card(x, top - 116, col, 116)
        p.badge(x + 14, top - 14, str(i + 1))
        p.heading(title, x + 42, top - 13, 12.5)
        p.text(body, x + 14, top - 44, col - 28, SMALL)

    p.text("<b>This guide:</b> &nbsp;2 · How it works &nbsp;&nbsp; 3 · Why it is safe &nbsp;&nbsp; 4 · Set it up &nbsp;&nbsp; 5 · Test it, ship it, fix it",
           M, top - 132, W - 2 * M, SMALL)
    c.showPage()


# ───────────────────────────── page 2 · how it works ─────────────────────────────

def how_it_works(c):
    p = Page(c, 2, "How it works", "One round trip, about a quarter of a second")
    y = p.text("Four pieces pass one sealed message along. Only the two ends — the extension and the phone — hold the key that opens it.",
               M, p.y, W - 2 * M, LEAD) - 16

    # architecture diagram
    dh = 150
    p.card(M, y - dh, W - 2 * M, dh)
    nodes = [("Chrome", "extension", "finds the form, fills it"), ("Helper", "safely-host", "keeps Bluetooth open"),
             ("Safely Key", "XIAO ESP32C3", "relays, reads nothing"), ("iPhone", "Safely app", "vault + decisions")]
    nw, nh = 82, 58
    gap = (W - 2 * M - 40 - 4 * nw) / 3
    ny = y - 44 - nh
    xs = [M + 20 + i * (nw + gap) for i in range(4)]
    for i, (a, b, d) in enumerate(nodes):
        if i in (0, 3):
            gradient_box(c, xs[i], ny, nw, nh)
            fg, sub = white, Color(1, 1, 1, alpha=0.85)
        else:
            c.setFillColor(SOFT)
            c.roundRect(xs[i], ny, nw, nh, 12, stroke=0, fill=1)
            fg, sub = INK, MUTED
        c.setFillColor(fg)
        c.setFont("Display", 12)
        c.drawCentredString(xs[i] + nw / 2, ny + nh - 24, a)
        c.setFillColor(sub)
        c.setFont("Mono", 8)
        c.drawCentredString(xs[i] + nw / 2, ny + nh - 40, b)
        c.setFillColor(MUTED)
        c.setFont("Body", 8)
        c.drawCentredString(xs[i] + nw / 2, ny - 13, d)
    links = [("native", "messaging"), ("Bluetooth", "Low Energy"), ("Bluetooth", "Low Energy")]
    for i, label in enumerate(links):
        x1, x2 = xs[i] + nw + 4, xs[i + 1] - 4
        arrow(c, x1, ny + nh / 2 + 7, x2, ny + nh / 2 + 7)
        arrow(c, x2, ny + nh / 2 - 7, x1, ny + nh / 2 - 7, color=MINT)
        c.setFillColor(MUTED)
        c.setFont("Body", 7)
        c.drawCentredString((x1 + x2) / 2, ny + nh / 2 + 24, label[0])
        c.drawCentredString((x1 + x2) / 2, ny + nh / 2 + 15, label[1])
    # the end-to-end bracket
    by = y - 22
    c.setStrokeColor(INDIGO)
    c.setLineWidth(1.2)
    c.setDash(2, 3)
    c.line(xs[0] + nw / 2, by, xs[3] + nw / 2, by)
    c.line(xs[0] + nw / 2, by, xs[0] + nw / 2, ny + nh + 3)
    c.line(xs[3] + nw / 2, by, xs[3] + nw / 2, ny + nh + 3)
    c.setDash()
    label = "end-to-end encrypted · ECDH P-256 + AES-256-GCM"
    lw = pdfmetrics.stringWidth(label, "Body-Bold", 8.5) + 16
    c.setFillColor(white)
    c.rect(W / 2 - lw / 2, by - 6, lw, 12, stroke=0, fill=1)
    c.setFillColor(DEEP)
    c.setFont("Body-Bold", 8.5)
    c.drawCentredString(W / 2, by - 3, label)
    y -= dh + 22

    # steps + picture
    left = (W - 2 * M) * 0.56
    y0 = p.heading("What happens when you open a login page", M, y)
    steps = [
        ("The extension sees a password field.", "It takes the site's address from Chrome itself — a page cannot lie about where it is."),
        ("It seals a request and hands it to the helper.", "“Logins for https://github.com, please.” Encrypted before it leaves the browser."),
        ("The key relays it to your phone.", "iOS wakes the app in the background over Bluetooth, even with the screen off."),
        ("The phone decides.", "It matches the domain against the vault, applies your rule (fill automatically, or ask with Face ID), logs it, and seals the reply."),
        ("The form fills.", "One match fills on its own; several show a small chooser. The password lives in page memory only."),
    ]
    yy = y0 - 4
    for i, (title, body) in enumerate(steps):
        p.badge(M, yy, str(i + 1), r=8.5)
        yy = p.text(f"<b><font color='#0F172A'>{title}</font></b> {body}", M + 25, yy + 1, left - 40, BODY) - 8

    rx = M + left + 6
    rw = W - M - rx
    iy = p.image("walk-away.jpg", rx, y0 + 8, rw, radius=14)
    p.card(rx, iy - 12 - 96, rw, 96, fill=SOFT, shadow=False)
    p.heading("Walk away and it stops", rx + 12, iy - 22, 11.5, DEEP)
    p.text("Bluetooth reaches a few metres. Take the key or the phone with you and the chain breaks; the extension holds "
           "no passwords to fall back on. Come back and both links reconnect by themselves — no tap needed.",
           rx + 12, iy - 45, rw - 24, SMALL)

    y = min(yy, iy - 108) - 18
    p.heading("Three things that make it feel seamless", M, y)
    y -= 28
    col = (W - 2 * M - 24) / 3
    extras = [
        ("It finds you", "Phone and computer each keep a standing Bluetooth request for the key. The moment it is in range again, both links come back — nothing to tap, no app to open."),
        ("It works while asleep", "iOS wakes Safely in the background when the key delivers a message, so the phone can stay locked in your pocket while the form fills."),
        ("It learns new logins", "Sign in somewhere by hand and the extension offers to save the login — to the phone, through the key. Chrome's own password manager is not involved."),
    ]
    for i, (title, body) in enumerate(extras):
        x = M + i * (col + 12)
        p.card(x, y - 118, col, 118)
        gradient_box(c, x + 14, y - 20, 26, 6, 3)
        p.heading(title, x + 14, y - 30, 11.5)
        p.text(body, x + 14, y - 52, col - 28, SMALL)
    c.showPage()


# ───────────────────────────── page 3 · security ─────────────────────────────

def security(c):
    p = Page(c, 3, "Why it is safe", "The key is a messenger, not a safe")
    y = p.text("The design assumes the worst about everything in the middle. The key, the helper and the radio link are all treated as hostile; "
               "they only ever carry sealed envelopes.", M, p.y, W - 2 * M, LEAD) - 16

    # pairing sequence
    dh = 250
    p.card(M, y - dh, W - 2 * M, dh)
    p.heading("Pairing: six digits that defeat a man in the middle", M + 16, y - 14, 12.5)
    bx, px = M + 110, W - M - 110
    top, bottom = y - 60, y - dh + 18
    for x, name in ((bx, "Browser"), (px, "Phone")):
        gradient_box(c, x - 42, top, 84, 22, 8)
        c.setFillColor(white)
        c.setFont("Body-Bold", 9.5)
        c.drawCentredString(x, top + 7, name)
        c.setStrokeColor(LINE)
        c.setLineWidth(1.4)
        c.line(x, top, x, bottom)
    msgs = [
        (True, "pair_commit", "a fingerprint of the browser's new key — locks its choice in"),
        (False, "pair_pub", "the phone's public key"),
        (True, "pair_reveal", "the browser's real key; the phone checks it against the fingerprint"),
        (None, "Both screens now show the same six digits. You compare them and confirm on both.", ""),
        (False, "pair_confirm (sealed)", "first encrypted message — proves both derived the same secret"),
    ]
    my = top - 24
    for right, name, note in msgs:
        if right is None:
            c.setFillColor(SOFT)
            c.roundRect(bx - 20, my - 12, px - bx + 40, 22, 11, stroke=0, fill=1)
            c.setFillColor(DEEP)
            c.setFont("Body-Bold", 8.8)
            c.drawCentredString((bx + px) / 2, my - 4.5, name)
            my -= 36
            continue
        arrow(c, bx + 3 if right else px - 3, my, px - 3 if right else bx + 3, my, color=INDIGO if right else MINT)
        c.setFillColor(INK)
        c.setFont("Mono", 8.8)
        c.drawCentredString((bx + px) / 2, my + 5, name)
        c.setFillColor(MUTED)
        c.setFont("Body", 8)
        c.drawCentredString((bx + px) / 2, my - 11, note)
        my -= 34
    y -= dh + 8
    y = p.text("Because the browser commits to its key <i>before</i> it sees the phone's key, an attacker sitting between them cannot shop for a key "
               "that makes the digits collide. They get one blind guess in a million — and you would see different codes.", M + 4, y - 4, W - 2 * M - 8, SMALL) - 16

    # who knows what
    p.heading("Who can see what", M, y, 12.5)
    y -= 26
    rows = [
        ("Chrome extension", "A non-extractable session key. Passwords only for the page you are on, only in memory.", "Nothing on disk. No vault.", GREEN),
        ("Bluetooth helper", "Sealed envelopes passing through.", "No keys. Cannot decrypt.", GREEN),
        ("Safely Key", "Sealed frames for a few milliseconds.", "No storage. Lose it: flash a new one for a few dollars.", GREEN),
        ("iPhone app", "Everything — that is its job.", "AES-256 file; key in the Keychain, this device only, never iCloud.", INDIGO),
    ]
    cw = [112, 214, W - 2 * M - 112 - 214]
    rh = 36
    p.card(M, y - rh * len(rows) - 22, W - 2 * M, rh * len(rows) + 22)
    c.setFont("Body-Bold", 8)
    c.setFillColor(MUTED)
    for i, head in enumerate(("PART", "WHAT IT HOLDS", "WHAT IT NEVER HAS")):
        c.drawString(M + 14 + sum(cw[:i]), y - 15, head)
    ry = y - 22
    for name, holds, never, color in rows:
        c.setStrokeColor(LINE)
        c.setLineWidth(0.6)
        c.line(M + 14, ry, W - M - 14, ry)
        c.setFillColor(color)
        c.circle(M + 18, ry - 17, 3, stroke=0, fill=1)
        c.setFillColor(INK)
        c.setFont("Body-Bold", 9.2)
        c.drawString(M + 26, ry - 20, name)
        p.text(holds, M + 14 + cw[0], ry - 7, cw[1] - 12, SMALL)
        p.text(never, M + 14 + cw[0] + cw[1], ry - 7, cw[2] - 26, SMALL)
        ry -= rh
    y = ry - 16

    col = (W - 2 * M - 12) / 2
    p.card(M, y - 128, col, 128, fill=SOFT, shadow=False)
    p.heading("Also built in", M + 12, y - 10, 11, DEEP)
    p.text("• A rising counter in every message — recorded traffic cannot be replayed.<br/>• Logins are matched by registrable domain; "
           "<font name='Mono' size='8'>evil.github.io</font> never sees <font name='Mono' size='8'>you.github.io</font>.<br/>"
           "• 40 requests a minute per browser, every fill in the Activity log.<br/>• Clipboard copies expire after 60 s and stay off Handoff.",
           M + 12, y - 32, col - 24, SMALL)
    p.card(M + col + 12, y - 128, col, 128, fill=HexColor("#FFFBEB"), shadow=False)
    p.heading("Honest limits of version 1", M + col + 24, y - 10, 11, AMBER)
    p.text("• “Fill automatically” treats proximity as consent. Choose “Ask me every time” for Face ID on each request.<br/>"
           "• No forward secrecy yet: a stolen browser profile plus recorded radio traffic could be decrypted.<br/>"
           "• No cloud copy by design — use Settings → Export a backup.",
           M + col + 24, y - 32, col - 24, SMALL)
    c.showPage()


# ───────────────────────────── page 4 · set up ─────────────────────────────

def setup(c):
    p = Page(c, 4, "Set it up", "About ten minutes, once")
    left = (W - 2 * M) * 0.60
    rx = M + left + 14
    rw = W - M - rx
    y = p.y

    def step(n, title, y):
        p.badge(M, y, str(n))
        p.heading(title, M + 28, y - 2, 12.5)
        return y - 26

    y = step(1, "Power the key", y)
    y = p.text("Your XIAO ESP32C3 is already flashed with the Safely firmware and advertising as <b>Safely Key</b>. Plug it into any USB "
               "power — a battery pack in your bag works. To re-flash after a code change:", M + 28, y, left - 28) - 6
    y = p.code(["firmware/flash.sh"], M + 28, y, left - 28) - 16

    y = step(2, "Install the helper and the extension", y)
    y = p.code(["scripts/install-host.sh"], M + 28, y, left - 28) - 7
    y = p.text("Then in Chrome open <font name='Mono' size='8.6'>chrome://extensions</font>, switch on <b>Developer mode</b>, click <b>Load unpacked</b> and choose the "
               "<font name='Mono' size='8.6'>extension/</font> folder. The setup page opens by itself. If macOS asks whether Chrome may use Bluetooth, allow it.",
               M + 28, y, left - 28) - 16

    y = step(3, "Put the app on your iPhone", y)
    y = p.text("Open <font name='Mono' size='8.6'>ios/Safely.xcodeproj</font>, pick your iPhone, press Run — or install it from TestFlight (next page). "
               "Swipe through the welcome screens and allow Bluetooth. The Devices tab shows the key lighting up.", M + 28, y, left - 28) - 16

    y = step(4, "Pair", y)
    y = p.text("Phone: <b>Devices → Pair a browser</b>. Chrome: <b>Start pairing</b>. Both show six digits. If they are the same, confirm on both. "
               "That is the only time you compare anything.", M + 28, y, left - 28) - 16

    y = step(5, "Bring your passwords over", y)
    y = p.text("Chrome: <font name='Mono' size='8.6'>chrome://password-manager/settings</font> → <b>Export passwords</b>. "
               "Safari: File → Export → Passwords. Click the Safely icon → <b>Import passwords</b> and drop the file in. It is encrypted in the browser and "
               "travels through the key to the phone — 250 logins take well under a minute.", M + 28, y, left - 28) - 8
    p.card(M + 28, y - 50, left - 28, 50, fill=HexColor("#FFFBEB"), shadow=False)
    p.text("<b><font color='#B45309'>Nothing is deleted from Chrome.</font></b> Delete the .csv afterwards (it is plain text), and clear Chrome's saved "
           "passwords yourself once you trust Safely.", M + 40, y - 9, left - 52, SMALL)

    iy = p.image("key.jpg", rx, p.y + 4, rw, radius=14)
    iy = p.text("The key: a XIAO ESP32C3 on USB power.", rx, iy - 5, rw, CENTER) - 14
    iy = p.image("ext-pair.jpg", rx, iy, rw, radius=10)
    iy = p.text("The extension's setup page during pairing.", rx, iy - 5, rw, CENTER) - 14
    iy = p.image("ext-import.jpg", rx, iy, rw, radius=10)
    p.text("Import: drop the exported .csv.", rx, iy - 5, rw, CENTER)
    c.showPage()


# ───────────────────────────── page 5 · test, ship, fix ─────────────────────────────

def test_and_ship(c):
    p = Page(c, 5, "Test it, ship it, fix it", "From first fill to TestFlight")
    y = p.y
    shots = [("ios-vault.jpg", "Vault", 603 / 1311), ("ios-devices.jpg", "Devices", 603 / 1311),
             ("ios-activity.jpg", "Activity", 603 / 1311), ("ext-popup.jpg", "Chrome popup", 350 / 560)]
    sh = 205
    widths = [sh * ratio for _, _, ratio in shots]
    gap = (W - 2 * M - sum(widths)) / (len(shots) - 1)
    x = M
    for (name, label, _), sw in zip(shots, widths):
        p.image(name, x, y, sw, radius=11)
        p.text(label, x, y - sh - 5, sw, CENTER)
        x += sw + gap
    y -= sh + 30

    col = (W - 2 * M - 14) / 2
    ly = p.heading("Try it", M, y, 12.5)
    tests = [
        ("First fill.", "Run <font name='Mono' size='8'>scripts/serve-test-page.sh</font>, add a login for <font name='Mono' size='8'>http://localhost:8765</font> in the app, open the page. The fields glow and fill."),
        ("Walk away.", "Carry the key out of the room. The popup turns to “Looking for key”; a reload fills nothing. Come back: “Ready” within seconds."),
        ("Ask every time.", "Settings → “Ask me every time”. Reload: the phone asks, Face ID approves. Try Deny as well."),
        ("Save a new login.", "Type a login by hand on a site Safely does not know. A “Save this login to Safely?” card appears."),
        ("Fill inside iPhone apps.", "iOS Settings → General → AutoFill &amp; Passwords → turn on Safely. Any app's login now offers your vault."),
    ]
    for i, (title, body) in enumerate(tests):
        p.badge(M, ly, str(i + 1), r=8)
        ly = p.text(f"<b><font color='#0F172A'>{title}</font></b> {body}", M + 23, ly + 1, col - 23, SMALL) - 7

    rx = M + col + 14
    ry = p.heading("No iPhone at hand?", rx, y, 12.5)
    ry = p.text("A simulator runs the phone's exact protocol code on the Mac with four demo logins:", rx, ry, col, SMALL) - 5
    ry = p.code(["cd core &amp;&amp; swift build", ".build/debug/safely-simphone"], rx, ry, col) - 14

    ry = p.heading("Automated checks", rx, ry, 12.5)
    ry = p.code(["cd core &amp;&amp; swift test", "node scripts/protocol-test.mjs", "node scripts/ble-e2e-test.mjs"], rx, ry, col) - 6
    ry = p.text("Unit tests · extension JavaScript against phone Swift · the whole chain over real Bluetooth.", rx, ry, col, SMALL) - 14

    ry = p.heading("TestFlight", rx, ry, 12.5)
    ry = p.text("Once: sign in under Xcode → Settings → Accounts, and create the app in App Store Connect with bundle ID "
                "<font name='Mono' size='8'>com.codecrackjd.safely</font>. Then:", rx, ry, col, SMALL) - 5
    ry = p.code(["scripts/testflight.sh --upload"], rx, ry, col) - 6
    ry = p.text("Without <font name='Mono' size='8'>--upload</font> it writes <font name='Mono' size='8'>build/export/Safely.ipa</font> for the Transporter app.", rx, ry, col, SMALL)

    y = min(ly, ry) - 12
    fixes = [
        ("“Helper missing”", "Run scripts/install-host.sh, then reload the extension."),
        ("“Looking for key”", "Is the key powered? System Settings → Privacy → Bluetooth → Chrome on."),
        ("“Phone away”", "Open Safely once on the phone; iOS then keeps the link in the background."),
        ("Nothing fills", "Does the site's address in the vault match? Check the phone's Activity tab."),
    ]
    p.card(M, y - 98, W - 2 * M, 98)
    p.heading("If something is off", M + 14, y - 10, 11.5)
    fw = (W - 2 * M - 28) / 2
    for i, (sym, fix) in enumerate(fixes):
        fx = M + 14 + (i % 2) * fw
        fy = y - 34 - (i // 2) * 30
        p.text(f"<b><font color='#0F172A'>{sym}</font></b> — {fix}", fx, fy, fw - 10, SMALL)
    p.text("Helper log: <font name='Mono' size='8'>~/Library/Logs/Safely/host.log</font> &nbsp;·&nbsp; Key log: "
           "<font name='Mono' size='8'>arduino-cli monitor -p /dev/cu.usbmodem1101 -c baudrate=115200</font> &nbsp;·&nbsp; Protocol: docs/PROTOCOL.md",
           M, y - 106, W - 2 * M, CENTER)
    c.showPage()


def main():
    c = canvas.Canvas(str(OUT), pagesize=A4)
    c.setTitle("Safely — how it works and how to test it")
    c.setAuthor("Safely")
    for page in (cover, how_it_works, security, setup, test_and_ship):
        page(c)
    c.save()
    print(OUT)


if __name__ == "__main__":
    main()
