"""dotmatrix_pdf.py — render captured printer text as an 820-style PDF.

Recreates the *printer's* character generator (the Atari only ever sent ATASCII;
the font lived in the printer ROM): a 5x7 dot matrix, round ink dots, 40 columns,
in the spirit of the Atari 820. Pure stdlib — the PDF is hand-written vector
content (each dot = a zero-length round-capped stroke), no font embedding.

    from dotmatrix_pdf import text_to_pdf
    text_to_pdf(text, "out.pdf")            # cols=40 (820) or 80 (825-ish)
"""

# 5x7 glyphs, 7 rows top->bottom, 5 bits each (bit4 = leftmost column).
# Classic dot-matrix designs (original renderings, HD44780-style conventions).
_G = {
 ' ': (0,0,0,0,0,0,0),          '!': (4,4,4,4,4,0,4),
 '"': (10,10,10,0,0,0,0),       '#': (10,10,31,10,31,10,10),
 '$': (4,15,20,14,5,30,4),      '%': (24,25,2,4,8,19,3),
 '&': (12,18,20,8,21,18,13),    "'": (4,4,8,0,0,0,0),
 '(': (2,4,8,8,8,4,2),          ')': (8,4,2,2,2,4,8),
 '*': (0,4,21,14,21,4,0),       '+': (0,4,4,31,4,4,0),
 ',': (0,0,0,0,12,4,8),         '-': (0,0,0,31,0,0,0),
 '.': (0,0,0,0,0,12,12),        '/': (0,1,2,4,8,16,0),
 '0': (14,17,19,21,25,17,14),   '1': (4,12,4,4,4,4,14),
 '2': (14,17,1,2,4,8,31),       '3': (31,2,4,2,1,17,14),
 '4': (2,6,10,18,31,2,2),       '5': (31,16,30,1,1,17,14),
 '6': (6,8,16,30,17,17,14),     '7': (31,1,2,4,8,8,8),
 '8': (14,17,17,14,17,17,14),   '9': (14,17,17,15,1,2,12),
 ':': (0,12,12,0,12,12,0),      ';': (0,12,12,0,12,4,8),
 '<': (2,4,8,16,8,4,2),         '=': (0,0,31,0,31,0,0),
 '>': (8,4,2,1,2,4,8),          '?': (14,17,1,2,4,0,4),
 '@': (14,17,1,13,21,21,14),    'A': (14,17,17,17,31,17,17),
 'B': (30,17,17,30,17,17,30),   'C': (14,17,16,16,16,17,14),
 'D': (28,18,17,17,17,18,28),   'E': (31,16,16,30,16,16,31),
 'F': (31,16,16,30,16,16,16),   'G': (14,17,16,23,17,17,15),
 'H': (17,17,17,31,17,17,17),   'I': (14,4,4,4,4,4,14),
 'J': (7,2,2,2,2,18,12),        'K': (17,18,20,24,20,18,17),
 'L': (16,16,16,16,16,16,31),   'M': (17,27,21,21,17,17,17),
 'N': (17,17,25,21,19,17,17),   'O': (14,17,17,17,17,17,14),
 'P': (30,17,17,30,16,16,16),   'Q': (14,17,17,17,21,18,13),
 'R': (30,17,17,30,20,18,17),   'S': (15,16,16,14,1,1,30),
 'T': (31,4,4,4,4,4,4),         'U': (17,17,17,17,17,17,14),
 'V': (17,17,17,17,17,10,4),    'W': (17,17,17,21,21,21,10),
 'X': (17,17,10,4,10,17,17),    'Y': (17,17,17,10,4,4,4),
 'Z': (31,1,2,4,8,16,31),       '[': (14,8,8,8,8,8,14),
 '\\': (0,16,8,4,2,1,0),        ']': (14,2,2,2,2,2,14),
 '^': (4,10,17,0,0,0,0),        '_': (0,0,0,0,0,0,31),
 '`': (8,4,2,0,0,0,0),          'a': (0,0,14,1,15,17,15),
 'b': (16,16,30,17,17,17,30),   'c': (0,0,14,16,16,17,14),
 'd': (1,1,15,17,17,17,15),     'e': (0,0,14,17,31,16,14),
 'f': (6,9,8,28,8,8,8),         'g': (0,15,17,17,15,1,14),
 'h': (16,16,22,25,17,17,17),   'i': (4,0,12,4,4,4,14),
 'j': (2,0,6,2,2,18,12),        'k': (16,16,18,20,24,20,18),
 'l': (12,4,4,4,4,4,14),        'm': (0,0,26,21,21,21,21),
 'n': (0,0,22,25,17,17,17),     'o': (0,0,14,17,17,17,14),
 'p': (0,0,30,17,30,16,16),     'q': (0,0,15,17,15,1,1),
 'r': (0,0,22,25,16,16,16),     's': (0,0,14,16,14,1,30),
 't': (8,8,28,8,8,9,6),         'u': (0,0,17,17,17,19,13),
 'v': (0,0,17,17,17,10,4),      'w': (0,0,17,17,21,21,10),
 'x': (0,0,17,10,4,10,17),      'y': (0,0,17,17,15,1,14),
 'z': (0,0,31,2,4,8,31),        '{': (2,4,4,8,4,4,2),
 '|': (4,4,4,4,4,4,4),          '}': (8,4,4,2,4,4,8),
 '~': (0,0,8,21,2,0,0),
}


