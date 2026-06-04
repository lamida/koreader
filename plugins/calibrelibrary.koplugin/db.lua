--[[--
Reads a calibre library catalog directly from its `metadata.db` SQLite database.

Unlike the `calibre.koplugin` metadata search (which relies on the `metadata.calibre`
JSON files written by calibre's "Send to device"), this module reads the master
`metadata.db` that lives at the root of a calibre library, so it can list the whole
library and resolve each book's file on disk.

@module calibrelibrary.db
--]]

local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local CalibreDB = {
    -- Only formats KOReader opens well and that are commonly synced. calibre
    -- stores the format column in uppercase (EPUB, PDF, MOBI, AZW3, ...).
    supported_formats = { "EPUB", "PDF" },
}

-- Whitelisted books-table columns for ORDER BY. Keys are stable identifiers
-- used in settings; never interpolate user input here.
CalibreDB.sort_fields = {
    title     = "title",
    pubdate   = "pubdate",
    timestamp = "timestamp",
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
Query books from the library catalog.

@param library_dir path to the calibre library (the folder containing metadata.db)
@param opts table with optional keys:
    search_query: string, matched against title and author (case-insensitive LIKE)
    sort_field: one of the keys in CalibreDB.sort_fields (default "title")
    ascending: boolean (default true)
@return list of books: { id, title, path, authors, formats = {{format, name}, ...} }
--]]
function CalibreDB:queryBooks(library_dir, opts)
    opts = opts or {}
    if not self:isAvailable(library_dir) then
        return {}
    end

    local sort_column = self.sort_fields[opts.sort_field] or self.sort_fields.title
    local direction = opts.ascending == false and "DESC" or "ASC"
    local formats_in = formatsInClause()
    local has_search = opts.search_query ~= nil and opts.search_query ~= ""

    local sql = table.concat({
        "SELECT b.id, b.title, b.path,",
        "(SELECT group_concat(a.name, ', ') FROM authors a",
        " JOIN books_authors_link bal ON a.id = bal.author WHERE bal.book = b.id) AS authors,",
        "(SELECT group_concat(d.format || ':' || d.name, '|') FROM data d",
        " WHERE d.book = b.id AND d.format IN (" .. formats_in .. ")) AS formats",
        "FROM books b",
        -- Only list books that have at least one supported format on disk.
        "WHERE b.id IN (SELECT book FROM data WHERE format IN (" .. formats_in .. "))",
        has_search and [[AND (b.title LIKE ? OR b.id IN (
            SELECT bal.book FROM books_authors_link bal
            JOIN authors a ON bal.author = a.id WHERE a.name LIKE ?))]] or "",
        "ORDER BY b." .. sort_column .. " " .. direction,
        -- Stable secondary ordering when not already sorting by title.
        sort_column ~= self.sort_fields.title and ", b.title ASC" or "",
    }, " ")

    local books = {}
    local ok, err = pcall(function()
        local conn = SQ3.open(self:getDBPath(library_dir), "ro")
        local stmt = conn:prepare(sql)
        if has_search then
            local wildcard = "%" .. opts.search_query .. "%"
            stmt:bind(wildcard, wildcard)
        end
        local row = stmt:step()
        while row do
            table.insert(books, {
                id      = tonumber(row[1]),
                title   = row[2] or "Unknown",
                path    = row[3] or "",
                authors = row[4] or "Unknown Author",
                formats = parseFormats(row[5]),
            })
            row = stmt:step()
        end
        stmt:close()
        conn:close()
    end)
    if not ok then
        logger.warn("CalibreDB: failed to query metadata.db:", err)
        return {}
    end

    return books
end

--[[--
Resolve the on-disk path of a book file.

calibre stores files at `<library>/<book.path>/<data.name>.<format>` where
`book.path` is e.g. "Author Name/Title (123)" and `data.name` is the filename
without extension.

@return absolute path string if the file exists, otherwise nil
--]]
function CalibreDB:resolveBookPath(library_dir, book_path, file_name, format)
    if not library_dir or not book_path or not file_name or not format then
        return nil
    end
    local full_path = string.format("%s/%s/%s.%s",
        library_dir, book_path, file_name, format:lower())
    if lfs.attributes(full_path, "mode") == "file" then
        return full_path
    end
    return nil
end

return CalibreDB
