// Copyright (C) 2026 Mitchell Scott
// SPDX-License-Identifier: GPL-3.0-only

#include "epublinks.h"

#include <QTextBlock>
#include <QTextCursor>
#include <QTextDocument>
#include <QUrl>

#include <algorithm>
#include <vector>

namespace {

bool isDrawnAsText(const QTextFragment &fragment)
{
    const QString text = fragment.text();
    return std::any_of(text.cbegin(), text.cend(), [](QChar character) {
        return character != QChar::ObjectReplacementCharacter && !character.isSpace();
    });
}

QString spineDestination(const QString &spinePath, const QString &fragment = {})
{
    return fragment.isEmpty() ? spinePath : spinePath + u'#' + fragment;
}

}

void qualifyInternalLinks(QTextDocument *spineDocument)
{
    const QUrl spineUrl = spineDocument->baseUrl();
    const QString spinePath = spineUrl.path();
    bool spineStartPlaced = false;

    struct FormatEdit {
        int position;
        int length;
        QTextCharFormat format;
    };
    std::vector<FormatEdit> edits;

    for (QTextBlock block = spineDocument->begin(); block.isValid(); block = block.next()) {
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const QTextFragment fragment = it.fragment();
            if (!fragment.isValid())
                continue;
            QTextCharFormat format = fragment.charFormat();
            bool formatChanged = false;

            const bool placeSpineStart = !spineStartPlaced && isDrawnAsText(fragment);
            QStringList anchorNames = format.anchorNames();
            if (placeSpineStart || !anchorNames.isEmpty()) {
                QStringList qualifiedNames;
                if (placeSpineStart) {
                    qualifiedNames << spineDestination(spinePath);
                    spineStartPlaced = true;
                }
                for (const QString &name : std::as_const(anchorNames))
                    qualifiedNames << spineDestination(spinePath, name);
                format.setAnchor(true);
                format.setAnchorNames(qualifiedNames + anchorNames);
                formatChanged = true;
            }

            const QString href = format.anchorHref();
            if (!href.isEmpty()) {
                const QUrl target = spineUrl.resolved(QUrl(href));
                if (target.scheme() == spineUrl.scheme() && target.host() == spineUrl.host()) {
                    format.setAnchorHref(u'#' + spineDestination(target.path(), target.fragment()));
                    formatChanged = true;
                }
            }

            if (formatChanged)
                edits.push_back({fragment.position(), fragment.length(), format});
        }
    }

    QTextCursor cursor(spineDocument);
    cursor.beginEditBlock();
    for (const FormatEdit &edit : edits) {
        cursor.setPosition(edit.position);
        cursor.setPosition(edit.position + edit.length, QTextCursor::KeepAnchor);
        cursor.setCharFormat(edit.format);
    }
    cursor.endEditBlock();
}