def _esc(b):
    return b


def text_to_pdf(text, path, cols=None, page=(612, 792), margin=54, ink=0.15):
    """Render text (already ASCII) to `path`.

    cols=None auto-sizes: word processors (AtariWriter) emit their own left
    margin as spaces and format for 80-column printers — the common leading-
    space margin is stripped (the sheet margin here replaces it) and the
    column count picks 40 (820-style) or 80 (825-style) to fit the content."""
    pw, ph = page

    # normalize + de-margin
    lines = [l.rstrip() for l in text.replace("\r\n", "\n").split("\n")]
    while lines and lines[-1] == "":
        lines.pop()
    nonblank = [l for l in lines if l.strip()]
    if nonblank:
        indent = min(len(l) - len(l.lstrip(" ")) for l in nonblank)
        if indent:
            lines = [l[indent:] if l.strip() else "" for l in lines]
    maxlen = max((len(l) for l in lines), default=1)
    if cols is None:
        # fit the longest line to the full printable width (font as large as
        # the content allows); 40-col floor keeps short notes from ballooning
        cols = max(40, maxlen)

    cell_w = (pw - 2 * margin) / cols          # char cell width in points
    pitch = cell_w / 6.0                       # dot pitch (5 cols + 1 gap)
    dot = pitch * 0.92                         # dot diameter
    cell_h = pitch * 9                         # 7 rows + 2 leading
    lines_pp = int((ph - 2 * margin) // cell_h)

    # wrap anything still longer than the chosen width
    wrapped = []
    for raw in lines:
        if raw == "":
            wrapped.append("")
        while raw:
            wrapped.append(raw[:cols])
            raw = raw[cols:]
    lines = wrapped or [""]

    pages = [lines[i:i + lines_pp] for i in range(0, len(lines), lines_pp)]

    def page_stream(pl):
        ops = [f"{ink:.2f} {ink:.2f} {ink:.2f} RG", "1 J", f"{dot:.2f} w"]
        y0 = ph - margin - pitch * 7
        for row, line in enumerate(pl):
            base_y = y0 - row * cell_h
            for col, ch in enumerate(line):
                glyph = _G.get(ch)
                if not glyph:
                    continue
                x0 = margin + col * cell_w
                for gy, bits in enumerate(glyph):
                    if not bits:
                        continue
                    y = base_y + (6 - gy) * pitch
                    for gx in range(5):
                        if bits & (16 >> gx):
                            x = x0 + gx * pitch
                            ops.append(f"{x:.1f} {y:.1f} m {x:.1f} {y:.1f} l S")
        return "\n".join(ops).encode("latin1")

    # minimal PDF
    objs = []                                   # (bytes) 1-indexed
    kids = []
    streams = [page_stream(p) for p in pages]
    n_fixed = 2                                 # catalog, pages
    for i, st in enumerate(streams):
        page_id = n_fixed + 1 + i * 2
        cont_id = page_id + 1
        kids.append(f"{page_id} 0 R")
        objs.append((page_id,
                     f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {pw} {ph}] "
                     f"/Contents {cont_id} 0 R >>".encode()))
        objs.append((cont_id,
                     b"<< /Length " + str(len(st)).encode() + b" >>\nstream\n" +
                     st + b"\nendstream"))
    objs.insert(0, (2, ("<< /Type /Pages /Kids [" + " ".join(kids) +
                        f"] /Count {len(pages)} >>").encode()))
    objs.insert(0, (1, b"<< /Type /Catalog /Pages 2 0 R >>"))

    out = bytearray(b"%PDF-1.4\n")
    xref = {}
    for oid, body in objs:
        xref[oid] = len(out)
        out += f"{oid} 0 obj\n".encode() + body + b"\nendobj\n"
    xref_pos = len(out)
    maxid = max(xref) + 1
    out += f"xref\n0 {maxid}\n".encode()
    out += b"0000000000 65535 f \n"
    for i in range(1, maxid):
        out += f"{xref[i]:010d} 00000 n \n".encode()
    out += (f"trailer\n<< /Size {maxid} /Root 1 0 R >>\n"
            f"startxref\n{xref_pos}\n%%EOF\n").encode()
    open(path, "wb").write(bytes(out))
    return len(pages)
