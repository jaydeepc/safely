#!/usr/bin/env python3
"""Builds docs/Shhlock-Guide.pdf — the illustrated "how it works and how to test it" guide.

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
OUT = ROOT / "docs" / "Shhlock-Guide.pdf"
FONTS = Path("/System/Library/Fonts/Supplemental")

pdfmetrics.registerFont(TTFont("Body", str(FONTS / "Arial.ttf")))
pdfmetrics.registerFont(TTFont("Body-Bold", str(FONTS / "Arial Bold.ttf")))
pdfmetrics.registerFont(TTFont("Display", str(FONTS / "Arial Rounded Bold.ttf")))
pdfmetrics.registerFont(TTFont("Mono", str(FONTS / "Courier New Bold.ttf")))
pdfmetrics.registerFontFamily("Body", normal="Body", bold="Body-Bold", italic="Body", boldItalic="Body-Bold")

INK, MUTED, LINE = HexColor("#101828"), HexColor("#667085"), HexColor("#E4E7EC")
INDIGO, DEEP, MINT = HexColor("#2F6BFF"), HexColor("#1D4ED8"), HexColor("#5B8DFF")  # primary, deep, gradient end
GRAPE, SKY = HexColor("#0F1B3D"), HexColor("#0EA5A4")
CANVAS, SOFT, GREEN, AMBER, ROSE = HexColor("#F5F7FB"), HexColor("#EEF3FF"), HexColor("#12B76A"), HexColor("#B45309"), HexColor("#E5484D")

W, H = A4
M = 44  # page margin

BODY = ParagraphStyle("body", fontName="Body", fontSize=10, leading=14.5, textColor=HexColor("#344054"))
SMALL = ParagraphStyle("small", parent=BODY, fontSize=8.6, leading=12, textColor=MUTED)
CENTER = ParagraphStyle("center", parent=SMALL, alignment=TA_CENTER)
LEAD = ParagraphStyle("lead", parent=BODY, fontSize=12, leading=17.5, textColor=HexColor("#475467"))
CODE = ParagraphStyle("code", fontName="Mono", fontSize=8.8, leading=12.5, textColor=HexColor("#E4E7EC"))


class Page:
    def __init__(self, c, number, title=None, kicker=None):
        self.c = c
        c.setFillColor(CANVAS)
        c.rect(0, 0, W, H, stroke=0, fill=1)
        for x, y, r, col in ((40, H - 30, 190, "#DCE6FF"), (W - 30, H - 260, 170, "#E3F6F5"), (W * 0.45, -40, 180, "#E8EDF7")):
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
        c.drawString(M, 24, "Shhlock · how it works and how to test it")
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
                c.setFillColor(Color(0.06, 0.11, 0.24, alpha=0.012))
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
        self.card(x, y - h, width, h, fill=HexColor("#0F1B3D"), radius=9, shadow=False)
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
    c.drawImage(ImageReader(str(ROOT / "design" / "app-icon.png")), M, H - M - 34, 34, 34, mask="auto")
    c.setFillColor(INK)
    c.setFont("Display", 17)
    c.drawString(M + 44, H - M - 23, "Shhlock")

    c.setFont("Display", 36)
    c.drawString(M, H - 150, "Your passwords,")
    c.drawString(M, H - 192, "on a key you carry.")
    c.setFillColor(INDIGO)
    c.drawString(M, H - 234, "Any browser. No phone")
    c.drawString(M, H - 276, "in hand. No cloud.")

    y = p.text("Shhlock is a small Bluetooth key (a Seeed Studio XIAO ESP32C3) that holds your logins, an iPhone app that manages "
               "them, and a menu-bar app for the Mac that fills them into any browser or app while the key is near. "
               "Walk away with the key and the computer has nothing.", M, H - 300, W - 2 * M - 40, LEAD)

    # three-part diagram
    y -= 22
    dh = 190
    p.card(M, y - dh, W - 2 * M, dh)
    nw, nh = 132, 92
    gap = (W - 2 * M - 40 - 3 * nw) / 2
    xs = [M + 20 + i * (nw + gap) for i in range(3)]
    ny = y - 30 - nh
    parts = [("iPhone", "Shhlock app", "loads and edits the vault,\napproves computers", False),
             ("Shhlock Key", "XIAO ESP32C3", "holds the encrypted vault,\nanswers paired devices", True),
             ("Mac", "Shhlock for Mac", "fills any browser or app\nthrough Accessibility", False)]
    for i, (a, b, d, strong) in enumerate(parts):
        if strong:
            gradient_box(c, xs[i], ny, nw, nh)
            fg, sub = white, Color(1, 1, 1, alpha=0.8)
        else:
            c.setFillColor(SOFT)
            c.roundRect(xs[i], ny, nw, nh, 12, stroke=0, fill=1)
            fg, sub = INK, MUTED
        c.setFillColor(fg)
        c.setFont("Display", 13)
        c.drawCentredString(xs[i] + nw / 2, ny + nh - 26, a)
        c.setFillColor(sub)
        c.setFont("Mono", 8)
        c.drawCentredString(xs[i] + nw / 2, ny + nh - 42, b)
        c.setFillColor(MUTED)
        c.setFont("Body", 8.2)
        for k, line in enumerate(d.split("\n")):
            c.drawCentredString(xs[i] + nw / 2, ny + 24 - k * 11, line)
    for i, label in enumerate(("manages · syncs", "fills")):
        x1, x2 = xs[i] + nw + 6, xs[i + 1] - 6
        arrow(c, x1, ny + nh / 2 + 6, x2, ny + nh / 2 + 6)
        arrow(c, x2, ny + nh / 2 - 6, x1, ny + nh / 2 - 6, color=SKY)
        c.setFillColor(MUTED)
        c.setFont("Body", 7.5)
        c.drawCentredString((x1 + x2) / 2, ny + nh / 2 + 14, label)
    c.setFillColor(DEEP)
    c.setFont("Body-Bold", 8.5)
    c.drawCentredString(W / 2, y - dh + 12, "every message sealed end-to-end · P-256 + AES-256-GCM · the key opens only for devices you paired")
    y -= dh + 20

    col = (W - 2 * M - 24) / 3
    blocks = [
        ("Set up once", "Pair the phone by pressing the key's button. Import your Chrome or Safari passwords. Approve your Mac with a six-digit code."),
        ("Then just sign in", "Open a login page. One matching login fills itself; several show a short list under the field to click."),
        ("Walk away", "Bluetooth reaches a few metres. Take the key, and the Mac can fill nothing — it never stored a password."),
    ]
    for i, (title, body) in enumerate(blocks):
        x = M + i * (col + 12)
        p.card(x, y - 108, col, 108)
        p.badge(x + 14, y - 14, str(i + 1))
        p.heading(title, x + 42, y - 13, 12.5)
        p.text(body, x + 14, y - 44, col - 28, SMALL)
    p.text("<b>This guide:</b> &nbsp;2 · How it works &nbsp;&nbsp; 3 · Why it is safe &nbsp;&nbsp; 4 · Set it up &nbsp;&nbsp; 5 · Test it, ship it, fix it",
           M, y - 124, W - 2 * M, SMALL)
    c.showPage()


# ───────────────────────────── page 2 · how it works ─────────────────────────────

def how_it_works(c):
    p = Page(c, 2, "How it works", "The key is the vault; the Mac only borrows")
    y = p.text("The phone is needed once, to set things up. Afterwards the key and the Mac work on their own.",
               M, p.y, W - 2 * M, LEAD) - 14

    left = (W - 2 * M) * 0.58
    y0 = p.heading("When you open a login page on the Mac", M, y)
    steps = [
        ("Shhlock for Mac notices the field.", "Through macOS Accessibility it sees that a password or e-mail field has focus, in any app."),
        ("It reads the page's address.", "From the browser's web area: https://github.com. A page cannot lie about it."),
        ("It asks the key.", "A sealed request over Bluetooth: “logins for github.com?” The key matches by domain and answers, sealed."),
        ("It fills — or asks you.", "One match fills at once. Several show a small list under the field; click one. Cmd-Shift-F fills on demand."),
        ("Nothing stays behind.", "The Mac keeps only its pairing. Passwords exist in its memory for the moment of filling."),
    ]
    yy = y0 - 4
    for i, (title, body) in enumerate(steps):
        p.badge(M, yy, str(i + 1), r=8.5)
        yy = p.text(f"<b><font color='#101828'>{title}</font></b> {body}", M + 25, yy + 1, left - 40, BODY) - 8

    rx = M + left + 6
    rw = W - M - rx
    iy = p.image("key.jpg", rx, y0 + 8, rw, radius=14)
    p.card(rx, iy - 12 - 110, rw, 110, fill=SOFT, shadow=False)
    p.heading("Why not Bluetooth alone?", rx + 12, iy - 22, 11.5, DEEP)
    p.text("A Bluetooth device can only type into a computer, like a keyboard. It cannot see which site is open or draw a "
           "list to pick from. Something on the computer must do that — and a menu-bar app that works in every browser is "
           "lighter than an extension per browser.", rx + 12, iy - 45, rw - 24, SMALL)

    y = min(yy, iy - 134) - 16
    p.heading("What the phone does", M, y)
    y -= 28
    col = (W - 2 * M - 24) / 3
    extras = [
        ("Loads the vault", "Import your Chrome or Safari export, add logins by hand, edit and delete. Every change syncs to the key while it is in reach."),
        ("Approves computers", "A new Mac shows a six-digit code; the phone shows the same one. Tap “Same code” and the Mac may use the key from then on."),
        ("Keeps a copy", "The phone holds its own encrypted copy. Lose the key: reset a new one, pair, and the vault is back in a minute."),
    ]
    for i, (title, body) in enumerate(extras):
        x = M + i * (col + 12)
        p.card(x, y - 118, col, 118)
        gradient_box(c, x + 14, y - 20, 26, 5, 2.5)
        p.heading(title, x + 14, y - 30, 11.5)
        p.text(body, x + 14, y - 52, col - 28, SMALL)
    c.showPage()


# ───────────────────────────── page 3 · security ─────────────────────────────

def security(c):
    p = Page(c, 3, "Why it is safe", "Lose the key, and it is a blank")
    y = p.text("The vault sits on a device you could drop in the street. The design assumes that will happen.",
               M, p.y, W - 2 * M, LEAD) - 16

    dh = 246
    p.card(M, y - dh, W - 2 * M, dh)
    p.heading("Approving a computer: a code that cannot be faked", M + 16, y - 14, 12.5)
    bx, kx, px = M + 90, W / 2, W - M - 90
    top, bottom = y - 60, y - dh + 16
    for x, name in ((bx, "Mac"), (kx, "Key"), (px, "Phone")):
        gradient_box(c, x - 34, top, 68, 22, 8)
        c.setFillColor(white)
        c.setFont("Body-Bold", 9.5)
        c.drawCentredString(x, top + 7, name)
        c.setStrokeColor(LINE)
        c.setLineWidth(1.4)
        c.line(x, top, x, bottom)
    my = top - 22
    rows = [
        (bx, kx, "pair_commit", "a fingerprint of the Mac's new key"),
        (kx, bx, "pair_pub", "the key's public key"),
        (bx, kx, "pair_reveal", "the Mac's real key — checked against the fingerprint"),
        (kx, px, "approve (sealed)", "the six-digit code, to the phone"),
        (px, kx, "approve_reply (sealed)", "“same code” — tapped by you"),
        (kx, bx, "pair_confirm (sealed)", "the Mac is in"),
    ]
    for x1, x2, name, note in rows:
        arrow(c, x1 + 3 if x2 > x1 else x1 - 3, my, x2 - 3 if x2 > x1 else x2 + 3, my, color=INDIGO if x2 > x1 else SKY)
        c.setFillColor(INK)
        c.setFont("Mono", 8.4)
        c.drawCentredString((x1 + x2) / 2, my + 5, name)
        c.setFillColor(MUTED)
        c.setFont("Body", 7.8)
        c.drawCentredString((x1 + x2) / 2, my - 10, note)
        my -= 30
    y -= dh + 8
    y = p.text("The Mac commits to its key before it learns the key's, so nobody in between can grind for a matching code. "
               "The phone pairs differently: it must press the physical button on the key.", M + 4, y - 4, W - 2 * M - 8, SMALL) - 16

    p.heading("Who holds what", M, y, 12.5)
    y -= 26
    rows = [
        ("Shhlock Key", "The vault, AES-256-GCM. The vault key exists only in RAM after a paired device unlocks it.", "The vault key in the clear. Stolen alone, it is unreadable.", GREEN),
        ("Mac", "Its pairing: a session key and a 32-byte unlock secret, in the login keychain.", "No vault. Passwords only in memory while filling.", GREEN),
        ("iPhone", "Its own encrypted copy, Face ID locked, key in the Keychain (this device only).", "Never in iCloud, never in a backup.", INDIGO),
        ("Chrome extension", "Optional. Same pairing scheme as the Mac app.", "Nothing on disk beyond its pairing.", GREEN),
    ]
    cw = [100, 226, W - 2 * M - 100 - 226]
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
    p.card(M, y - 118, col, 118, fill=SOFT, shadow=False)
    p.heading("Also built in", M + 12, y - 10, 11, DEEP)
    p.text("• A rising counter in every message: recorded traffic cannot be replayed.<br/>• Logins are matched by registrable domain; "
           "<font name='Mono' size='8'>evil.github.io</font> never sees <font name='Mono' size='8'>you.github.io</font>.<br/>"
           "• 40 requests a minute per device.<br/>• Hold the key's button 8 s: factory reset.",
           M + 12, y - 32, col - 24, SMALL)
    p.card(M + col + 12, y - 118, col, 118, fill=HexColor("#FFFBEB"), shadow=False)
    p.heading("Honest limits of version 2", M + col + 24, y - 10, 11, AMBER)
    p.text("• No forward secrecy between a device and the key.<br/>• The ESP32's flash is not encrypted: an attacker with the key "
           "<i>and</i> a paired Mac's keychain could read the vault.<br/>• No cloud copy by design — use Settings → Export a backup.",
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

    y = step(1, "Flash and power the key", y)
    y = p.text("Plug the XIAO ESP32C3 into the Mac once to flash it. Afterwards any USB power will do — a battery in your bag.", M + 28, y, left - 28) - 6
    y = p.code(["firmware/flash.sh"], M + 28, y, left - 28) - 14

    y = step(2, "Pair your phone with the key", y)
    y = p.text("Install Shhlock from TestFlight. <b>Key → Pair this phone with the key</b>, then press the small button on the "
               "XIAO board when the app asks. That press is what proves the key is yours.", M + 28, y, left - 28) - 14

    y = step(3, "Load your passwords", y)
    y = p.text("Chrome: <font name='Mono' size='8.6'>chrome://password-manager/settings</font> → <b>Export passwords</b>. Safari: File → Export → Passwords. "
               "AirDrop the .csv to the phone, then <b>Settings → Import from Chrome or Safari</b>. The vault syncs to the key on its own. "
               "Delete the .csv afterwards — it is plain text.", M + 28, y, left - 28) - 14

    y = step(4, "Install Shhlock for Mac", y)
    y = p.code(["scripts/install-mac-app.sh"], M + 28, y, left - 28) - 7
    y = p.text("Allow Bluetooth when asked. From the padlock in the menu bar choose <b>Set up Shhlock…</b> and allow Accessibility "
               "(System Settings opens; switch Shhlock on).", M + 28, y, left - 28) - 14

    y = step(5, "Approve the Mac", y)
    y = p.text("With the phone app open, click <b>Pair with my key</b> on the Mac. Both show six digits. Tap <b>Same code</b> on the phone, "
               "click <b>Same code</b> on the Mac. Done — the phone can go back in your pocket.", M + 28, y, left - 28) - 8
    p.card(M + 28, y - 46, left - 28, 46, fill=HexColor("#FFFBEB"), shadow=False)
    p.text("<b><font color='#B45309'>Nothing is deleted from Chrome.</font></b> Turn off Chrome's own “offer to save passwords” so only Shhlock asks.",
           M + 28 + 12, y - 9, left - 52, SMALL)

    iy = p.image("ios-key.jpg", rx, p.y + 4, rw * 0.62, radius=12)
    p.text("The Key tab after pairing and syncing.", rx, iy - 5, rw, CENTER)
    c.showPage()


# ───────────────────────────── page 5 · test, ship, fix ─────────────────────────────

def test_and_ship(c):
    p = Page(c, 5, "Test it, ship it, fix it", "From first fill to TestFlight")
    y = p.y
    shots = [("ios-onboarding.jpg", "Welcome"), ("ios-vault.jpg", "Vault"), ("ios-key.jpg", "Key"), ("ios-approve.jpg", "Approving a Mac"), ("ios-lock.jpg", "Locked")]
    sh = 190
    sw = sh * 603 / 1311
    gap = (W - 2 * M - sw * len(shots)) / (len(shots) - 1)
    x = M
    for name, label in shots:
        p.image(name, x, y, sw, radius=11)
        p.text(label, x, y - sh - 5, sw, CENTER)
        x += sw + gap
    y -= sh + 30

    col = (W - 2 * M - 14) / 2
    ly = p.heading("Try it", M, y, 12.5)
    tests = [
        ("First fill.", "Open a site you imported. The fields fill and the padlock in the menu bar shows “Ready · N logins on your key”."),
        ("Several logins.", "On a site with two accounts a list appears under the field. Click one."),
        ("Walk away.", "Take the key out of the room. The menu says “Looking for your Shhlock Key”; nothing fills. Come back: ready again within seconds."),
        ("Without the phone.", "Switch the phone off. Filling on the Mac keeps working — the vault is on the key."),
        ("Remove a computer.", "On the phone, Key → ✕ next to the Mac. The Mac gets no answers until approved again."),
    ]
    for i, (title, body) in enumerate(tests):
        p.badge(M, ly, str(i + 1), r=8)
        ly = p.text(f"<b><font color='#101828'>{title}</font></b> {body}", M + 23, ly + 1, col - 23, SMALL) - 7

    rx = M + col + 14
    ry = p.heading("Automated checks", rx, y, 12.5)
    ry = p.code(["cd core &amp;&amp; swift test", "firmware/flash.sh --test", "cd core &amp;&amp; swift run shhlock-keytest"], rx, ry, col) - 6
    ry = p.text("Unit tests · then the real key over USB: pairing, approval, a 123-login sync, matching, save, replay, reboot — 21 checks. "
                "Flash without <font name='Mono' size='8'>--test</font> afterwards.", rx, ry, col, SMALL) - 14

    ry = p.heading("TestFlight", rx, ry, 12.5)
    ry = p.text("Sign in under Xcode → Settings → Accounts; the app record in App Store Connect uses bundle ID "
                "<font name='Mono' size='8'>com.codecrackjd.safely</font>. Then:", rx, ry, col, SMALL) - 5
    ry = p.code(["scripts/testflight.sh --upload"], rx, ry, col) - 6

    y = min(ly, ry) - 12
    fixes = [
        ("Menu: “Needs Accessibility”", "System Settings → Privacy & Security → Accessibility → Shhlock on. Re-do after reinstalling."),
        ("“Looking for your Shhlock Key”", "Is it powered? System Settings → Privacy → Bluetooth → Shhlock on."),
        ("Pairing the Mac stalls", "The phone app must be open (it approves). Also check the phone shows “Connected and unlocked”."),
        ("Nothing fills on a site", "Is the login under that domain in the vault? Try Cmd-Shift-F. Some pages need the fallback typing, which takes a second."),
    ]
    p.card(M, y - 104, W - 2 * M, 104)
    p.heading("If something is off", M + 14, y - 10, 11.5)
    fw = (W - 2 * M - 28) / 2
    for i, (sym, fix) in enumerate(fixes):
        fx = M + 14 + (i % 2) * fw
        fy = y - 34 - (i // 2) * 32
        p.text(f"<b><font color='#101828'>{sym}</font></b> — {fix}", fx, fy, fw - 10, SMALL)
    p.text("Mac log: Set up Shhlock… → Activity log &nbsp;·&nbsp; Key log: <font name='Mono' size='8'>arduino-cli monitor -p /dev/cu.usbmodem1101 -c baudrate=115200</font> &nbsp;·&nbsp; Protocol: docs/PROTOCOL.md",
           M, y - 112, W - 2 * M, CENTER)
    c.showPage()


def main():
    c = canvas.Canvas(str(OUT), pagesize=A4)
    c.setTitle("Shhlock — how it works and how to test it")
    c.setAuthor("Shhlock")
    for page in (cover, how_it_works, security, setup, test_and_ship):
        page(c)
    c.save()
    print(OUT)


if __name__ == "__main__":
    main()
