describe("Calibre library db module", function()
    local CalibreDB, SQ3, lfs, DataStorage
    local orig_path
    local library_dir

    -- Build a minimal calibre-like metadata.db plus the on-disk book files.
    local function setupLibrary(dir)
        lfs.mkdir(dir)
        local db_path = dir .. "/metadata.db"
        os.remove(db_path)
        local conn = SQ3.open(db_path)
        conn:exec([[
            CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, path TEXT,
                pubdate TEXT, timestamp TEXT);
            CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books_authors_link (id INTEGER PRIMARY KEY, book INTEGER, author INTEGER);
            CREATE TABLE data (id INTEGER PRIMARY KEY, book INTEGER, format TEXT, name TEXT);

            INSERT INTO books VALUES (1, 'Alpha', 'Jane Roe/Alpha (1)', '2020-01-01', '2021-01-01');
            INSERT INTO books VALUES (2, 'Beta',  'John Doe/Beta (2)',  '2019-01-01', '2022-01-01');
            INSERT INTO books VALUES (3, 'Gamma', 'John Doe/Gamma (3)', '2018-01-01', '2020-01-01');
            -- Mobi-only book: must be hidden (no supported format).
            INSERT INTO books VALUES (4, 'Delta', 'No One/Delta (4)',   '2017-01-01', '2019-01-01');

            INSERT INTO authors VALUES (1, 'Jane Roe');
            INSERT INTO authors VALUES (2, 'John Doe');
            INSERT INTO authors VALUES (3, 'No One');

            INSERT INTO books_authors_link VALUES (1, 1, 1);
            INSERT INTO books_authors_link VALUES (2, 2, 2);
            INSERT INTO books_authors_link VALUES (3, 3, 2);
            INSERT INTO books_authors_link VALUES (4, 4, 3);

            INSERT INTO data VALUES (1, 1, 'EPUB', 'Alpha - Jane Roe');
            INSERT INTO data VALUES (2, 1, 'PDF',  'Alpha - Jane Roe');
            INSERT INTO data VALUES (3, 2, 'EPUB', 'Beta - John Doe');
            INSERT INTO data VALUES (4, 3, 'PDF',  'Gamma - John Doe');
            INSERT INTO data VALUES (5, 4, 'MOBI', 'Delta - No One');
        ]])
        conn:close()

        -- Create the actual files for book 1 (EPUB) so resolveBookPath can find it.
        local book_dir = dir .. "/Jane Roe/Alpha (1)"
        lfs.mkdir(dir .. "/Jane Roe")
        lfs.mkdir(book_dir)
        local fh = io.open(book_dir .. "/Alpha - Jane Roe.epub", "w")
        fh:write("dummy")
        fh:close()
    end

    setup(function()
        orig_path = package.path
        package.path = "plugins/calibrelibrary.koplugin/?.lua;" .. package.path
        require("commonrequire")
        SQ3 = require("lua-ljsqlite3/init")
        lfs = require("libs/libkoreader-lfs")
        DataStorage = require("datastorage")
        CalibreDB = require("db")

        library_dir = DataStorage:getDataDir() .. "/calibre-test-library"
        setupLibrary(library_dir)
    end)

    teardown(function()
        package.path = orig_path
    end)

    it("reports availability of metadata.db", function()
        assert.is_true(CalibreDB:isAvailable(library_dir))
        assert.is_false(CalibreDB:isAvailable(library_dir .. "/nope"))
        assert.is_false(CalibreDB:isAvailable(nil))
    end)

    it("lists only books with a supported format", function()
        local books = CalibreDB:queryBooks(library_dir)
        assert.are.equal(3, #books) -- Delta (mobi-only) is excluded
        local titles = {}
        for _, b in ipairs(books) do
            titles[b.title] = true
        end
        assert.is_true(titles["Alpha"])
        assert.is_true(titles["Beta"])
        assert.is_true(titles["Gamma"])
        assert.is_nil(titles["Delta"])
    end)

    it("parses authors and formats", function()
        local books = CalibreDB:queryBooks(library_dir, { sort_field = "title", ascending = true })
        local alpha = books[1]
        assert.are.equal("Alpha", alpha.title)
        assert.are.equal("Jane Roe", alpha.authors)
        assert.are.equal(2, #alpha.formats)
        local formats = {}
        for _, f in ipairs(alpha.formats) do
            formats[f.format] = f.name
        end
        assert.are.equal("Alpha - Jane Roe", formats["EPUB"])
        assert.are.equal("Alpha - Jane Roe", formats["PDF"])
    end)

    it("sorts by title ascending and descending", function()
        local asc = CalibreDB:queryBooks(library_dir, { sort_field = "title", ascending = true })
        assert.are.equal("Alpha", asc[1].title)
        assert.are.equal("Gamma", asc[3].title)

        local desc = CalibreDB:queryBooks(library_dir, { sort_field = "title", ascending = false })
        assert.are.equal("Gamma", desc[1].title)
        assert.are.equal("Alpha", desc[3].title)
    end)

    it("sorts by date added", function()
        local books = CalibreDB:queryBooks(library_dir, { sort_field = "timestamp", ascending = true })
        -- timestamps: Gamma 2020, Alpha 2021, Beta 2022
        assert.are.equal("Gamma", books[1].title)
        assert.are.equal("Alpha", books[2].title)
        assert.are.equal("Beta", books[3].title)
    end)

    it("filters by title", function()
        local books = CalibreDB:queryBooks(library_dir, { search_query = "Alph" })
        assert.are.equal(1, #books)
        assert.are.equal("Alpha", books[1].title)
    end)

    it("filters by author", function()
        local books = CalibreDB:queryBooks(library_dir, { search_query = "John Doe" })
        assert.are.equal(2, #books) -- Beta and Gamma
    end)

    it("resolves an existing book file", function()
        local path = CalibreDB:resolveBookPath(library_dir, "Jane Roe/Alpha (1)", "Alpha - Jane Roe", "EPUB")
        assert.is_not_nil(path)
        assert.is_truthy(path:match("Alpha %- Jane Roe%.epub$"))
    end)

    it("returns nil for a missing book file", function()
        local path = CalibreDB:resolveBookPath(library_dir, "Jane Roe/Alpha (1)", "Alpha - Jane Roe", "PDF")
        assert.is_nil(path) -- only the epub was created on disk
    end)
end)
