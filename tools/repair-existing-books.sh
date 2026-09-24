#!/bin/bash
# Copyright (C) 2026 Mitchell Scott
# SPDX-License-Identifier: GPL-3.0-only

set -eu
shopt -s nullglob

xochitl_library=/home/root/.local/share/remarkable/xochitl
library=${LIBRARY:-$xochitl_library}
backup_directory=${BACKUP_DIRECTORY:-/home/root/fix-ebook-links-backup}
dry_run=false
requested_uuids=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [UUID...]

Repairs the in-book links (contents pages, footnotes, cross-references) of ebooks that were
typeset before fix-ebook-links was installed, without typesetting them again. Only the link
annotations change: pages, page count and annotations stay as they are.

A link whose target has no destination in the typeset PDF goes to the first page of the file
it points into. That is the right page for a footnote kept in its own file, and the start of
the chapter for a back-link into a long chapter.

With no UUID, every ebook in $library is checked.

  --dry-run   show what would change, write nothing

Stop xochitl before repairing: systemctl stop xochitl
The original PDF of each repaired book is kept in $backup_directory.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) requested_uuids+=("$1") ;;
    esac
    shift
done

if ! $dry_run && [ "$library" = "$xochitl_library" ] && pidof xochitl >/dev/null; then
    echo "xochitl is running. Stop it first: systemctl stop xochitl" >&2
    exit 1
fi

rendered_ebook_uuids() {
    local content uuid
    for content in "$library"/*.content; do
        uuid=$(basename "$content" .content)
        grep -q '"fileType": *"epub"' "$content" && [ -f "$library/$uuid.pdf" ] && echo "$uuid"
    done
}

document_name() {
    sed -n 's/.*"visibleName": *"\([^"]*\)".*/\1/p' "$library/$1.metadata" 2>/dev/null | sed -n 1p
}

read_bytes() {
    dd if="$1" iflag=skip_bytes,count_bytes skip="$2" count="$3" 2>/dev/null
}

is_plain_pdf() {
    local pdf=$1 size
    size=$(stat -c %s "$pdf")
    [ "$(read_bytes "$pdf" 0 5)" = "%PDF-" ] || return 1
    read_bytes "$pdf" $((size > 64 ? size - 64 : 0)) 64 | grep -q '^startxref'
}

read_spine() {
    hexdump -v -e '1/1 "%u\n"' "$1" | awk '
    { bytes[count++] = $1 }
    function u32(    value) {
        value = ((bytes[position] * 256 + bytes[position + 1]) * 256 + bytes[position + 2]) * 256 + bytes[position + 3]
        position += 4
        return value
    }
    function utf8(codepoint) {
        if (codepoint < 128) return sprintf("%c", codepoint)
        if (codepoint < 2048) return sprintf("%c%c", 192 + int(codepoint / 64), 128 + codepoint % 64)
        return sprintf("%c%c%c", 224 + int(codepoint / 4096), 128 + int(codepoint / 64) % 64, 128 + codepoint % 64)
    }
    function qstring(    length_in_bytes, text, end) {
        length_in_bytes = u32()
        if (length_in_bytes == 4294967295) return ""
        text = ""
        for (end = position + length_in_bytes; position < end; position += 2)
            text = text utf8(bytes[position] * 256 + bytes[position + 1])
        return text
    }
    END {
        position = 0
        qstring()
        version = u32()
        if (version >= 2) position += 16
        position += 24
        u32()
        qstring()
        toc_count = u32()
        for (i = 0; i < toc_count; i++) { qstring(); qstring(); u32(); u32() }
        spine_count = u32()
        for (i = 0; i < spine_count; i++) {
            path = qstring(); u32(); u32(); page_start = u32(); page_count = u32()
            printf "SPINE\t%s\t%d\t%d\n", path, page_start, page_count
        }
    }'
}

