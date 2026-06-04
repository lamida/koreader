--[[--
Reads a calibre library catalog directly from its `metadata.db` SQLite database.

Unlike the `calibre.koplugin` metadata search (which relies on the `metadata.calibre`
JSON files written by calibre's "Send to device"), this module reads the master
`metadata.db` that lives at the root of a calibre library, so it can list the whole
library and resolve each book's file on disk.

Design note (responsiveness): the catalog is read once with @{queryAllBooks}; the UI
then filters and sorts that in-memory list with @{filterBooks} / @{sortBooks}, so
typing in the filter or changing the sort never hits the database again. File
resolution (@{resolveBookPath}) is a single stat plus, at worst, a scan of one book
directory: it never enumerates the whole library, which is what made the original
cicicaba app block (its SAF tree walk) and trip Android's "isn't responding" dialog.

@module calibrelibrary.db
--]]

local SQ3 = require("lua-ljsqlite3/init")
local Utf8Proc = require("ffi/utf8proc")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local CalibreDB = {
    -- Only formats KOReader opens well and that are commonly synced. calibre
    -- stores the format column in uppercase (EPUB, PDF, MOBI, AZW3, ...).
    supported_formats = { "EPUB", "PDF" },
}

-- Book fields allowed as a sort key, mapped to the comparison they use.
-- "title" is compared case-insensitively; the date fields hold calibre's ISO
-- timestamps, whose lexicographic order matches chronological order.
CalibreDB.sort_fields = {
    title     = true,
    pubdate   = true,
    timestamp = true,
}

local function formatsInClause()
    local quoted = {}
    for _, format in ipairs(CalibreDB.supported_formats) do
        table.insert(quoted, "'" .. format .. "'")
    end
    return table.concat(quoted, ", ")
end

function CalibreDB:getDBPath(library_dir)
    if not library_dir then return nil end
    return library_dir .. "/metadata.db"
end

--- Returns true if `library_dir` holds a non-empty metadata.db.
function CalibreDB:isAvailable(library_dir)
    local db_path = self:getDBPath(library_dir)
    if not db_path then return false end
    local attr = lfs.attributes(db_path)
    return attr ~= nil and attr.mode == "file" and attr.size > 0
end

--- Parse a "FORMAT:name|FORMAT:name" group_concat into a list of {format, name}.
local function parseFormats(formats_string)
    local formats = {}
    if not formats_string or formats_string == "" then
        return formats
    end
    for item in formats_string:gmatch("[^|]+") do
        local format, name = item:match("^([^:]+):(.+)$")
        if format and name then
            table.insert(formats, { format = format, name = name })
        end
    end
    return formats
end

--[[--
Read the whole catalog once.

Only books that have at least one supported format on disk are returned (so
e.g. mobi-only titles are hidden). The result is unsorted; callers sort with
@{sortBooks}.

@param library_dir path to the calibre library (the folder containing metadata.db)
@return list of books: { id, title, path, authors, pubdate, timestamp, formats = {{format, name}, ...} }
--]]
function CalibreDB:queryAllBooks(library_dir)
    if not self:isAvailable(library_dir) then
        return {}
    end

    local formats_in = formatsInClause()
    local sql = table.concat({
        "SELECT b.id, b.title, b.path, b.pubdate, b.timestamp,",
        "(SELECT group_concat(a.name, ', ') FROM authors a",
        " JOIN books_authors_link bal ON a.id = bal.author WHERE bal.book = b.id) AS authors,",
        "(SELECT group_concat(d.format || ':' || d.name, '|') FROM data d",
        " WHERE d.book = b.id AND d.format IN (" .. formats_in .. ")) AS formats",
        "FROM books b",
        "WHERE b.id IN (SELECT book FROM data WHERE format IN (" .. formats_in .. "))",
    }, " ")

    local books = {}
    local ok, err = pcall(function()
        local conn = SQ3.open(self:getDBPath(library_dir), "ro")
        local stmt = conn:prepare(sql)
        local row = stmt:step()
        while row do
            table.insert(books, {
                id        = tonumber(row[1]),
                title     = row[2] or "Unknown",
                path      = row[3] or "",
                pubdate   = row[4] or "",
                timestamp = row[5] or "",
                authors   = row[6] or "Unknown Author",
                formats   = parseFormats(row[7]),
            })
            row = stmt:step()
        end
        stmt:close()
        conn:close()
    end)
    if not ok then
        logger.warn("CalibreDB: failed to read metadata.db:", err)
        return {}
    end

    return books
end

--- Case-insensitive substring filter on title or author. Operates on the
--- in-memory list from @{queryAllBooks}, so it is instant and never blocks.
function CalibreDB:filterBooks(books, query)
    if not query or query == "" then
        return books
    end
    local needle = Utf8Proc.lowercase(query)
    local result = {}
    for _, book in ipairs(books) do
        local title = Utf8Proc.lowercase(book.title or "")
        local authors = Utf8Proc.lowercase(book.authors or "")
        -- plain (non-pattern) find so punctuation in the query is literal.
        if title:find(needle, 1, true) or authors:find(needle, 1, true) then
            table.insert(result, book)
        end
    end
    return result
end

--- Return a sorted copy of `books` (the input is not mutated).
function CalibreDB:sortBooks(books, field, ascending)
    if not self.sort_fields[field] then
        field = "title"
    end
    local sorted = {}
    for i, book in ipairs(books) do
        sorted[i] = book
    end

    local function sortKey(book)
        if field == "title" then
            return Utf8Proc.lowercase(book.title or "")
        end
        return book[field] or ""
    end

    table.sort(sorted, function(a, b)
        local ka, kb = sortKey(a), sortKey(b)
        if ka ~= kb then
            if ascending == false then
                return ka > kb
            end
            return ka < kb
        end
        -- Stable, readable secondary ordering by title.
        return Utf8Proc.lowercase(a.title or "") < Utf8Proc.lowercase(b.title or "")
    end)
    return sorted
end

--[[--
Resolve the on-disk path of a book file.

calibre stores files at `<library>/<book.path>/<data.name>.<format>` where
`book.path` is e.g. "Author Name/Title (123)" and `data.name` is the filename
without extension.

This does a single stat for the expected path. If that is missing (the stored
name can occasionally differ from the file on disk), it scans only the book's
own directory - a handful of entries - for a file with the right extension. It
never walks the whole library, so it returns in microseconds and cannot freeze
the UI.

@return absolute path string if a file is found, otherwise nil
--]]
function CalibreDB:resolveBookPath(library_dir, book_path, file_name, format)
    if not library_dir or not book_path or not format then
        return nil
    end
    local ext = format:lower()
    local book_dir = library_dir .. "/" .. book_path

    if file_name then
        local expected = string.format("%s/%s.%s", book_dir, file_name, ext)
        if lfs.attributes(expected, "mode") == "file" then
            return expected
        end
    end

    -- Fallback: scan just this one book directory.
    local entries = {}
    local ok = pcall(function()
        for entry in lfs.dir(book_dir) do
            table.insert(entries, entry)
        end
    end)
    if ok then
        local suffix = "." .. ext
        for _, entry in ipairs(entries) do
            if entry:lower():sub(-#suffix) == suffix then
                return book_dir .. "/" .. entry
            end
        end
    end
    return nil
end

return CalibreDB
