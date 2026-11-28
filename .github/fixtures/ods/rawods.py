"""Raw OpenDocument packages for probes and for the generator: a content.xml
spelled by hand, and a ZIP around it written the way the ODF package spec
asks (the `mimetype` entry first and stored). Nothing here reads a file
back; the reference reader is asked for that.
"""
import datetime
import io
import zipfile

SPREADSHEET = "application/vnd.oasis.opendocument.spreadsheet"

NS = ('xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
      'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
      'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
      'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
      'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" '
      'xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" '
      'xmlns:of="urn:oasis:names:tc:opendocument:xmlns:of:1.2" '
      'xmlns:calcext="urn:org:documentfoundation:names:experimental:calc:xmlns:calcext:1.0" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" '
      'xmlns:xlink="http://www.w3.org/1999/xlink" office:version="1.2"')

MANIFEST = ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" '
            'manifest:version="1.2">'
            '<manifest:file-entry manifest:full-path="/" manifest:version="1.2" '
            'manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>'
            '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>'
            '</manifest:manifest>')

STAMP = (2020, 1, 1, 0, 0, 0)  # fixed, so a package written twice is the same bytes


def content(body, decl='<?xml version="1.0" encoding="UTF-8"?>\n'):
    """content.xml around a body: the document-content root with the usual
    namespace declarations and whatever sits in office:body."""
    return (decl +
            '<office:document-content ' + NS + '>'
            '<office:scripts/>'
            '<office:font-face-decls/>'
            '<office:automatic-styles/>'
            '<office:body><office:spreadsheet>' + body +
            '</office:spreadsheet></office:body>'
            '</office:document-content>').encode("utf-8")


def table(name, rows_xml, attrs=""):
    """One table:table around its rows' XML."""
    return ('<table:table table:name="' + name + '"' + attrs + '>' + rows_xml +
            '</table:table>')


def row(cells_xml, attrs=""):
    return '<table:table-row' + attrs + '>' + cells_xml + '</table:table-row>'


def pack(entries, compress_content=True, mimetype=True):
    """A ZIP holding `entries` (name, bytes): the mimetype entry first and
    stored, as the package specification asks — unless `mimetype` is
    false, for a package without one; the rest deflated unless
    `compress_content` is false."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as z:
        if mimetype:
            info = zipfile.ZipInfo("mimetype", STAMP)
            info.compress_type = zipfile.ZIP_STORED
            z.writestr(info, SPREADSHEET.encode("utf-8"))
        for name, data in entries:
            info = zipfile.ZipInfo(name, STAMP)
            info.compress_type = zipfile.ZIP_DEFLATED if compress_content else zipfile.ZIP_STORED
            z.writestr(info, data)
    return buffer.getvalue()


def package(body, extra=(), compress_content=True, decl='<?xml version="1.0" encoding="UTF-8"?>\n'):
    """A whole spreadsheet package around a body."""
    return pack([("content.xml", content(body, decl)),
                 ("styles.xml", content("").replace(b"document-content", b"document-styles")),
                 ("meta.xml", b'<?xml version="1.0" encoding="UTF-8"?>\n'
                              b'<office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
                              b'office:version="1.2"><office:meta/></office:document-meta>'),
                 ("META-INF/manifest.xml", MANIFEST.encode("utf-8"))] + list(extra),
                compress_content=compress_content)


def cell(attrs, inner=""):
    """One table:table-cell."""
    return '<table:table-cell' + attrs + '>' + inner + '</table:table-cell>'


def text(t):
    """One paragraph around escaped text."""
    return '<text:p>' + (t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")) + '</text:p>'


def fcell(v):
    """One float cell."""
    return cell(' office:value-type="float" office:value="' + v + '"', text(v))


def scell(inner):
    """One string cell around paragraphs' XML."""
    return cell(' office:value-type="string"', inner)


EPOCH = datetime.datetime(1970, 1, 1)
