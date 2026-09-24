# fix-ebook-links

[![rm1](https://img.shields.io/badge/rM1-supported-green)](https://remarkable.com/store/remarkable)
[![rm2](https://img.shields.io/badge/rM2-supported-green)](https://remarkable.com/store/remarkable-2)
[![rmpp](https://img.shields.io/badge/rMPP-supported-green)](https://remarkable.com/products/remarkable-paper/pro)
[![rmppmove](https://img.shields.io/badge/rMPPMove-supported-green)](https://remarkable.com/products/remarkable-paper/pro-move)
[![rmppure](https://img.shields.io/badge/rMPPure-supported-green)](https://remarkable.com/products/remarkable-paper/pure)



A xovi extension that makes the links inside ebooks work: printed tables of contents, footnotes and their back-links, and cross-references such as "see chapter 4".

xochitl typesets an EPUB into a PDF with Qt, one spine file at a time. Qt writes a link as a jump inside the PDF only when its target starts with `#`, so a link to another file of the book (`chapter5.xhtml#note1`) becomes a web link, and the reader does nothing when it is tapped. Qt also drops the target of any anchor that sits on link text, which is how footnotes are marked up, and keeps only the first of several ids at one position. 

This extension fixes both while the PDF is written. It qualifies every in-book link and anchor with the file it belongs to, adds a target at the start of each file, and records the anchors Qt skips. The pages themselves are drawn exactly as before.

## Dependencies

- [xovi](https://github.com/asivery/rm-xovi-extensions) - Extension framework

## Installation

### Vellum

```
vellum add fix-ebook-links
```

### Manual

1. Ensure xovi is installed
2. Download the build for your device from the [latest release](https://github.com/rmitchellscott/rm-fix-ebook-links/releases/latest): `fix-ebook-links-aarch64.so` for the Paper Pro, Paper Pro Move and Paper Pure, or `fix-ebook-links-armv7.so` for the reMarkable 1 and 2
3. Place it in `/home/root/xovi/extensions.d/` on your reMarkable, renamed to `fix-ebook-links.so`
4. Restart xovi

## Usage

Only books typeset while the extension is loaded are fixed. A book that was already on the tablet keeps its dead links until it is typeset again.

Typesetting a book again repaginates it. Handwritten annotations stay on the page number they were written on, so in a book you have annotated they may no longer line up with the text.

## Repairing books already on the tablet

The extension fixes books as they are typeset. `tools/repair-existing-books.sh` fixes the links in books that were typeset before it was installed, without typesetting them again, so pages and handwritten annotations stay where they are. It runs on the tablet:

```
scp tools/repair-existing-books.sh root@10.11.99.1:
ssh root@10.11.99.1
systemctl stop xochitl
bash repair-existing-books.sh --dry-run
bash repair-existing-books.sh
systemctl start xochitl
```

With no arguments it checks every ebook; pass document UUIDs to limit it. A book needs its `.epub` and `.epubindex` on the tablet. The `.epubindex` does not sync, so a book typeset on another device is skipped, and so is a book whose PDF came from a device with a different screen. A link whose target has no destination in the typeset PDF goes to the first page of the file it points into: the right page for a footnote kept in its own file, and the start of the chapter for a back-link into a long chapter. The original PDF is kept in `/home/root/fix-ebook-links-backup/`, and the repaired PDF syncs to your other devices.

## Limitations

- A link to a file that contains only an image, such as a title page, stays dead. Qt records targets only while drawing text.
- EPUB 3 notes written as `<aside epub:type="footnote">` keep their dead links. Qt's HTML import drops the id of an `<aside>` before the PDF is written.

## License

Copyright (C) 2026 Mitchell Scott

Licensed under the GNU General Public License v3.0.