collect_anchor_groups() {
    local epub_directory=$1 spine_path
    while IFS=$'\t' read -r _ spine_path _ _; do
        [ -f "$epub_directory/$spine_path" ] || continue
        awk -v spine_path="$spine_path" '
        BEGIN { RS = "<" }
        function flush_pending(    i) {
            for (i = 1; i <= pending_count; i++) {
                if (!(pending[i] in registered)) {
                    registered[pending[i]] = 1
                    printf "GROUP\t%s\t%s\t%s\n", spine_path, pending[i], pending[1]
                }
            }
            pending_count = 0
        }
        NR > 1 {
            tag_end = index($0, ">")
            if (!tag_end) next
            tag = substr($0, 1, tag_end - 1)
            text = substr($0, tag_end + 1)
            closing = (substr(tag, 1, 1) == "/")
            name = closing ? substr(tag, 2) : tag
            sub(/[ \t\r\n\/].*/, "", name)
            name = tolower(name)
            if (name == "head") in_head = !closing
            if (!closing && name !~ /^[!?]/) {
                attributes = " " tag
                while (match(attributes, /[ \t\r\n](id|name)[ \t\r\n]*=[ \t\r\n]*("[^"]*"|\047[^\047]*\047)/)) {
                    attribute = substr(attributes, RSTART + 1, RLENGTH - 1)
                    attributes = substr(attributes, RSTART + RLENGTH)
                    key = attribute
                    sub(/[ \t\r\n]*=.*/, "", key)
                    if (key == "name" && name != "a") continue
                    value = attribute
                    sub(/^[^=]*=[ \t\r\n]*/, "", value)
                    value = substr(value, 2, length(value) - 2)
                    if (value != "") pending[++pending_count] = value
                }
            }
            if (!in_head && text ~ /[^ \t\r\n]/ && pending_count) flush_pending()
        }
        END { flush_pending() }' "$epub_directory/$spine_path"
    done < "$2"
}

plan_repair() {
    local object_directory=$1
    shift
    awk -v object_directory="$object_directory" '
    function object_body_starts(line) { return line ~ /^[0-9]+ 0 obj$/ }
    function trim(text) { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", text); return text }
    function directory_of(path) { return (path ~ /\//) ? substr(path, 1, match(path, /\/[^\/]*$/) - 1) : "" }
    function normalize(path,    parts, count, i, stack, depth, result) {
        count = split(path, parts, "/")
        depth = 0
        for (i = 1; i <= count; i++) {
            if (parts[i] == "" || parts[i] == ".") continue
            if (parts[i] == "..") { if (depth) depth--; continue }
            stack[++depth] = parts[i]
        }
        result = ""
        for (i = 1; i <= depth; i++) result = result (i > 1 ? "/" : "") stack[i]
        return result
    }
    function percent_decode(text,    result, hex) {
        result = ""
        while (match(text, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
            hex = toupper(substr(text, RSTART + 1, 2))
            result = result substr(text, 1, RSTART - 1) sprintf("%c", (index("0123456789ABCDEF", substr(hex, 1, 1)) - 1) * 16 + index("0123456789ABCDEF", substr(hex, 2, 1)) - 1)
            text = substr(text, RSTART + 3)
        }
        return result text
    }
    function spine_for_page(page,    path) {
        for (path in spine_start)
            if (page >= spine_start[path] && page < spine_start[path] + spine_length[path]) return path
        return ""
    }
    function destination_in_range(name, path) {
        return (name in destination_page_object) && (destination_page_object[name] in page_index) &&
            page_index[destination_page_object[name]] >= spine_start[path] &&
            page_index[destination_page_object[name]] < spine_start[path] + spine_length[path]
    }
    function destination_array(name) {
        return "[" destination_page_object[name] " 0 R /XYZ null " destination_top[name] " null]"
    }
    function write_annotation(number, destination,    text, rectangle, border, flags, file) {
        text = object_text[number]
        rectangle = match(text, /\/Rect \[[^]]*\]/) ? substr(text, RSTART, RLENGTH) : ""
        border = match(text, /\/Border \[[^]]*\]/) ? substr(text, RSTART, RLENGTH) : "/Border [0 0 0]"
        flags = match(text, /\/F [0-9]+/) ? substr(text, RSTART, RLENGTH) "\n" : ""
        if (rectangle == "") return 0
        file = object_directory "/" number ".obj"
        printf "<<\n/Type /Annot\n/Subtype /Link\n%s%s\n%s\n/Dest %s\n>>\n", flags, rectangle, border, destination > file
        close(file)
        return 1
    }
    FILENAME ~ /spine$/ {
        split($0, fields, "\t")
        spine_start[fields[2]] = fields[3] + 0
        spine_length[fields[2]] = (fields[4] + 0 > 0) ? fields[4] + 0 : 1
        spine_end = fields[3] + fields[4]
        next
    }
    FILENAME ~ /groups$/ {
        split($0, fields, "\t")
        registered_name[fields[2] "#" fields[3]] = fields[4]
        next
    }
    {
        if ($0 == "trailer") { in_trailer = 1; trailer_text = ""; next }
        if (in_trailer) {
            if ($0 == "startxref") { in_trailer = 0; expect_startxref = 1; next }
            trailer_text = trailer_text " " $0
            next
        }
        if (expect_startxref) { last_startxref = $0 + 0; expect_startxref = 0; next }
        if (object_body_starts($0)) { current = $1; buffer = ""; buffered_lines = 0; in_object = 1; next }
        if (!in_object) next
        if ($0 == "endobj") {
            in_object = 0
            delete link_objects[current]; delete object_text[current]; delete annotation_array_text[current]
            delete destination_text[current]; delete annotations_array_of_page[current]
            if (buffered_lines >= 4000) next
            if (buffer ~ /^<<[ \t\r\n]*\/Type \/Pages/) pages_text = buffer
            else if (buffer ~ /\/Type \/Page[ \t\r\n]/ && match(buffer, /\/Annots [0-9]+ 0 R/)) {
                annotations_array_of_page[current] = substr(buffer, RSTART + 8, RLENGTH - 12) + 0
            }
            else if (buffer ~ /^\[[ \t\r\n]*[0-9]+ 0 R/ && buffer !~ /\/XYZ/) annotation_array_text[current] = buffer
            else if (buffer ~ /\/Subtype \/Link/ && buffer ~ /\/S \/URI/) { object_text[current] = buffer; link_objects[current] = 1 }
            else if (buffer ~ /^\[[0-9]+ 0 R \/XYZ /) destination_text[current] = buffer
            else if (buffer ~ /\/Names[ \t\r\n]*\[/ && buffer ~ /\/Limits/) destinations_tree_text = buffer
            next
        }
        if (buffered_lines < 4000) { buffer = buffer $0 "\n"; buffered_lines++ }
    }
    END {
        gsub(/\/Prev [0-9]+/, "", trailer_text)
        sub(/^ *<< */, "", trailer_text)
        sub(/ *>> *$/, "", trailer_text)
        gsub(/  +/, " ", trailer_text)
        print "TRAILER " trailer_text
        print "STARTXREF " last_startxref

        kids = pages_text
        sub(/^.*\/Kids[ \t\r\n]*\[/, "", kids)
        sub(/\].*$/, "", kids)
        kid_count = split(kids, kid_tokens, /[ \t\r\n]+/)
        index_count = 0
        for (i = 1; i <= kid_count; i++) {
            if (kid_tokens[i] ~ /^[0-9]+$/ && kid_tokens[i + 1] == "0" && kid_tokens[i + 2] == "R") {
                page_index[kid_tokens[i]] = index_count
                page_object_at[index_count] = kid_tokens[i]
                index_count++
                i += 2
            }
        }
        if (spine_end - index_count > 1 || index_count - spine_end > 1) {
            print "STALE " spine_end " " index_count
            exit
        }

        for (page in annotations_array_of_page) {
            array_number = annotations_array_of_page[page]
            if (!(array_number in annotation_array_text)) continue
            token_count = split(annotation_array_text[array_number], annotation_tokens, /[][ \t\r\n]+/)
            for (i = 1; i <= token_count; i++)
                if (annotation_tokens[i] ~ /^[0-9]+$/ && annotation_tokens[i + 2] == "R") { annotation_page[annotation_tokens[i]] = page_index[page]; i += 2 }
        }

        names = destinations_tree_text
        sub(/^.*\/Names[ \t\r\n]*\[/, "", names)
        while (match(names, /\([^)]*\)[ \t\r\n]*[0-9]+ 0 R/)) {
            entry = substr(names, RSTART, RLENGTH)
            names = substr(names, RSTART + RLENGTH)
            name = entry
            sub(/\)[ \t\r\n]*[0-9]+ 0 R$/, "", name)
            name = substr(name, 2)
            sub(/^[^ -~]+/, "", name)
            gsub(/\\\(/, "(", name); gsub(/\\\)/, ")", name); gsub(/\\\\/, "\\", name)
            target = entry
            sub(/^.*\)[ \t\r\n]*/, "", target)
            sub(/ 0 R$/, "", target)
            if (!(target in destination_text)) continue
            split(destination_text[target], destination_fields, /[][ \t\r\n]+/)
            destination_page_object[name] = destination_fields[2]
            destination_top[name] = destination_fields[7]
        }

        for (annotation in link_objects) {
            text = object_text[annotation]
            if (!match(text, /\/URI \([^)]*\)/)) continue
            href = substr(text, RSTART + 6, RLENGTH - 7)
            gsub(/\\\(/, "(", href); gsub(/\\\)/, ")", href); gsub(/\\\\/, "\\", href)
            if (href ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) { external++; continue }
            if (!(annotation in annotation_page)) { unresolved++; continue }
            source = spine_for_page(annotation_page[annotation])
            fragment = ""
            target_path = href
            if (index(href, "#")) { fragment = percent_decode(substr(href, index(href, "#") + 1)); target_path = substr(href, 1, index(href, "#") - 1) }
            target_path = percent_decode(target_path)
            if (target_path == "") target_path = source
            else target_path = normalize((directory_of(source) != "" ? directory_of(source) "/" : "") target_path)
            if (!(target_path in spine_start)) { unresolved++; print "UNRESOLVED " href; continue }
            destination = ""
            if (fragment != "") {
                if (destination_in_range(fragment, target_path)) { destination = destination_array(fragment); kind = "exact" }
                else if ((target_path "#" fragment) in registered_name && destination_in_range(registered_name[target_path "#" fragment], target_path)) {
                    destination = destination_array(registered_name[target_path "#" fragment]); kind = "merged_id"
                }
            }
            if (destination == "") {
                if (!(spine_start[target_path] in page_object_at)) { unresolved++; continue }
                destination = "[" page_object_at[spine_start[target_path]] " 0 R /XYZ null null null]"
                kind = (fragment == "") ? "file_start" : "fragment_fallback"
            }
            if (write_annotation(annotation, destination)) { count[kind]++; print "REWRITE " annotation }
            else unresolved++
        }
        printf "SUMMARY exact=%d merged_id=%d file_start=%d fragment_fallback=%d external=%d unresolved=%d\n", count["exact"], count["merged_id"], count["file_start"], count["fragment_fallback"], external, unresolved
    }' "$@"
}

append_incremental_update() {
    local pdf=$1 object_directory=$2 startxref=$3 trailer_entries=$4
    shift 4
    local object offsets=() objects=() xref_offset i
    for object in "$@"; do
        objects+=("$object")
        offsets+=("$(stat -c %s "$pdf")")
        printf '%d 0 obj\n' "$object" >> "$pdf"
        cat "$object_directory/$object.obj" >> "$pdf"
        printf 'endobj\n' >> "$pdf"
    done
    xref_offset=$(stat -c %s "$pdf")
    {
        printf 'xref\n'
        for i in "${!objects[@]}"; do
            printf '%d 1\n%010d 00000 n \n' "${objects[$i]}" "${offsets[$i]}"
        done
        printf 'trailer\n<< %s /Prev %d >>\nstartxref\n%d\n%%%%EOF\n' "$trailer_entries" "$startxref" "$xref_offset"
    } >> "$pdf"
}

repair_book() {
    local uuid=$1 pdf="$library/$1.pdf" epub="$library/$1.epub" index="$library/$1.epubindex"
    local name work summary startxref trailer_entries rewritten=()
    name=$(document_name "$uuid")
    if [ ! -f "$epub" ] || [ ! -f "$index" ]; then
        echo "skip     $uuid  $name  (no .epub or .epubindex)"
        return
    fi
    if ! is_plain_pdf "$pdf"; then
        echo "skip     $uuid  $name  (not a plain Qt PDF)"
        return
    fi
    mkdir -p "$backup_directory"
    work=$(mktemp -d "$backup_directory/work.XXXXXX")
    mkdir "$work/objects" "$work/epub"
    read_spine "$index" > "$work/spine"
    unzip -q -o "$epub" -d "$work/epub"
    collect_anchor_groups "$work/epub" "$work/spine" > "$work/groups"
    tr -d '\000' < "$pdf" > "$work/text"
    plan_repair "$work/objects" "$work/spine" "$work/groups" "$work/text" > "$work/plan"
    if grep -q '^STALE ' "$work/plan"; then
        echo "skip     $uuid  $name  (.epubindex lays out $(sed -n 's/^STALE \([0-9]*\) .*/\1/p' "$work/plan") pages, the PDF has $(sed -n 's/^STALE [0-9]* //p' "$work/plan"))"
        rm -r "$work"
        return
    fi
    mapfile -t rewritten < <(sed -n 's/^REWRITE //p' "$work/plan" | sort -n)
    summary=$(sed -n 's/^SUMMARY //p' "$work/plan")
    if [ ${#rewritten[@]} -eq 0 ]; then
        echo "ok       $uuid  $name"
        rm -r "$work"
        return
    fi
    echo "repair   $uuid  $name  links=${#rewritten[@]} $summary"
    if $dry_run; then
        rm -r "$work"
        return
    fi
    startxref=$(sed -n 's/^STARTXREF //p' "$work/plan")
    trailer_entries=$(sed -n 's/^TRAILER //p' "$work/plan")
    cp "$pdf" "$work/repaired.pdf"
    append_incremental_update "$work/repaired.pdf" "$work/objects" "$startxref" "$trailer_entries" "${rewritten[@]}"
    [ -f "$backup_directory/$uuid.pdf" ] || cp "$pdf" "$backup_directory/$uuid.pdf"
    mv "$work/repaired.pdf" "$pdf"
    rm -r "$work"
}

if [ ${#requested_uuids[@]} -eq 0 ]; then
    mapfile -t requested_uuids < <(rendered_ebook_uuids)
fi

for uuid in "${requested_uuids[@]}"; do
    repair_book "$uuid"
done
