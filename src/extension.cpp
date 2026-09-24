// Copyright (C) 2026 Mitchell Scott
// SPDX-License-Identifier: GPL-3.0-only

#include <QString>
#include <QTextDocument>
#include <QUrl>
#include <QtGui/private/qtextengine_p.h>

#include "epublinks.h"
#include "xovi.h"

class QPdfEnginePrivate;

namespace {

template <typename Function, typename Symbol>
Function symbolAs(Symbol symbol)
{
    return reinterpret_cast<Function>(reinterpret_cast<void *>(symbol));
}

bool isEpubSpineDocument(const QTextDocument *document)
{
    const QString path = document->baseUrl().path();
    return path.endsWith(QStringLiteral(".xhtml"), Qt::CaseInsensitive)
        || path.endsWith(QStringLiteral(".html"), Qt::CaseInsensitive)
        || path.endsWith(QStringLiteral(".htm"), Qt::CaseInsensitive);
}

using DrawTextItem = void (*)(QPdfEnginePrivate *, const QPointF &, const QTextItemInt &);

void registerAnchorWithoutDrawing(DrawTextItem originalDrawTextItem, QPdfEnginePrivate *engine,
                                  const QPointF &position, const QTextItemInt &textItem, const QString &anchor)
{
    QTextCharFormat anchorOnlyFormat = textItem.charFormat;
    anchorOnlyFormat.clearProperty(QTextFormat::AnchorHref);
    anchorOnlyFormat.setAnchorNames({anchor});

    QTextItemInt anchorOnlyItem(textItem);
    const_cast<QTextCharFormat &>(anchorOnlyItem.charFormat) = anchorOnlyFormat;
    anchorOnlyItem.glyphs = QGlyphLayout();
    originalDrawTextItem(engine, position, anchorOnlyItem);
}

}

extern "C" void override$_ZN13QTextDocument7setHtmlERK7QString(QTextDocument *self, const QString &html)
{
    using SetHtml = void (*)(QTextDocument *, const QString &);
    const auto originalSetHtml = symbolAs<SetHtml>($_ZN13QTextDocument7setHtmlERK7QString);
    originalSetHtml(self, html);
    if (isEpubSpineDocument(self))
        qualifyInternalLinks(self);
}

extern "C" void override$_ZN17QPdfEnginePrivate12drawTextItemERK7QPointFRK12QTextItemInt(
    QPdfEnginePrivate *self, const QPointF &position, const QTextItemInt &textItem)
{
    const auto originalDrawTextItem =
        symbolAs<DrawTextItem>($_ZN17QPdfEnginePrivate12drawTextItemERK7QPointFRK12QTextItemInt);
    originalDrawTextItem(self, position, textItem);

    const QStringList anchors = textItem.charFormat.anchorNames();
    const bool originalRegisteredFirstAnchor = !textItem.charFormat.hasProperty(QTextFormat::AnchorHref);
    for (qsizetype i = originalRegisteredFirstAnchor ? 1 : 0; i < anchors.size(); ++i)
        registerAnchorWithoutDrawing(originalDrawTextItem, self, position, textItem, anchors.at(i));
}
