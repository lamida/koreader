--[[--
Browse a calibre library catalog directly from its `metadata.db` and open books
with KOReader's internal reader.

This complements `calibre.koplugin`: instead of the wireless transfer / metadata
search, it points at a calibre library folder on disk (the one holding
metadata.db plus the per-author/title subfolders) and lists the whole catalog.
Selecting a book resolves its file and opens it in the reader.

@module koplugin.calibrelibrary
--]]

local BookList = require("ui/widget/booklist")
local ButtonDialog = require("ui/widget/buttondialog")
local CalibreDB = require("db")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local _ = require("gettext")
local T = require("ffi/util").template

-- Persisted settings keys.
local SETTING_LIBRARY_DIR = "calibre_catalog_library_dir"
local SETTING_SORT_FIELD = "calibre_catalog_sort_field"
local SETTING_SORT_ASCENDING = "calibre_catalog_sort_ascending"
local SETTING_PREFERRED_FORMAT = "calibre_catalog_preferred_format"

-- Sort fields exposed in the UI, in display order. `key` matches CalibreDB.sort_fields.
local SORT_OPTIONS = {
    { key = "title",     label = _("Title") },
    { key = "timestamp", label = _("Date added") },
    { key = "pubdate",   label = _("Published date") },
}

local CalibreLibrary = WidgetContainer:extend{
    name = "calibrelibrary",
    is_doc_only = false,
}

function CalibreLibrary:onDispatcherRegisterActions()
    Dispatcher:registerAction("calibre_catalog_browse",
        { category="none", event="ShowCalibreCatalog", title=_("Browse calibre library"), general=true })
end

function CalibreLibrary:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

-- Settings accessors. {{{

function CalibreLibrary:getLibraryDir()
    return G_reader_settings:readSetting(SETTING_LIBRARY_DIR)
end

function CalibreLibrary:getSortField()
    return G_reader_settings:readSetting(SETTING_SORT_FIELD) or "title"
end

function CalibreLibrary:isSortAscending()
    return G_reader_settings:nilOrTrue(SETTING_SORT_ASCENDING)
end

function CalibreLibrary:getPreferredFormat()
    return G_reader_settings:readSetting(SETTING_PREFERRED_FORMAT) or "ask"
end

-- }}}

function CalibreLibrary:onShowCalibreCatalog()
    self:browse()
    return true
end

function CalibreLibrary:addToMainMenu(menu_items)
    menu_items.calibre_catalog = {
        text = _("Calibre library"),
        sub_item_table = {
            {
                text = _("Browse library"),
                enabled_func = function()
                    return CalibreDB:isAvailable(self:getLibraryDir())
                end,
                callback = function()
                    self:browse()
                end,
            },
            {
                text_func = function()
                    local dir = self:getLibraryDir()
                    return dir and T(_("Library folder: %1"), dir) or _("Set library folder")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:setLibraryDir(touchmenu_instance)
                end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Sort by: %1"), self:getCurrentSortLabel())
                end,
                keep_menu_open = true,
                sub_item_table_func = function()
                    return self:getSortMenuTable()
                end,
            },
            {
                text_func = function()
                    return T(_("Preferred format: %1"), self:getPreferredFormatLabel())
                end,
                keep_menu_open = true,
                sub_item_table_func = function()
                    return self:getPreferredFormatMenuTable()
                end,
            },
        },
    }
end

function CalibreLibrary:getCurrentSortLabel()
    local field = self:getSortField()
    for _, opt in ipairs(SORT_OPTIONS) do
        if opt.key == field then
            return opt.label
        end
    end
    return SORT_OPTIONS[1].label
end

