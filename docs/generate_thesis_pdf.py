from pathlib import Path

from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm
from reportlab.platypus import Paragraph, Preformatted, SimpleDocTemplate, Spacer


def build_pdf(markdown_path: Path, output_pdf: Path) -> None:
    text = markdown_path.read_text(encoding="utf-8")
    styles = getSampleStyleSheet()
    body = ParagraphStyle(
        "Body",
        parent=styles["Normal"],
        fontName="Helvetica",
        fontSize=10.5,
        leading=14,
        spaceAfter=6,
    )
    h1 = ParagraphStyle(
        "H1",
        parent=styles["Heading1"],
        fontName="Helvetica-Bold",
        fontSize=16,
        leading=20,
        spaceAfter=10,
    )
    h2 = ParagraphStyle(
        "H2",
        parent=styles["Heading2"],
        fontName="Helvetica-Bold",
        fontSize=12.5,
        leading=16,
        spaceAfter=8,
    )
    code_style = ParagraphStyle(
        "Code",
        parent=body,
        fontName="Courier",
        fontSize=9,
        leading=12,
        leftIndent=8,
    )

    story = []
    in_code = False
    code_buffer = []

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if line.strip().startswith("```"):
            if in_code:
                story.append(Preformatted("\n".join(code_buffer), code_style))
                story.append(Spacer(1, 0.2 * cm))
                code_buffer = []
                in_code = False
            else:
                in_code = True
            continue

        if in_code:
            code_buffer.append(line)
            continue

        if not line.strip():
            story.append(Spacer(1, 0.18 * cm))
            continue

        if line.startswith("# "):
            story.append(Paragraph(line[2:].strip(), h1))
            continue
        if line.startswith("## "):
            story.append(Paragraph(line[3:].strip(), h2))
            continue

        safe = (
            line.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
        )
        if safe.startswith("- "):
            safe = f"&bull; {safe[2:]}"
        story.append(Paragraph(safe, body))

    if code_buffer:
        story.append(Preformatted("\n".join(code_buffer), code_style))

    doc = SimpleDocTemplate(
        str(output_pdf),
        pagesize=A4,
        leftMargin=2 * cm,
        rightMargin=2 * cm,
        topMargin=1.8 * cm,
        bottomMargin=1.8 * cm,
        title="Floote Thesis Defense Report",
        author="Floote Team",
    )
    doc.build(story)


if __name__ == "__main__":
    base = Path(__file__).resolve().parent
    # Mobile inventory first so a locked thesis PDF (open in viewer) does not block it.
    jobs = [
        (
            base / "mobile_app_files_defense.md",
            base / "mobile_app_files_defense.pdf",
        ),
        (
            base / "thesis_defense_report_smart_routing_iot.md",
            base / "thesis_defense_report_smart_routing_iot.pdf",
        ),
    ]
    for md, pdf in jobs:
        if not md.exists():
            print(f"Skip (missing): {md}")
            continue
        try:
            build_pdf(md, pdf)
            print(f"Generated: {pdf}")
        except PermissionError as e:
            print(f"Permission denied (close the file if open): {pdf}\n  {e}")
