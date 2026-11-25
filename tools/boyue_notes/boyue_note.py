#!/usr/bin/env python3
"""
Décodeur des notes manuscrites du lecteur Boyue (Likebook K78W, firmware V3.1.1, lecteur V2.1.6).

Emplacement sur la liseuse (stockage partagé, sans root) :
  /sdcard/Android/data/com.boyue.app.byreader/HandwritingNote/<nom du PDF>/handwriting<taille du PDF>_<n>.note

Format (rétro-ingénierie du 29/10/2026, entiers en varint LEB128) :
  en-tête   e4 00 00 <nb d'entrées de page> 00 ff ff 01
  entrée    <page, 1-based> 00 01 <nb de traits>  puis les traits de la page
  trait     7d 7f 00 00 <bbox x0 y0 x1 y1> 00 00 01 28
            7e 7f 00 00 <bbox x0 y0 x1 y1> 00 <style>         style = varint 32 bits : octet haut = outil
                                                             (0x0F plume, 0x4C surligneur), 24 bits bas = couleur RGB ?
            <2n> 07 <x1 y1 ... xn yn>                      coordonnées = points PDF x 100, origine en haut à gauche
            <n-1> 07 <épaisseur par segment>                 en millièmes de point (hypothèse, cohérente au rendu)
            00 00 <t> 00 00 <t> 00 <t> 00                    horodatages, non interprétés
  fin       7f
Usage : python3 boyue_note.py fichier.note   (affiche un résumé)
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Stroke:
    page: int                            # index 0-based
    points: list[tuple[float, float]]    # en points PDF, origine en haut à gauche de la page
    widths: list[float]                  # épaisseur de chaque segment, en points
    style: int = 0x0F000000              # outil (octet haut) et couleur (24 bits bas, hypothèse)

    @property
    def highlighter(self) -> bool:
        return self.style >> 24 == 0x4C


class Reader:
    def __init__(self, data: bytes):
        self.b, self.i = data, 0

    def byte(self) -> int:
        v = self.b[self.i]
        self.i += 1
        return v

    def varint(self) -> int:
        v = shift = 0
        while True:
            c = self.byte()
            v |= (c & 0x7F) << shift
            shift += 7
            if not c & 0x80:
                return v

    def expect(self, raw: bytes) -> None:
        got = self.b[self.i:self.i + len(raw)]
        if got != raw:
            raise ValueError(f"octet {self.i} : attendu {raw.hex(' ')}, trouvé {got.hex(' ')}")
        self.i += len(raw)


def _stroke(r: Reader, page: int) -> Stroke:
    r.expect(b"\x7d\x7f\x00\x00")
    for _ in range(4):
        r.varint()
    r.expect(b"\x00\x00\x01\x28\x7e\x7f\x00\x00")
    for _ in range(4):
        r.varint()
    r.expect(b"\x00")
    style = r.varint()
    n = r.varint()
    r.expect(b"\x07")
    coords = [r.varint() / 100 for _ in range(n)]
    nw = r.varint()
    r.expect(b"\x07")
    widths = [r.varint() / 1000 for _ in range(nw)]
    r.expect(b"\x00\x00")
    r.varint()
    r.expect(b"\x00\x00")
    r.varint()
    r.expect(b"\x00")
    r.varint()
    r.expect(b"\x00")
    return Stroke(page, list(zip(coords[0::2], coords[1::2])), widths, style)


def parse(data: bytes) -> list[Stroke]:
    r = Reader(data)
    r.expect(b"\xe4\x00\x00")
    entries = r.varint()
    r.expect(b"\x00\xff\xff\x01")
    strokes: list[Stroke] = []
    for _ in range(entries):
        page = r.varint()
        r.expect(b"\x00\x01")
        for _ in range(r.varint()):
            strokes.append(_stroke(r, page - 1))
    r.expect(b"\x7f")
    if r.i != len(data):
        raise ValueError(f"{len(data) - r.i} octets non lus en fin de fichier")
    return strokes


def parse_file(path: Path) -> list[Stroke]:
    return parse(path.read_bytes())


if __name__ == "__main__":
    for f in sys.argv[1:]:
        strokes = parse_file(Path(f))
        pages = sorted({s.page + 1 for s in strokes})
        print(f"{f} : {len(strokes)} traits, pages {pages}")
        for s in strokes:
            xs, ys = [p[0] for p in s.points], [p[1] for p in s.points]
            print(f"  p.{s.page + 1} {len(s.points)} pts  x {min(xs):.0f}-{max(xs):.0f}  y {min(ys):.0f}-{max(ys):.0f}"
                  f"  ép. {min(s.widths):.2f}-{max(s.widths):.2f} pt  style {s.style:08x}")