function CalibreLibrary:getSortMenuTable()
    local items = {}
    for _, opt in ipairs(SORT_OPTIONS) do
        table.insert(items, {
            text = opt.label,
            checked_func = function()
                return self:getSortField() == opt.key
            end,
            callback = function()
                G_reader_settings:saveSetting(SETTING_SORT_FIELD, opt.key)
            end,
        })
    end
    items[#items].separator = true
    table.insert(items, {
        text = _("Reverse sort order"),
        checked_func = function()
            return not self:isSortAscending()
        end,
        callback = function()
            G_reader_settings:saveSetting(SETTING_SORT_ASCENDING, not self:isSortAscending())
        end,
    })
    return items
end

function CalibreLibrary:getPreferredFormatLabel()
    local pref = self:getPreferredFormat()
    if pref == "ask" then
        return _("Ask")
    end
    return pref
end

function CalibreLibrary:getPreferredFormatMenuTable()
    local options = { "ask" }
    for _, format in ipairs(CalibreDB.supported_formats) do
        table.insert(options, format)
    end
    local items = {}
    for _, opt in ipairs(options) do
        table.insert(items, {
            text = opt == "ask" and _("Ask each time") or opt,
            checked_func = function()
                return self:getPreferredFormat() == opt
            end,
            radio = true,
            callback = function()
                G_reader_settings:saveSetting(SETTING_PREFERRED_FORMAT, opt)
            end,
        })
    end
    return items
end

function CalibreLibrary:setLibraryDir(touchmenu_instance)
    require("ui/downloadmgr"):new{
        onConfirm = function(dir)
            if not CalibreDB:isAvailable(dir) then
                UIManager:show(InfoMessage:new{
                    text = T(_("No metadata.db found in:\n%1\n\nSelect the root folder of your calibre library."), dir),
                })
                return
            end
            G_reader_settings:saveSetting(SETTING_LIBRARY_DIR, dir)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }:chooseDir(self:getLibraryDir())
end

-- Catalog listing. {{{

function CalibreLibrary:browse()
    local library_dir = self:getLibraryDir()
    if not CalibreDB:isAvailable(library_dir) then
        UIManager:show(InfoMessage:new{
            text = _("No calibre library configured. Set the library folder first."),
        })
        return
    end

    self.catalog_menu = BookList:new{
        name = "calibre_catalog",
        title = _("Calibre library"),
        title_bar_left_icon = "appbar.search",
        onLeftButtonTap = function()
            self:showOptions()
        end,
        -- Override selection so the menu is not auto-closed before we have
        -- (optionally) prompted for a format.
        onMenuSelect = function(_self, item)
            self:openBook(item.book)
            return true
        end,
        onMenuHold = function(_self, item)
            self:onBookHold(item)
            return true
        end,
        ui = self.ui,
    }
    self.catalog_menu.close_callback = function()
        UIManager:close(self.catalog_menu)
        self.catalog_menu = nil
    end
    self:updateCatalog()
    UIManager:show(self.catalog_menu)
end

--- Re-query the catalog with the current filter / sort and refresh the list.
function CalibreLibrary:updateCatalog()
    if not self.catalog_menu then return end
    local books = CalibreDB:queryBooks(self:getLibraryDir(), {
        search_query = self.search_query,
        sort_field = self:getSortField(),
        ascending = self:isSortAscending(),
    })

    local item_table = {}
    for _, book in ipairs(books) do
        table.insert(item_table, {
            text = T("%1 - %2", book.title, book.authors),
            book = book,
        })
    end

    local title
    if self.search_query and self.search_query ~= "" then
        title = T(_("Calibre library: \"%1\" (%2)"), self.search_query, #item_table)
    else
        title = T(_("Calibre library (%1)"), #item_table)
    end
    self.catalog_menu:switchItemTable(title, item_table, -1)
end

--- In-list options: filter by text and change sort order.
function CalibreLibrary:showOptions()
    local buttons = {
        {
            {
                text = _("Filter"),
                callback = function()
                    UIManager:close(self.options_dialog)
                    self:showSearchDialog()
                end,
            },
            {
                text = self:isSortAscending() and _("Reverse order ↓") or _("Reverse order ↑"),
                callback = function()
                    UIManager:close(self.options_dialog)
                    G_reader_settings:saveSetting(SETTING_SORT_ASCENDING, not self:isSortAscending())
                    self:updateCatalog()
                end,
            },
        },
    }
    for _, opt in ipairs(SORT_OPTIONS) do
        local is_current = self:getSortField() == opt.key
        buttons[#buttons + 1] = {
            {
                text = (is_current and "✓ " or "") .. T(_("Sort by %1"), opt.label),
                callback = function()
                    UIManager:close(self.options_dialog)
                    G_reader_settings:saveSetting(SETTING_SORT_FIELD, opt.key)
                    self:updateCatalog()
                end,
            },
        }
    end
    if self.search_query and self.search_query ~= "" then
        buttons[#buttons + 1] = {
            {
                text = _("Clear filter"),
                callback = function()
                    UIManager:close(self.options_dialog)
                    self.search_query = nil
                    self:updateCatalog()
                end,
            },
        }
    end
    self.options_dialog = ButtonDialog:new{
        title = _("Catalog options"),
        buttons = buttons,
    }
    UIManager:show(self.options_dialog)
end

function CalibreLibrary:showSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Filter by title or author"),
        input = self.search_query or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Filter"),
                    is_enter_default = true,
                    callback = function()
                        local query = dialog:getInputText()
                        self.search_query = query ~= "" and query or nil
                        UIManager:close(dialog)
                        self:updateCatalog()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CalibreLibrary:onBookHold(item)
    local book = item.book
    if not book then return end
    local formats = {}
    for _, f in ipairs(book.formats) do
        table.insert(formats, f.format)
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Title: %1\nAuthor(s): %2\nFormats: %3\nPath: %4"),
            book.title, book.authors, table.concat(formats, ", "), book.path),
    })
    return true
end

-- }}}

-- Opening a book. {{{

--- Pick a format for `book` honoring the preferred-format setting; prompts when
--- several formats are available and no usable preference is set.
function CalibreLibrary:openBook(book)
    if #book.formats == 0 then
        UIManager:show(InfoMessage:new{ text = _("This book has no supported format.") })
        return
    end
    if #book.formats == 1 then
        self:openFormat(book, book.formats[1])
        return
    end

    local preferred = self:getPreferredFormat()
    if preferred ~= "ask" then
        for _, format in ipairs(book.formats) do
            if format.format == preferred then
                self:openFormat(book, format)
                return
            end
        end
    end

    -- Multiple formats and no usable preference: ask.
    local buttons = {}
    for _, format in ipairs(book.formats) do
        buttons[#buttons + 1] = {
            {
                text = format.format,
                callback = function()
                    UIManager:close(self.format_dialog)
                    self:openFormat(book, format)
                end,
            },
        }
    end
    self.format_dialog = ButtonDialog:new{
        title = T(_("Open \"%1\" as:"), book.title),
        buttons = buttons,
    }
    UIManager:show(self.format_dialog)
end

function CalibreLibrary:openFormat(book, format)
    local file_path = CalibreDB:resolveBookPath(self:getLibraryDir(), book.path, format.name, format.format)
    if not file_path then
        UIManager:show(InfoMessage:new{
            text = T(_("Could not find the book file on disk:\n%1/%2.%3"),
                book.path, format.name, format.format:lower()),
        })
        return
    end
    local close_callback = self.catalog_menu and self.catalog_menu.close_callback
    filemanagerutil.openFile(self.ui, file_path, close_callback)
end

-- }}}

return CalibreLibrary
