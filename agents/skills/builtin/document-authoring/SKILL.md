---
name: document-authoring
description: Creates files in the sandbox — xlsx, docx, pptx, PDF — with libraries that are already installed. Use for a spreadsheet, Tabelle, Excel, Word document, Bericht, report, Präsentation, slides, PDF, invoice, Rechnung, Formular ausfüllen, or whenever the answer is better as a file than as chat text.
---

# Document authoring

Reading a document is `read_document`. Writing one is this skill: a Python
script in the sandbox, then `send_file_to_user`.

**Everything below is preinstalled in the image.** Never run `pip install`,
never build a venv — a plain `python3 script.py` imports all of it.

## Which library for which target

| Target | Use |
| --- | --- |
| `.xlsx` | `openpyxl` (`pandas` for the data, openpyxl for the formatting) |
| `.docx` | `python-docx` |
| `.pptx` | `python-pptx` |
| new PDF, laid out by code | `reportlab` — invoices, labels, certificates, anything positioned |
| new PDF, laid out as a document | `weasyprint` — write HTML + CSS, render it; the right tool for a report |
| Markdown into that HTML | `markdown` |
| fill an existing PDF form | `pypdf` (see the gotcha below) |
| merge, split, rotate, watermark a PDF | `pypdf` |
| repair or linearize a PDF | `qpdf --linearize in.pdf out.pdf` |
| docx / xlsx / pptx → PDF | `soffice --headless --convert-to pdf --outdir OUT FILE` |
| images | `Pillow` |

Pick by what the file has to *be*, not by what is quickest to type. A user who
asks for "a table of the numbers" wants `.xlsx` they can sort, not a PDF
picture of a table. A user who asks for a report wants a PDF that reads like a
document — that is weasyprint, not reportlab drawing text at coordinates.

## Writing an xlsx

```python
from openpyxl import Workbook
from openpyxl.styles import Font

wb = Workbook()
ws = wb.active
ws.title = "Q3"

ws.append(["Month", "Revenue", "Orders"])
for cell in ws[1]:
    cell.font = Font(bold=True)

for row in [("Jul", 12400, 310), ("Aug", 15100, 366), ("Sep", 18250, 402)]:
    ws.append(row)

ws["B5"] = "=SUM(B2:B4)"          # a real formula, not a computed constant
for col, width in zip("ABC", (10, 14, 10)):
    ws.column_dimensions[col].width = width
for row in ws.iter_rows(min_row=2, min_col=2, max_col=2):
    for cell in row:
        cell.number_format = '#,##0 "€"'
ws.freeze_panes = "A2"

wb.save("/workspace/q3.xlsx")
```

With a DataFrame in hand: `df.to_excel("/workspace/x.xlsx", index=False)` and
then reopen with openpyxl if it needs widths, bold headers or number formats.

## Filling an existing PDF form

```python
from pypdf import PdfReader, PdfWriter

reader = PdfReader("/workspace/form.pdf")
print(reader.get_fields().keys())   # always look first — field names are not guessable

writer = PdfWriter(clone_from=reader)
# THE GOTCHA: without NeedAppearances the values are in the file but most
# viewers draw nothing, so the user sees an empty form and thinks it failed.
writer.set_need_appearances_writer(True)

for page in writer.pages:
    writer.update_page_form_field_values(
        page,
        {"full_name": "Ada Lovelace", "date": "2026-09-13", "agree": "/Yes"},
        auto_regenerate=False,
    )

with open("/workspace/form-filled.pdf", "wb") as fh:
    writer.write(fh)
```

Checkboxes take the export value with a leading slash (`"/Yes"`, `"/On"`), not
`True`. To hand back a form nobody can edit afterwards, pass `flatten=True` to
the same call — the values are then drawn into the page and the fields are
gone.

## Converting to PDF

```bash
soffice --headless --convert-to pdf --outdir /workspace/out /workspace/report.docx
```

Works for docx, xlsx, pptx and odf. Notes that cost time when unknown: the
first call builds a user profile and takes a few seconds; only one soffice
instance runs per profile, so for a parallel conversion add
`-env:UserInstallation=file:///tmp/lo-$$`; there is no Java in the image, which
the conversion path does not need.

## Deliver the file

The workspace lives in a container on the user's machine — writing the file is
not giving it to them. Finish with the `send_file_to_user` tool (`path`, and
`name` if the on-disk name is ugly). The hard ceiling is 8 MiB per file; past
that, zip it, split it, or lower the image resolution before sending.

## Rules

- Put files in `/workspace`, with a name the user would recognise a week later.
- Only real numbers from this conversation go into a document. Do not invent a
  row to make a table look complete.
- Embed the numbers as numbers and the totals as formulas, so the spreadsheet
  stays useful after the user edits a cell.
- Say in your reply what the file contains. The file is the deliverable; the
  message is still the answer.
