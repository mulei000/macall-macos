#!/usr/bin/env python3
"""生成最小有效 OOXML 模板（docx / pptx / xlsx），供 macall「新建文件」使用。

这些文件只保证能被对应 App（Word / Keynote 导入 / Excel / Numbers 导入）正常打开，
不含任何实际内容。iWork 的 .pages/.key/.numbers 由用户在设置里拖入真实模板，
这里不生成（它们是苹果私有打包格式，无法靠最小骨架生成）。
"""
import os
import zipfile

PKG = "http://schemas.openxmlformats.org/package/2006/relationships"
DOC = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
WORD = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
XLS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
PPT = "http://schemas.openxmlformats.org/presentationml/2006/main"

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "Resources", "FinderTemplates")
OUT_DIR = os.path.abspath(OUT_DIR)
os.makedirs(OUT_DIR, exist_ok=True)


def write_zip(path, files):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items():
            z.writestr(name, data)
    print("wrote", os.path.basename(path))


# ---------- DOCX ----------
docx = {
    "[Content_Types].xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="%s">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '</Types>' % PKG
    ),
    "_rels/.rels": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="%s">'
        '<Relationship Id="rId1" Type="%s/officeDocument" Target="word/document.xml"/>'
        '</Relationships>' % (PKG, DOC)
    ),
    "word/document.xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="%s"><w:body><w:p/></w:body></w:document>' % WORD
    ),
}
write_zip(os.path.join(OUT_DIR, "docx.docx"), docx)

# ---------- XLSX ----------
xlsx = {
    "[Content_Types].xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="%s">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '</Types>' % PKG
    ),
    "_rels/.rels": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="%s">'
        '<Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>' % (PKG, DOC)
    ),
    "xl/workbook.xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="%s" xmlns:r="%s">'
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>'
        '</workbook>' % (XLS, DOC)
    ),
    "xl/_rels/workbook.xml.rels": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="%s">'
        '<Relationship Id="rId1" Type="%s/worksheet" Target="worksheets/sheet1.xml"/>'
        '</Relationships>' % (PKG, DOC)
    ),
    "xl/worksheets/sheet1.xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="%s"><sheetData/></worksheet>' % XLS
    ),
}
write_zip(os.path.join(OUT_DIR, "xlsx.xlsx"), xlsx)

# ---------- PPTX ----------
pptx = {
    "[Content_Types].xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="%s">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
        '<Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
        '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
        '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
        '</Types>' % PKG
    ),
    "_rels/.rels": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="%s">'
        '<Relationship Id="rId1" Type="%s/officeDocument" Target="ppt/presentation.xml"/>'
        '</Relationships>' % (PKG, DOC)
    ),
    "ppt/presentation.xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<presentation xmlns="%s" xmlns:r="%s">'
        '<sldMasterIdLst><sldMasterId id="2147483648" r:id="rId1"/></sldMasterIdLst>'
        '<sldIdLst><sldId id="256" r:id="rId2"/></sldIdLst>'
        '</presentation>' % (PPT, DOC)
    ),
    "ppt/_rels/presentation.xml.rels": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="%s">'
        '<Relationship Id="rId1" Type="%s/slideMaster" Target="slideMasters/slideMaster1.xml"/>'
        '<Relationship Id="rId2" Type="%s/slide" Target="slides/slide1.xml"/>'
        '</Relationships>' % (PKG, DOC, DOC)
    ),
    "ppt/slideMasters/slideMaster1.xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<slideMaster xmlns="%s" xmlns:r="%s">'
        '<cSld><bg/><spTree><nvGrpSpPr/><grpSpPr/></spTree></cSld>'
        '<clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" '
        'accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" '
        'hlink="hlink" folHlink="folHlink"/>'
        '</slideMaster>' % (PPT, DOC)
    ),
    "ppt/slideMasters/_rels/slideMaster1.xml.rels": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="%s">'
        '<Relationship Id="rId1" Type="%s/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
        '</Relationships>' % (PKG, DOC)
    ),
    "ppt/slideLayouts/slideLayout1.xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<slideLayout xmlns="%s" xmlns:r="%s" type="titleAndBody" masterId="2147483648">'
        '<cSld><spTree><nvGrpSpPr/><grpSpPr/></spTree></cSld>'
        '</slideLayout>' % (PPT, DOC)
    ),
    "ppt/slideLayouts/_rels/slideLayout1.xml.rels": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="%s">'
        '<Relationship Id="rId1" Type="%s/slideMaster" Target="../slideMasters/slideMaster1.xml"/>'
        '</Relationships>' % (PKG, DOC)
    ),
    "ppt/slides/slide1.xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<slide xmlns="%s" xmlns:r="%s">'
        '<cSld><spTree><nvGrpSpPr/><grpSpPr/></spTree></cSld>'
        '</slide>' % (PPT, DOC)
    ),
    "ppt/slides/_rels/slide1.xml.rels": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="%s">'
        '<Relationship Id="rId1" Type="%s/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
        '</Relationships>' % (PKG, DOC)
    ),
}
write_zip(os.path.join(OUT_DIR, "pptx.pptx"), pptx)

print("Done ->", OUT_DIR)
