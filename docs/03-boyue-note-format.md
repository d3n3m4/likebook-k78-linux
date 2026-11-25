# Reverse-Engineered Boyue `.note` Format → Standard PDF Ink Annotations

For users running **stock Android** on a Boyue Likebook / Meebook reader (tested on Likebook Ares Note K78W, firmware `V3.1.1`, Boyue Reader `V2.1.6`), `tools/boyue_notes/` decodes Boyue's proprietary `.note` sidecar files without root and writes standard PDF `/Ink` annotations readable by Okular, Zotero, Acrobat, Xodo, and Preview.

---

## 1. File Location on Stock Android (No Root Required)

```text
/sdcard/Android/data/com.boyue.app.byreader/HandwritingNote/<PDF filename>/handwriting<PDF byte size>_<n>.note
```

> **Note**: Boyue keys handwritten notes on **both** the exact filename and exact byte size of the PDF. Modifying the PDF (e.g., running OCR) detaches existing notes.

---

## 2. Binary Layout (LEB128 Varints)

All variable-length integers use unsigned LEB128 encoding (`boyue_note.py`):

```text
Header:
  e4 00 00 <page_entry_count> 00 ff ff 01

Page Entry (repeated <page_entry_count> times):
  <page_number_1_based> 00 01 <stroke_count>
    Stroke (repeated <stroke_count> times):
      7d 7f 00 00 <bbox: x0 y0 x1 y1> 00 00 01 28
      7e 7f 00 00 <bbox: x0 y0 x1 y1> 00 <style_u32_varint>
      <2 * n_points> 07 <x1 y1 x2 y2 ... xn yn>
      <n_points - 1> 07 <segment_width_1 ... segment_width_{n-1}>
      00 00 <t1> 00 00 <t2> 00 <t3> 00

Trailer:
  7f
```

### Field Details

- **Coordinates (`x, y`)**: PDF points multiplied by `100`, origin at the **top-left** of the page.
- **Style (`style_u32_varint`)**: High byte identifies the tool (`0x0F` = pen, `0x4C` = highlighter); low 24 bits encode RGB color.
- **Segment widths**: Per-segment stroke thickness in thousandths of a PDF point.

---

## 3. Usage

```bash
pip install pymupdf

# Inspect a .note file
python3 tools/boyue_notes/boyue_note.py path/to/handwriting123456_0.note

# Convert a directory of Boyue notes onto copies of the matching PDFs
python3 tools/boyue_notes/notes_to_pdf.py NOTES_DIR PDFS_DIR OUTPUT_DIR
```
