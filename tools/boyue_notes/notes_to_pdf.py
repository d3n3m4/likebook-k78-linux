#!/usr/bin/env python3
"""
Notes manuscrites Boyue -> annotations Ink standard dans une COPIE du PDF
(lisible par Okular, Zotero, Acrobat, Xodo...). Tourne sur le PC (le Pi LibreELEC n'a pas PyMuPDF).

Entrées :
  NOTES/<nom du PDF>/handwriting<taille du PDF>_<n>.note   copie de .../com.boyue.app.byreader/HandwritingNote/
  PDFS/<nom du PDF>                                         le PDF annoté, identique à celui de la liseuse
Sortie :
  SORTIE/<nom du PDF>   réécrit à chaque passage depuis l'original (pas de traits en double)

Boyue relie les notes au PDF par son nom ET sa taille : un PDF réécrit (OCR...) n'a plus de notes.
Usage : notes_to_pdf.py NOTES PDFS SORTIE      (normalement lancé par scripts/06_notes_vers_pdf.sh)
Dépendance : pymupdf (venv du projet : .venv/bin/pip install pymupdf)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import pymupdf

sys.path.insert(0, str(Path(__file__).parent))
import boyue_note  # noqa: E402

NOTE_RE = re.compile(r"handwriting(\d+)_\d+\.note$")


def write_ink(src_pdf: Path, strokes: list[boyue_note.Stroke], dst_pdf: Path) -> int:
    doc = pymupdf.open(src_pdf)
    n = 0
    for s in strokes:
        if s.page >= len(doc) or len(s.points) < 2:
            continue
        annot = doc[s.page].add_ink_annot([s.points])
        annot.set_border(width=sum(s.widths) / len(s.widths) if s.widths else 0.75)
        annot.set_colors(stroke=tuple((s.style >> k & 255) / 255 for k in (16, 8, 0)))
        if s.highlighter:  # surligneur Boyue : bande semi-transparente (octet haut 0x4C ≈ 30 %)
            annot.set_opacity((s.style >> 24) / 255)
        annot.set_info(title="Likebook K78", subject="Surligneur" if s.highlighter else "Stylet")
        annot.update()
        n += 1
    dst_pdf.parent.mkdir(parents=True, exist_ok=True)
    doc.save(dst_pdf, garbage=3, deflate=True)
    doc.close()
    return n


def process(notes_dir: Path, pdfs_dir: Path, out_dir: Path) -> None:
    for book in sorted(p for p in notes_dir.iterdir() if p.is_dir()):
        pdf = pdfs_dir / book.name
        if not pdf.exists():
            print(f"?? PDF introuvable : {book.name}")
            continue
        size = pdf.stat().st_size
        notes = sorted(f for f in book.iterdir() if (m := NOTE_RE.match(f.name)) and int(m[1]) == size)
        if not notes:
            print(f"?? aucune note pour la taille actuelle ({size} o) : {book.name}")
            continue
        strokes = [s for f in notes for s in boyue_note.parse_file(f)]
        n = write_ink(pdf, strokes, out_dir / book.name)
        pages = sorted({s.page + 1 for s in strokes})
        print(f"ok {book.name} : {n} traits, pages {pages}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    process(*(Path(a) for a in sys.argv[1:]))
