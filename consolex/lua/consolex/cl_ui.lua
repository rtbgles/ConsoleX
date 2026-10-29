if not CLIENT then return end

if not vgui.GetControlTable( "CNSXFrame" ) then
    include( "consolex/cl_elements.lua" )
end

local function make( class, parent, fallback )
    local pnl = vgui.Create( vgui.GetControlTable( class ) and class or ( fallback or "DPanel" ), parent )
    if not IsValid( pnl ) then
        pnl = vgui.Create( fallback or "DPanel", parent )
    end
    if IsValid( pnl ) and pnl.SetTextColor then
        pnl:SetTextColor( Color( 230, 238, 255 ) )
    end

    return pnl
end

local frame
local tabs = {}
local active = 0
local minimized = false
local rest = { w = 1100, h = 720, x = 40, y = 40 }
local editor
local tree
local logBox
local pathEntry
local rootBox
local playerBox
local statusLbl
local sessionLbl
local listBtn

local nextTabId = 0
local cursorText = ""
local lastActivity = 0
local serverDirty = false
local lintText = ""
local history = {}
local grepJob

local DEFAULT_BODY = "-- CNSX\nprint( 'hello' )\n"
local HISTORY_MAX = 40
local HISTORY_CODE_MAX = 20000
local LOG_MAX = 48000
local SERVER_SYNC_SECS = 60

local ROOT_LABEL = {
    data = "server DATA",
    game = "server GAME",
    lua = "server LUA",
    mine = "my DATA",
    remote = "player DATA"
}

-- ---------- prefs ----------

local function defaultPrefs()
    return {
        w = 1100,
        h = 720,
        sounds = true,
        banner = true,
        blur = true,
        grain = true,
        fontSize = 13,
        theme = "twilight",
        wrap = true,
        lint = true,
        autosave = false,
        runSelection = true
    }
end

local function loadPrefs()
    local data = CNSX.Decode( file.Read( "consolex/prefs.json", "DATA" ) )
    local prefs = defaultPrefs()
    for k, v in pairs( data ) do
        prefs[k] = v
    end
    CNSX.Prefs = prefs

    return prefs
end

local function savePrefs()
    file.CreateDir( "consolex" )
    file.Write( "consolex/prefs.json", CNSX.Encode( CNSX.Prefs or defaultPrefs() ) )
end

local function prefs()
    return CNSX.Prefs or loadPrefs()
end

local function sfx( name )
    if prefs().sounds == false then
        return
    end
    surface.PlaySound( name )
end

-- ---------- log / status ----------

local function logLine( text, bad )
    if not IsValid( logBox ) then
        if bad then
            MsgC( Color( 255, 90, 90 ), "[CNSX] ", tostring( text ), "\n" )
        end
        return
    end
    text = tostring( text )
    if bad and not string.find( text, "^ERR" ) then
        text = "[!] " .. text
    end
    local all = logBox:GetText() .. os.date( "%H:%M:%S " ) .. text .. "\n"
    if #all > LOG_MAX then
        all = string.sub( all, -LOG_MAX )
        all = string.match( all, "\n(.*)$" ) or all
    end
    logBox:SetText( all )
    logBox:SetCaretPos( #all )
end
CNSX.LogLine = logLine

local function current()
    return tabs[active]
end

local function updateStatus()
    if not IsValid( statusLbl ) then
        return
    end
    local tab = current()
    local parts = {}
    if tab then
        parts[#parts + 1] = ( ROOT_LABEL[tab.root] or tab.root or "?" ) .. " / " .. ( tab.path ~= "" and tab.path or "(unsaved)" )
        if tab.readOnly then
            parts[#parts + 1] = "read-only"
        elseif tab.dirty then
            parts[#parts + 1] = "modified"
        end
    end
    if cursorText ~= "" then
        parts[#parts + 1] = cursorText
    end
    if lintText ~= "" then
        parts[#parts + 1] = lintText
    end
    statusLbl:SetText( table.concat( parts, "   |   " ) )
    statusLbl:SetTextColor( lintText ~= "" and CNSX.Theme.err or CNSX.Theme.muted )
end

local function setStatus( text )
    if IsValid( statusLbl ) then
        statusLbl:SetText( text or "" )
        statusLbl:SetTextColor( CNSX.Theme.muted )
    end
end

-- ---------- network ----------

local function send( act, extra )
    extra = extra or {}
    extra.act = act
    local packed, err = CNSX.Pack( extra )
    if not packed then
        if act ~= "tabs" then
            logLine( act .. " not sent: " .. tostring( err ), true )
        end
        return false, err
    end
    net.Start( "CNSX_Cmd" )
        CNSX.NetWritePacked( packed )
    net.SendToServer()
    if act ~= "session" and act ~= "tabs" then
        lastActivity = RealTime()
    end

    return true
end

-- the server's idle window and hard cap; the countdown runs from our last command
local function setSession( info )
    if not istable( info ) then
        return
    end
    CNSX._idle = tonumber( info.idle ) or 0
    CNSX._hardAt = RealTime() + ( tonumber( info.hard ) or 0 )
    lastActivity = RealTime()
end

local function setBusy( open )
    send( "session", {
        open = open and true or false,
        silent = prefs().sounds == false
    } )
end

-- ---------- editor bridge ----------

local function editorReady()
    return IsValid( editor ) and editor._ready == true
end

local function editorJS( code )
    if editorReady() then
        editor:RunJavascript( code )
    end
end

local function jsQuote( s )
    return string.sub( util.TableToJSON( { tostring( s or "" ) } ) or "[\"\"]", 2, -2 )
end

local function jsBool( b )
    return b and "true" or "false"
end

-- every caller wants the live editor text; one JS round trip answers all queued callers
-- the text belongs to the tab that was showing when it was requested; a reply for an older request
-- (after the timeout fallback already answered) is dropped
local pullQueue = {}
local pullSeq = 0
local pullTab

local function flushPull( all, sel, seq )
    if seq ~= nil and seq ~= pullSeq then
        return
    end
    if #pullQueue == 0 then
        return
    end
    local queue = pullQueue
    local tab = pullTab
    pullQueue = {}
    pullTab = nil
    -- invalidate this request so a late reply can't land anywhere
    pullSeq = pullSeq + 1
    if tab and all ~= nil and not tab.readOnly then
        tab.body = all
        tab.dirty = tab.body ~= tab.saved
    end
    for _, cb in ipairs( queue ) do
        cb( tab and tab.body or "", sel or "" )
    end
end

local function pullBody( cb )
    if not editorReady() then
        local tab = current()
        cb( tab and tab.body or "", "" )
        return
    end
    pullQueue[#pullQueue + 1] = cb
    if #pullQueue > 1 then
        return
    end
    pullSeq = pullSeq + 1
    pullTab = current()
    local seq = pullSeq
    editor:RunJavascript( "if(window.cnsxCode)cnsxCode(" .. seq .. ");" )
    timer.Simple( 0.5, function()
        if seq == pullSeq then
            flushPull( nil, nil, seq )
        end
    end )
end

local function gotoLine( n, msg )
    n = tonumber( n )
    if not n then
        return
    end
    n = math.max( 1, math.floor( n ) )
    if msg then
        editorJS( "if(window.cnsxMark)cnsxMark(" .. n .. "," .. jsQuote( msg ) .. ");" )
    else
        editorJS( "if(window.cnsxGoto)cnsxGoto(" .. n .. ");" )
    end
end

local function showTab( tab, force )
    if not tab then
        return
    end
    if editorReady() then
        local known = editor._sessions[tab.id]
        local body = ( force or not known ) and ( tab.body or "" ) or ""
        editor:RunJavascript( "if(window.cnsxOpen)cnsxOpen(" .. jsQuote( tab.id ) .. "," .. jsQuote( body ) .. "," .. jsQuote( CNSX.AceMode( tab.mode ) ) .. "," .. jsBool( force and known ) .. "," .. jsBool( tab.readOnly ) .. ");" )
        editor._sessions[tab.id] = true
    end
    if IsValid( pathEntry ) and tab.path ~= "" and tab.root ~= "remote" then
        pathEntry:SetText( tab.path )
    end
    lintText = ""
    updateStatus()
end

-- ---------- tabs ----------

local function newId()
    nextTabId = nextTabId + 1

    return "t" .. nextTabId
end

local function tabTitle( tab )
    local title = tostring( tab.title or "untitled" )
    if #title > 18 then
        title = string.sub( title, 1, 17 ) .. "~"
    end
    if tab.readOnly then
        title = title .. " [ro]"
    elseif tab.dirty then
        title = "* " .. title
    end

    return title
end

local function repaintTabs()
    if IsValid( frame ) and frame.PaintTabs then
        frame.PaintTabs()
    end
    updateStatus()
end

local function indexOfTab( tab )
    for i, t in ipairs( tabs ) do
        if t == tab then
            return i
        end
    end
end

local function tabById( id )
    for _, t in ipairs( tabs ) do
        if t.id == id then
            return t
        end
    end
end

local function makeTab( row )
    row = row or {}
    local body = tostring( row.body or "" )
    local tab = {
        id = newId(),
        title = tostring( row.title or "untitled.lua" ),
        body = body,
        path = tostring( row.path or "" ),
        root = tostring( row.root or "data" ),
        sid = row.sid,
        mode = tostring( row.mode or "lua" ),
        readOnly = row.readOnly == true
    }
    tab.saved = row.dirty and false or body
    tab.dirty = row.dirty == true

    return tab
end

local function tabsBlob()
    local blob = {}
    for _, tab in ipairs( tabs ) do
        blob[#blob + 1] = {
            title = tab.title,
            path = tab.path,
            root = tab.root,
            sid = tab.sid,
            mode = tab.mode,
            body = tab.body or "",
            dirty = tab.dirty or nil,
            readOnly = tab.readOnly or nil
        }
    end

    return blob
end

-- drafts: every tab is kept in DATA/consolex/session.json on this PC, and backed up to the server now and then
local draftT = 0

local function saveDraft()
    draftT = os.time()
    file.CreateDir( "consolex" )
    file.Write( "consolex/session.json", CNSX.Encode( { tabs = tabsBlob(), active = active, t = draftT } ) )
    serverDirty = true
end

local SERVER_TAB_MAX = 32 * 1024

local function syncServer( force )
    if not serverDirty and not force then
        return
    end
    serverDirty = false
    if send( "tabs", { tabs = tabsBlob(), ct = draftT } ) then
        return
    end
    -- too big for one message: back up the tabs that fit, the rest stay in the local drafts only
    local small = {}
    for _, row in ipairs( tabsBlob() ) do
        if #row.body <= SERVER_TAB_MAX then
            small[#small + 1] = row
        end
    end
    local ok = send( "tabs", { tabs = small, ct = draftT, partial = true } )
    if not CNSX._warnedTabs then
        CNSX._warnedTabs = true
        logLine( ok and "large tabs are not backed up to the server; they are still saved on this PC" or "tabs are too large for the server backup; they are still saved on this PC", true )
    end
end

local function loadLocalSession()
    local data = CNSX.Decode( file.Read( "consolex/session.json", "DATA" ) )
    if istable( data.tabs ) and #data.tabs > 0 then
        return data.tabs, tonumber( data.active ) or 1, tonumber( data.t ) or 0
    end
end

local function selectTab( i )
    local target = tabs[i]
    if not target then
        return
    end
    pullBody( function()
        -- the list may have changed while the editor text was on its way
        local idx = indexOfTab( target )
        if not idx then
            return
        end
        active = idx
        showTab( target )
        saveDraft()
        repaintTabs()
    end )
end

local function addTab( title, body, path, root, mode, extra )
    path = path or ""
    root = root or "data"
    if path ~= "" then
        for i, tab in ipairs( tabs ) do
            if tab.path == path and tab.root == root and ( root ~= "remote" or tab.sid == ( extra and extra.sid ) ) then
                logLine( "already open: " .. path .. " (close the tab to reload it)" )
                selectTab( i )
                return tab
            end
        end
    end
    local row = { title = title, body = body or DEFAULT_BODY, path = path, root = root, mode = mode }
    for k, v in pairs( extra or {} ) do
        row[k] = v
    end
    local tab = makeTab( row )
    tabs[#tabs + 1] = tab
    selectTab( #tabs )

    return tab
end

local function removeTab( tab )
    local idx = indexOfTab( tab )
    if not idx then
        return
    end
    table.remove( tabs, idx )
    if #tabs == 0 then
        tabs[1] = makeTab( { title = "untitled.lua", body = DEFAULT_BODY } )
        active = 1
    elseif idx < active then
        active = active - 1
    elseif idx == active then
        active = math.min( idx, #tabs )
    end
    -- switch the editor away before freeing the closed tab's session
    showTab( tabs[active] )
    editorJS( "if(window.cnsxDrop)cnsxDrop(" .. jsQuote( tab.id ) .. ");" )
    if editorReady() then
        editor._sessions[tab.id] = nil
    end
    saveDraft()
    repaintTabs()
end

local saveTab
local saveAs

local function closeTab( i, force )
    local tab = tabs[i]
    if not tab then
        return
    end
    pullBody( function()
        if tab.dirty and not force then
            Derma_Query( "\"" .. tostring( tab.title ) .. "\" has unsaved changes.", "CNSX  close tab",
                "Save", function()
                    tab.closeAfterSave = true
                    saveTab( tab )
                end,
                "Discard", function()
                    removeTab( tab )
                end,
                "Cancel" )
            return
        end
        removeTab( tab )
    end )
end

local function markSaved( tab, path, root, body )
    tab.path = path
    tab.root = root
    tab.saved = body
    tab.dirty = tab.body ~= body
    tab.title = string.GetFileFromFilename( path )
    local mode = CNSX.GuessMode( path )
    if mode ~= tab.mode then
        tab.mode = mode
        if tab == current() then
            editorJS( "if(window.cnsxMode)cnsxMode(" .. jsQuote( CNSX.AceMode( mode ) ) .. ");" )
        end
    end
    repaintTabs()
    saveDraft()
    if tab.closeAfterSave then
        tab.closeAfterSave = nil
        removeTab( tab )
    end
end

local function comboData( box )
    if not IsValid( box ) then
        return nil
    end
    local id = box:GetSelectedID()
    if id then
        return box:GetOptionData( id )
    end
    local _, data = box:GetSelected()

    return data
end

-- writes tab.body to its file (tab.body must be fresh: call from inside pullBody). opts: path, root, sid, auto
saveTab = function( tab, opts )
    opts = opts or {}
    local root = opts.root or tab.root
    local path = opts.path or tab.path
    if tab.readOnly then
        logLine( tab.title .. " is read-only (it was truncated when opened); nothing saved", true )
        tab.closeAfterSave = nil
        return
    end
    if path == "" or root == "game" or root == "lua" then
        if opts.auto then
            return
        end
        saveAs( tab )
        return
    end
    local body = tab.body or ""
    if root == "mine" then
        if opts.create and file.Exists( CNSX.WritablePath( path ), "DATA" ) then
            logLine( "my DATA/" .. CNSX.WritablePath( path ) .. " already exists", true )
            return
        end
        local ok, final, err = CNSX.WriteData( path, body )
        logLine( ok and ( ( opts.auto and "autosaved" or "saved" ) .. " my DATA/" .. final ) or ( "local save failed: " .. tostring( err ) ), not ok )
        if ok then
            markSaved( tab, final, "mine", body )
        else
            tab.closeAfterSave = nil
        end
        return
    end
    if root == "remote" then
        local sid = opts.sid or tab.sid or comboData( playerBox )
        if not sid then
            logLine( "pick a player first", true )
            tab.closeAfterSave = nil
            return
        end
        tab.pendingSid = sid
        tab.pendingBody = body
        if send( "remote_write", { sid = sid, path = path, body = body, tabId = tab.id } ) then
            logLine( "saving to player DATA/" .. CNSX.WritablePath( path ) )
        else
            tab.pendingBody = nil
            tab.closeAfterSave = nil
        end
        return
    end
    tab.pendingBody = body
    if send( "write", { path = path, body = body, tabId = tab.id, auto = opts.auto or nil, create = opts.create or nil } ) then
        if not opts.auto then
            logLine( "saving server DATA/" .. CNSX.WritablePath( path ) )
        end
    else
        tab.pendingBody = nil
        tab.closeAfterSave = nil
    end
end

saveAs = function( tab )
    local browse = comboData( rootBox ) or "data"
    local root = tab.root
    if root ~= "data" and root ~= "mine" and root ~= "remote" then
        root = ( browse == "mine" or browse == "remote" ) and browse or "data"
    end
    local guess = tab.path
    if guess == "" or tab.root ~= root then
        local folder = IsValid( pathEntry ) and CNSX.SanitizePath( pathEntry:GetValue() ) or ""
        if string.GetExtensionFromFilename( folder ) then
            folder = string.TrimRight( string.GetPathFromFilename( folder ) or "", "/" )
        end
        guess = ( folder ~= "" and ( folder .. "/" ) or "consolex/" ) .. ( tab.path ~= "" and string.GetFileFromFilename( tab.path ) or tab.title )
    end
    Derma_StringRequest( "CNSX  save as", "Path in " .. ( ROOT_LABEL[root] or root ) .. "  (.lua and other blocked types get .txt appended)", guess, function( text )
        text = CNSX.SanitizePath( text )
        if text == "" then
            return
        end
        pullBody( function()
            saveTab( tab, { path = text, root = root } )
        end )
    end, function()
        tab.closeAfterSave = nil
    end, "Save", "Cancel" )
end

local function saveCurrent( as )
    pullBody( function()
        local tab = current()
        if not tab then
            return
        end
        if as then
            saveAs( tab )
        else
            saveTab( tab )
        end
    end )
end

-- ---------- history ----------

local function loadHistory()
    local data = CNSX.Decode( file.Read( "consolex/history.json", "DATA" ) )
    history = istable( data.list ) and data.list or {}
end

local function pushHistory( act, code )
    if code == "" then
        return
    end
    for i = #history, 1, -1 do
        if history[i].code == code then
            table.remove( history, i )
        end
    end
    table.insert( history, 1, { act = act, code = string.sub( code, 1, HISTORY_CODE_MAX ), t = os.time() } )
    while #history > HISTORY_MAX do
        history[#history] = nil
    end
    file.CreateDir( "consolex" )
    file.Write( "consolex/history.json", CNSX.Encode( { list = history } ) )
end

local function openHistoryMenu()
    if #history == 0 then
        logLine( "no run history yet" )
        return
    end
    local menu = DermaMenu()
    for i, row in ipairs( history ) do
        if i > 25 then
            break
        end
        local first = string.match( tostring( row.code ), "^%s*([^\n]*)" ) or ""
        if #first > 48 then
            first = string.sub( first, 1, 47 ) .. "~"
        end
        menu:AddOption( os.date( "%H:%M", tonumber( row.t ) or 0 ) .. "  " .. tostring( row.act ) .. "  " .. first, function()
            addTab( "history.lua", row.code, "", "data", "lua" )
        end )
    end
    menu:AddSpacer()
    menu:AddOption( "Clear history", function()
        history = {}
        file.Write( "consolex/history.json", CNSX.Encode( { list = {} } ) )
    end )
    menu:Open()
end

-- ---------- run ----------

local lastRunSelection = false

local function runAct( act, extra )
    pullBody( function( code, sel )
        local src = code
        lastRunSelection = false
        if sel ~= "" and prefs().runSelection ~= false then
            src = sel
            lastRunSelection = true
        end
        if string.Trim( src ) == "" then
            logLine( "nothing to run", true )
            return
        end
        extra = extra or {}
        extra.code = src
        if act ~= "check" then
            pushHistory( act, src )
        end
        editorJS( "if(window.cnsxClearMarks)cnsxClearMarks();" )
        if lastRunSelection then
            logLine( "> " .. act .. " (selection, " .. #src .. " bytes)" )
        end
        send( act, extra )
    end )
end

local function showOutput( out )
    out = tostring( out or "" )
    if out == "" then
        return
    end
    out = string.gsub( out, "\n$", "" )
    for line in string.gmatch( out .. "\n", "([^\n]*)\n" ) do
        logLine( "  | " .. line )
    end
end

local function showRun( data )
    showOutput( data.out )
    local msg = tostring( data.msg or data.err or "" )
    logLine( ( data.ok and "OK " or "ERR " ) .. tostring( data.realm ) .. " " .. msg, not data.ok )
    if isfunction( CNSX.FlashRim ) then
        CNSX.FlashRim( data.ok == true )
    end
    if not data.ok and not lastRunSelection then
        local n = CNSX.ParseErrLine( msg )
        if n then
            gotoLine( n, string.match( msg, "^[^\n]*" ) )
        end
    end
end

-- ---------- lint / drafts ----------

local function runLint()
    local tab = current()
    if not tab or tab.mode ~= "lua" or prefs().lint == false then
        if lintText ~= "" then
            lintText = ""
            editorJS( "if(window.cnsxLint)cnsxLint(0);" )
            updateStatus()
        end
        return
    end
    pullBody( function( code )
        local line, msg = CNSX.LintLua( code )
        editorJS( "if(window.cnsxLint)cnsxLint(" .. ( line or 0 ) .. "," .. jsQuote( msg or "" ) .. ");" )
        lintText = line and ( "syntax error line " .. line ) or ""
        updateStatus()
    end )
end

local function autosaveFile()
    local tab = current()
    if prefs().autosave ~= true or not tab or not tab.dirty or tab.readOnly or tab.path == "" then
        return
    end
    -- only the tab's own writable file; GAME/LUA/remote are never written behind your back
    if tab.root ~= "data" and tab.root ~= "mine" then
        return
    end
    -- a type file.Write refuses would be saved as name.ext.txt; never do that unasked
    if CNSX.WritablePath( tab.path ) ~= string.lower( tab.path ) then
        return
    end
    saveTab( tab, { auto = true } )
end

local function onEditorChanged()
    local tab = current()
    if tab and not tab.dirty and not tab.readOnly then
        tab.dirty = true
        repaintTabs()
    end
    timer.Create( "CNSX_Lint", 0.6, 1, runLint )
    timer.Create( "CNSX_Draft", 1.5, 1, function()
        pullBody( function()
            saveDraft()
            autosaveFile()
            repaintTabs()
        end )
    end )
end

-- ---------- lock prompt ----------

local function showLock( info )
    info = info or {}
    if IsValid( CNSX._lock ) then
        CNSX._lock:Close()
    end
    local minLen = tonumber( info.minLen ) or 8
    local win = vgui.Create( "DFrame" )
    win:SetSize( 380, 190 )
    win:Center()
    win:SetTitle( "" )
    win:ShowCloseButton( true )
    win:MakePopup()
    win:SetKeyboardInputEnabled( true )
    CNSX._lock = win
    win.Paint = function( self, w, h )
        draw.RoundedBox( 10, 0, 0, w, h, Color( 10, 14, 24, 250 ) )
        draw.RoundedBox( 10, 0, 0, w, 36, Color( 16, 28, 56 ) )
        draw.SimpleText( info.needSet and "CNSX  set master password" or "CNSX  unlock", "CNSX_Title", 16, 18, Color( 200, 220, 255 ), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
    end
    local msg = vgui.Create( "DLabel", win )
    msg:Dock( TOP )
    msg:DockMargin( 16, 44, 16, 0 )
    msg:SetTall( 22 )
    msg:SetText( info.err or ( info.needSet and ( "first launch — choose a password (" .. minLen .. "+ chars)" ) or "superadmin master password" ) )
    msg:SetTextColor( info.err and Color( 255, 90, 90 ) or Color( 160, 180, 210 ) )
    local ent = vgui.Create( "DTextEntry", win )
    ent:Dock( TOP )
    ent:DockMargin( 16, 8, 16, 0 )
    ent:SetTall( 28 )
    ent:SetPlaceholderText( "password" )
    -- DTextEntry has no password mode; paint bullets instead of the text so it isn't shown on screen/stream
    ent.Paint = function( self, w, h )
        draw.RoundedBox( 4, 0, 0, w, h, Color( 16, 16, 18 ) )
        surface.SetDrawColor( self:HasFocus() and Color( 56, 110, 220 ) or Color( 58, 58, 66 ) )
        surface.DrawOutlinedRect( 0, 0, w, h )
        local len = #( self:GetText() or "" )
        local shown = len > 0 and string.rep( "*", len ) or ( self:HasFocus() and "" or "password" )
        draw.SimpleText( shown, "DermaDefault", 6, h * 0.5, len > 0 and Color( 230, 238, 255 ) or Color( 140, 140, 148 ), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
        return true
    end
    local go = vgui.Create( "DButton", win )
    go:Dock( BOTTOM )
    go:DockMargin( 16, 8, 16, 12 )
    go:SetTall( 28 )
    go:SetText( info.needSet and "Set and enter" or "Unlock" )
    go:SetTextColor( Color( 230, 238, 255 ) )
    go.Paint = function( self, w, h )
        draw.RoundedBox( 6, 0, 0, w, h, self:IsHovered() and Color( 56, 110, 220 ) or Color( 30, 50, 90 ) )
    end
    local function submit()
        local pass = ent:GetValue() or ""
        if info.needSet and #pass < minLen then
            msg:SetText( "password too short (" .. minLen .. "+)" )
            msg:SetTextColor( Color( 255, 90, 90 ) )
            return
        end
        if pass == "" then
            msg:SetText( "enter the password" )
            msg:SetTextColor( Color( 255, 90, 90 ) )
            return
        end
        net.Start( "CNSX_Auth" )
            net.WriteUInt( 1, 2 )
            net.WriteString( pass )
        net.SendToServer()
        msg:SetText( "checking..." )
        msg:SetTextColor( Color( 160, 180, 210 ) )
        timer.Create( "CNSX_AuthWait", 4, 1, function()
            if IsValid( msg ) and msg:GetText() == "checking..." then
                msg:SetText( "no server reply — lua refresh / check console" )
                msg:SetTextColor( Color( 255, 90, 90 ) )
            end
        end )
    end
    go.DoClick = submit
    ent.OnEnter = submit
    ent:RequestFocus()
end

-- ---------- prefs window ----------

local function applySize()
    local p = prefs()
    rest.w = math.Clamp( tonumber( p.w ) or 1100, 720, 3840 )
    rest.h = math.Clamp( tonumber( p.h ) or 720, 420, 2160 )
    if IsValid( frame ) and not frame._maxed and not minimized then
        frame:SetSize( math.min( rest.w, ScrW() ), math.min( rest.h, ScrH() ) )
    end
end

local function applyEditorPrefs()
    editorJS( "if(window.cnsxPrefs)cnsxPrefs(" .. CNSX.Encode( CNSX.EditorPrefs( prefs() ) ) .. ");" )
end

local function openPrefs()
    if IsValid( CNSX._prefsFrame ) then
        CNSX._prefsFrame:MakePopup()
        return
    end
    local p = loadPrefs()
    local win = vgui.Create( vgui.GetControlTable( "CNSXFrame" ) and "CNSXFrame" or "DFrame" )
    win:SetSize( 400, 590 )
    win._subtitle = "preferences"
    win:Center()
    win:SetTitle( "" )
    win:ShowCloseButton( true )
    win:SetSizable( false )
    win:MakePopup()
    CNSX._prefsFrame = win
    win.OnClose = function()
        CNSX._prefsFrame = nil
    end

    local wrap = vgui.Create( "DPanel", win )
    wrap:Dock( FILL )
    wrap:DockMargin( 10, 8, 10, 10 )
    wrap.Paint = function() end

    local hint = vgui.Create( "DLabel", wrap )
    hint:Dock( TOP )
    hint:SetTall( 18 )
    hint:SetText( "toggles save immediately; size/font apply with the button" )
    hint:SetTextColor( Color( 140, 170, 220 ) )

    local function row( label )
        local r = vgui.Create( "DPanel", wrap )
        r:Dock( TOP )
        r:SetTall( 28 )
        r:DockMargin( 0, 4, 0, 0 )
        r.Paint = function() end
        local lab = vgui.Create( "DLabel", r )
        lab:Dock( LEFT )
        lab:SetWide( 170 )
        lab:SetText( label )
        lab:SetTextColor( Color( 220, 230, 255 ) )

        return r
    end

    local function numberRow( label, key )
        local ent = vgui.Create( "DTextEntry", row( label ) )
        ent:Dock( FILL )
        ent:SetNumeric( true )
        ent:SetText( tostring( p[key] ) )
        CNSX.SkinEntry( ent )

        return ent
    end
    local wEnt = numberRow( "Width", "w" )
    local hEnt = numberRow( "Height", "h" )
    local fEnt = numberRow( "Editor font size", "fontSize" )

    local themeBox = vgui.Create( "DComboBox", row( "Editor theme" ) )
    themeBox:Dock( FILL )
    themeBox:SetSortItems( false )
    for _, name in ipairs( CNSX.Themes ) do
        themeBox:AddChoice( name, name, name == p.theme )
    end
    CNSX.SkinCombo( themeBox )
    themeBox.OnSelect = function( _, _, _, data )
        p.theme = data
        CNSX.Prefs = p
        savePrefs()
        applyEditorPrefs()
    end

    local function commit()
        p.w = math.Clamp( tonumber( wEnt:GetValue() ) or p.w or 1100, 720, 3840 )
        p.h = math.Clamp( tonumber( hEnt:GetValue() ) or p.h or 720, 420, 2160 )
        p.fontSize = math.Clamp( math.floor( tonumber( fEnt:GetValue() ) or p.fontSize or 13 ), 9, 28 )
        CNSX.Prefs = p
        savePrefs()
        applySize()
        applyEditorPrefs()
    end

    local function toggle( name, key, tip, onChange )
        local r = row( name )
        r:SetTooltip( tip )
        local b = make( "CNSXButton", r, "DButton" )
        b:Dock( FILL )
        b:SetTooltip( tip )
        local function stamp()
            local on = p[key] == true or ( p[key] ~= false and defaultPrefs()[key] == true )
            b:SetText( on and "on" or "off" )
            if b.SetKind then
                b:SetKind( on and "on" or "default" )
            end
        end
        stamp()
        b.DoClick = function()
            local on = p[key] == true or ( p[key] ~= false and defaultPrefs()[key] == true )
            p[key] = not on
            CNSX.Prefs = p
            savePrefs()
            stamp()
            if onChange then
                onChange( p[key] )
            end
            if key == "sounds" and p.sounds then
                surface.PlaySound( "buttons/button14.wav" )
            end
        end
    end
    toggle( "Word wrap", "wrap", "Wrap long lines in the editor", applyEditorPrefs )
    toggle( "Live syntax check", "lint", "Compile Lua tabs locally as you type and mark the first syntax error (nothing is run)", function()
        runLint()
    end )
    toggle( "Run selection only", "runSelection", "When text is selected, Run/Check use only the selection" )
    toggle( "Autosave files", "autosave", "Also write the tab's own DATA file (server or mine) shortly after you stop typing. Drafts of every tab are always kept locally either way." )
    toggle( "Sounds", "sounds", "Pass/fail and window sounds" )
    toggle( "Overhead banner", "banner", "Show the IN SESSION banner above admins using CNSX" )
    toggle( "Blur behind", "blur", "Blur the game behind the IDE" )
    toggle( "Grain", "grain", "Background grid texture" )

    local apply = make( "CNSXButton", wrap, "DButton" )
    apply:Dock( BOTTOM )
    apply:SetTall( 28 )
    apply:SetText( "Apply size and font" )
    apply.DoClick = function()
        commit()
        sfx( "buttons/button15.wav" )
    end
end

-- ---------- file browser ----------

local function fmtSize( n )
    n = tonumber( n )
    if not n or n < 0 then
        return ""
    end
    if n < 1024 then
        return n .. " B"
    end
    if n < 1024 * 1024 then
        return string.format( "%.1f KB", n / 1024 )
    end

    return string.format( "%.1f MB", n / 1048576 )
end

local function browseRoot()
    return comboData( rootBox ) or "data"
end

local function tintLine( line )
    line.Paint = function( self, w, h )
        if self:IsSelected() or self:IsHovered() then
            surface.SetDrawColor( 30, 50, 90 )
            surface.DrawRect( 0, 0, w, h )
        end
    end
    for _, col in ipairs( line.Columns or {} ) do
        col:SetTextColor( Color( 220, 230, 255 ) )
    end
end

local function fillTree( rows, path, truncated )
    if not IsValid( tree ) then
        return
    end
    tree:Clear()
    path = path or ""
    if path ~= "" then
        local up = tree:AddLine( "..", "" )
        up._up = true
        tintLine( up )
    end
    if not rows or #rows == 0 then
        local empty = tree:AddLine( "(empty)", "" )
        empty._empty = true
        tintLine( empty )
    end
    for _, row in ipairs( rows or {} ) do
        local line = tree:AddLine( ( row.dir and "[dir] " or "" ) .. ( row.name or row.path or "" ), row.dir and "" or fmtSize( row.size ) )
        line._path = row.path
        line._dir = row.dir
        tintLine( line )
    end
    if truncated then
        local more = tree:AddLine( "(list truncated)", "" )
        more._empty = true
        tintLine( more )
    end
    tree._path = path
    tree._grep = nil
    setStatus( ( ROOT_LABEL[browseRoot()] or "" ) .. " / " .. ( path == "" and "" or path ) )
end

local function fillGrep( res )
    if not IsValid( tree ) then
        return
    end
    tree:Clear()
    local back = tree:AddLine( "<- back to files", "" )
    back._back = true
    tintLine( back )
    for _, hit in ipairs( res.hits or {} ) do
        local line = tree:AddLine( string.GetFileFromFilename( hit.path ) .. ":" .. hit.line .. "  " .. tostring( hit.text ), "" )
        line._grepHit = { path = hit.path, line = hit.line, root = res.root }
        line:SetTooltip( hit.path .. ":" .. hit.line .. "\n" .. tostring( hit.text ) )
        tintLine( line )
    end
    if #( res.hits or {} ) == 0 then
        local none = tree:AddLine( "(no matches)", "" )
        none._empty = true
        tintLine( none )
    end
    tree._grep = res
    logLine( "find \"" .. tostring( res.query ) .. "\": " .. #( res.hits or {} ) .. " hits in " .. tostring( res.scanned ) .. " files (" .. tostring( res.secs ) .. "s)" .. ( res.capped and ", capped" or "" ) )
end

-- only the newest listing may fill the tree (remote replies are slow and can arrive after a newer one)
local listSeq = 0

local function listLocal( path )
    local rows, truncated = CNSX.ListDir( path, "DATA" )
    fillTree( rows, CNSX.SanitizePath( path ), truncated )
end

local function relist()
    if IsValid( listBtn ) then
        listBtn.DoClick()
    end
end

local function openFile( root, path, line )
    if root == "mine" then
        local body, err, readOnly = CNSX.ReadText( path, "DATA" )
        if not body then
            logLine( path .. ": " .. tostring( err ), true )
            return
        end
        addTab( string.GetFileFromFilename( path ), body, path, "mine", CNSX.GuessMode( path ), { readOnly = readOnly } )
        if err then
            logLine( err, true )
        end
        if line then
            timer.Simple( 0.2, function()
                gotoLine( line )
            end )
        end
        return
    end
    if root == "remote" then
        local sid = comboData( playerBox )
        if not sid then
            logLine( "pick a player first", true )
            return
        end
        send( "remote_read", { sid = sid, path = path } )
        return
    end
    send( "read", { root = root, path = path, line = line } )
end

local function folderOf( line )
    if line and line._dir then
        return line._path
    end
    if line and line._path then
        return string.TrimRight( string.GetPathFromFilename( line._path ) or "", "/" )
    end

    return tree and tree._path or ""
end

local function startGrep( folder )
    local root = browseRoot()
    if root == "remote" then
        logLine( "find in files is not available for player DATA", true )
        return
    end
    Derma_StringRequest( "CNSX  find in files", "Search " .. ( ROOT_LABEL[root] or root ) .. " / " .. ( folder == "" and "(root)" or folder ) .. "\nprefix re: for a Lua pattern, cs: for case-sensitive", "", function( text )
        local query = tostring( text or "" )
        local case, pattern = false, false
        if string.StartsWith( query, "cs:" ) then
            case = true
            query = string.sub( query, 4 )
        end
        if string.StartsWith( query, "re:" ) then
            pattern = true
            query = string.sub( query, 4 )
        end
        if query == "" then
            return
        end
        logLine( "searching " .. ( ROOT_LABEL[root] or root ) .. " / " .. folder .. " for \"" .. query .. "\"..." )
        if root == "mine" then
            local job, err = CNSX.GrepNew( { query = query, path = folder, case = case, pattern = pattern }, "DATA" )
            if not job then
                logLine( err, true )
                return
            end
            job.rootKey = "mine"
            grepJob = job
            return
        end
        send( "grep", { root = root, path = folder, query = query, case = case, pattern = pattern } )
    end, nil, "Search", "Cancel" )
end

hook.Add( "Think", "CNSX_LocalGrep", function()
    if not grepJob then
        return
    end
    local res = CNSX.GrepStep( grepJob )
    if res then
        res.root = grepJob.rootKey
        grepJob = nil
        if res.err then
            logLine( "find failed: " .. res.err, true )
        else
            fillGrep( res )
        end
    end
end )

local function fileMenu( line )
    local root = browseRoot()
    local writable = root == "data" or root == "mine"
    local menu = DermaMenu()
    local path = line and line._path
    if path then
        if line._dir then
            menu:AddOption( "Open folder", function()
                pathEntry:SetText( path )
                relist()
            end )
        else
            menu:AddOption( "Open", function()
                openFile( root, path )
            end )
            if root == "data" or root == "game" or root == "lua" then
                menu:AddOption( "Run on server (include)", function()
                    send( "include", { root = root, path = path } )
                end )
            end
        end
        menu:AddOption( "Copy path", function()
            SetClipboardText( path )
        end )
        if writable then
            menu:AddOption( "Rename / move...", function()
                Derma_StringRequest( "CNSX  rename", "New path in " .. ROOT_LABEL[root], path, function( to )
                    if root == "mine" then
                        local ok, final, err = CNSX.RenameData( path, to )
                        logLine( ok and ( "renamed to my DATA/" .. final ) or ( "rename failed: " .. tostring( err ) ), not ok )
                        relist()
                        return
                    end
                    send( "rename", { path = path, to = to } )
                end, nil, "Rename", "Cancel" )
            end )
            menu:AddOption( "Delete", function()
                Derma_Query( "Delete " .. ROOT_LABEL[root] .. "/" .. path .. "?" .. ( line._dir and "\n(folders must be empty)" or "" ), "CNSX  delete",
                    "Delete", function()
                        if root == "mine" then
                            local ok, err = CNSX.DeleteData( path )
                            logLine( ok and ( "deleted my DATA/" .. path ) or ( "delete failed: " .. tostring( err ) ), not ok )
                            relist()
                            return
                        end
                        send( "delete", { path = path } )
                    end,
                    "Cancel" )
            end )
        end
        menu:AddSpacer()
    end
    local folder = folderOf( line )
    if writable then
        menu:AddOption( "New file here...", function()
            Derma_StringRequest( "CNSX  new file", "File name in " .. ROOT_LABEL[root] .. " / " .. ( folder == "" and "(root)" or folder ), "new.txt", function( name )
                name = CNSX.SanitizePath( name )
                if name == "" then
                    return
                end
                local full = folder == "" and name or ( folder .. "/" .. name )
                local tab = addTab( string.GetFileFromFilename( full ), "", "", root, CNSX.GuessMode( full ) )
                if tab then
                    saveTab( tab, { path = full, root = root, create = true } )
                end
            end, nil, "Create", "Cancel" )
        end )
        menu:AddOption( "New folder here...", function()
            Derma_StringRequest( "CNSX  new folder", "Folder name in " .. ROOT_LABEL[root] .. " / " .. ( folder == "" and "(root)" or folder ), "", function( name )
                name = CNSX.SanitizePath( name )
                if name == "" then
                    return
                end
                local full = folder == "" and name or ( folder .. "/" .. name )
                if root == "mine" then
                    local ok, final, err = CNSX.MkdirData( full )
                    logLine( ok and ( "created my DATA/" .. final ) or ( "mkdir failed: " .. tostring( err ) ), not ok )
                    relist()
                    return
                end
                send( "mkdir", { path = full } )
            end, nil, "Create", "Cancel" )
        end )
    end
    if root ~= "remote" then
        menu:AddOption( "Find in files here...", function()
            startGrep( folder )
        end )
    end
    menu:AddOption( "Refresh", relist )
    menu:Open()
end

-- ---------- window ----------

local function hotkey( key, arg )
    if not IsValid( frame ) then
        return
    end
    if key == "find" then
        frame._showFind( false )
    elseif key == "line" then
        frame._showFind( true )
    elseif key == "esc" then
        frame._hideFind()
    elseif key == "save" then
        saveCurrent( false )
    elseif key == "saveas" then
        saveCurrent( true )
    elseif key == "run_sv" then
        runAct( "run_sv" )
    elseif key == "run_me" then
        runAct( "run_me" )
    elseif key == "newtab" then
        addTab( "untitled.lua" )
    elseif key == "closetab" then
        closeTab( active )
    elseif key == "nexttab" then
        selectTab( active % #tabs + 1 )
    elseif key == "prevtab" then
        selectTab( ( active - 2 ) % #tabs + 1 )
    elseif key == "wiki" then
        local url = CNSX.WikiURL( arg )
        if url then
            gui.OpenURL( url )
        end
    end
end

local function pushApi()
    if not editorReady() then
        return
    end
    CNSX._clApi = CNSX._clApi or CNSX.CollectAPI()
    editor:RunJavascript( "if(window.cnsxApi)cnsxApi('cl'," .. CNSX.Encode( CNSX._clApi ) .. ");" )
    if CNSX._svApi then
        editor:RunJavascript( "if(window.cnsxApi)cnsxApi('sv'," .. CNSX.Encode( CNSX._svApi ) .. ");" )
    elseif not CNSX._svApiAsked then
        CNSX._svApiAsked = true
        send( "api" )
    end
end

local function closeWindow()
    if not IsValid( frame ) or frame._closing then
        return
    end
    local closing = frame
    closing._closing = true
    pullBody( function()
        saveDraft()
        syncServer( true )
    end )
    setBusy( false )
    if not closing._maxed and not minimized then
        local p = prefs()
        p.w, p.h = closing:GetWide(), closing:GetTall()
        savePrefs()
    end
    if IsValid( CNSX._prefsFrame ) then
        CNSX._prefsFrame:Close()
    end
    if isfunction( closing.AlphaTo ) then
        closing:AlphaTo( 0, 0.15, 0, function()
            if IsValid( closing ) then
                closing:Close()
            end
            if frame == closing then
                frame = nil
            end
        end )
    else
        closing:Close()
        frame = nil
    end
end
CNSX.CloseWindow = closeWindow

local function buildWindow()
    if IsValid( frame ) and frame._closing then
        frame:Remove()
        frame = nil
    end
    if IsValid( frame ) then
        frame:SetVisible( true )
        if minimized and isfunction( frame._restore ) then
            frame._restore()
        end
        frame:MakePopup()
        setBusy( true )
        return
    end

    minimized = false
    local p = loadPrefs()
    loadHistory()
    rest.w = math.min( tonumber( p.w ) or rest.w, ScrW() )
    rest.h = math.min( tonumber( p.h ) or rest.h, ScrH() )
    rest.x = math.Clamp( rest.x, 0, math.max( 0, ScrW() - rest.w ) )
    rest.y = math.Clamp( rest.y, 0, math.max( 0, ScrH() - rest.h ) )
    setBusy( true )
    frame = vgui.Create( vgui.GetControlTable( "CNSXFrame" ) and "CNSXFrame" or "DFrame" )
    if not IsValid( frame ) then
        frame = vgui.Create( "DFrame" )
    end
    if not IsValid( frame ) then
        return
    end
    frame:SetTitle( "" )
    frame:ShowCloseButton( false )
    frame:SetDraggable( true )
    frame:SetSizable( true )
    frame:SetMinWidth( 720 )
    frame:SetMinHeight( 420 )
    frame:SetSize( rest.w, rest.h )
    frame:SetPos( rest.x, rest.y )
    frame:MakePopup()
    frame:SetAlpha( 0 )
    if isfunction( frame.AlphaTo ) then
        frame:AlphaTo( 255, 0.2, 0 )
    else
        frame:SetAlpha( 255 )
    end

    local chrome = vgui.Create( "DPanel", frame )
    chrome:SetPos( frame:GetWide() - 118, 4 )
    chrome:SetSize( 104, 20 )
    chrome.Paint = function() end
    frame.PerformLayout = function( self, w, h )
        if DFrame.PerformLayout then
            DFrame.PerformLayout( self, w, h )
        end
        if IsValid( chrome ) then
            chrome:SetPos( self:GetWide() - 112, 8 )
        end
    end

    local maxBtn
    local function chromeBtn( glyph, x, fn, tip )
        local b = make( "CNSXIcon", chrome, "DButton" )
        b:SetPos( x, 0 )
        b:SetSize( 28, 20 )
        b:SetGlyph( glyph )
        b:SetTooltip( tip )
        b.DoClick = fn

        return b
    end

    local function setMinimized( on )
        if not IsValid( frame ) then
            return
        end
        minimized = on and true or false
        frame._minBar = minimized
        if minimized then
            if not frame._maxed then
                rest.w, rest.h = frame:GetWide(), frame:GetTall()
                rest.x, rest.y = frame:GetPos()
            end
            frame:SetPos( 0, 0 )
            frame:SetSize( ScrW(), 28 )
            frame:SetSizable( false )
            frame:SetKeyboardInputEnabled( false )
            frame:SetMouseInputEnabled( false )
            pullBody( saveDraft )
        else
            frame:SetSizable( true )
            frame:SetKeyboardInputEnabled( true )
            frame:MakePopup()
            if frame._maxed then
                frame:SetPos( 0, 0 )
                frame:SetSize( ScrW(), ScrH() )
            else
                frame:SetPos( rest.x, rest.y )
                frame:SetSize( rest.w, rest.h )
            end
        end
    end
    frame._restore = function()
        setMinimized( false )
    end
    chromeBtn( "min", 0, function()
        setMinimized( not minimized )
    end, "Minimize to a bar (hold C and click it, or !cnsx, to restore)" )
    maxBtn = chromeBtn( "max", 36, function()
        if minimized then
            setMinimized( false )
        end
        if frame._maxed then
            frame._maxed = false
            maxBtn:SetGlyph( "max" )
            frame:MoveTo( rest.x, rest.y, 0.2, 0, 0.3 )
            frame:SizeTo( rest.w, rest.h, 0.2, 0, 0.3 )
        else
            rest.w, rest.h = frame:GetWide(), frame:GetTall()
            rest.x, rest.y = frame:GetPos()
            frame._maxed = true
            maxBtn:SetGlyph( "restore" )
            frame:MoveTo( 0, 0, 0.2, 0, 0.3 )
            frame:SizeTo( ScrW(), ScrH(), 0.2, 0, 0.3 )
        end
    end, "Maximize / restore" )
    chromeBtn( "close", 72, closeWindow, "Close (tabs are kept; the session stays unlocked until it idles out)" )

    local body = vgui.Create( "DPanel", frame )
    body:Dock( FILL )
    body:DockMargin( 6, 32, 6, 6 )
    body.Paint = function() end
    frame._body = body

    local tabBar = vgui.Create( "DPanel", body )
    tabBar:Dock( TOP )
    tabBar:SetTall( 26 )
    tabBar.Paint = function( self, w, h )
        CNSX.PaintBox( 0, 0, w, h, CNSX.Theme.panel )
    end

    local function barBtn( label, wide, tip, fn, kind )
        local b = make( "CNSXButton", tabBar, "DButton" )
        b:Dock( RIGHT )
        b:SetWide( wide )
        b:SetText( label )
        b:SetTooltip( tip )
        if kind and b.SetKind then
            b:SetKind( kind )
        end
        b.DoClick = fn

        return b
    end
    barBtn( "+", 28, "New tab (Ctrl+T)", function()
        addTab( "untitled.lua" )
    end )
    barBtn( "Lock", 48, "End this unlock now; the next open asks for the password", function()
        pullBody( function()
            saveDraft()
            syncServer( true )
            send( "logout" )
        end )
    end, "danger" )
    barBtn( "Prefs", 52, "Preferences", openPrefs )
    barBtn( "Find", 44, "Find / replace / go to line (Ctrl+F, Ctrl+G)", function()
        frame._showFind( false )
    end )

    local findBar = vgui.Create( "DPanel", body )
    findBar:Dock( TOP )
    findBar:SetTall( 0 )
    findBar:SetVisible( false )
    findBar.Paint = function( self, w, h )
        CNSX.PaintBox( 0, 0, w, h, CNSX.Theme.raised )
    end

    local findEnt = vgui.Create( "DTextEntry", findBar )
    findEnt:Dock( LEFT )
    findEnt:SetWide( 180 )
    findEnt:SetPlaceholderText( "find" )
    CNSX.SkinEntry( findEnt )

    local replEnt = vgui.Create( "DTextEntry", findBar )
    replEnt:Dock( LEFT )
    replEnt:SetWide( 150 )
    replEnt:SetPlaceholderText( "replace" )
    CNSX.SkinEntry( replEnt )

    local lineEnt = vgui.Create( "DTextEntry", findBar )
    lineEnt:Dock( LEFT )
    lineEnt:SetWide( 50 )
    lineEnt:SetNumeric( true )
    lineEnt:SetPlaceholderText( "line" )
    CNSX.SkinEntry( lineEnt )

    local findOpts = { case = false, regex = false, word = false }
    local function findArgs()
        return jsBool( findOpts.case ) .. "," .. jsBool( findOpts.regex ) .. "," .. jsBool( findOpts.word )
    end
    local function mini( label, wide, tip, fn )
        local b = make( "CNSXButton", findBar, "DButton" )
        b:Dock( LEFT )
        b:SetWide( wide )
        b:SetText( label )
        b:SetTooltip( tip )
        b.DoClick = fn

        return b
    end
    local function optBtn( label, key, tip )
        local b
        b = mini( label, 30, tip, function()
            findOpts[key] = not findOpts[key]
            b:SetKind( findOpts[key] and "on" or "default" )
        end )
    end
    local function find( back )
        editorJS( "if(window.cnsxFind)cnsxFind(" .. jsQuote( findEnt:GetValue() ) .. "," .. jsBool( back ) .. "," .. findArgs() .. ");" )
    end
    optBtn( "Aa", "case", "Match case" )
    optBtn( ".*", "regex", "Regular expression (JavaScript syntax)" )
    optBtn( "W", "word", "Whole word" )
    mini( "Next", 44, "Find next (Enter)", function()
        find( false )
    end )
    mini( "Prev", 44, "Find previous", function()
        find( true )
    end )
    mini( "Rep", 40, "Replace the current match and find the next", function()
        editorJS( "if(window.cnsxReplace)cnsxReplace(" .. jsQuote( findEnt:GetValue() ) .. "," .. jsQuote( replEnt:GetValue() ) .. "," .. findArgs() .. ");" )
    end )
    mini( "All", 36, "Replace all", function()
        editorJS( "if(window.cnsxReplaceAll)cnsxReplaceAll(" .. jsQuote( findEnt:GetValue() ) .. "," .. jsQuote( replEnt:GetValue() ) .. "," .. findArgs() .. ");" )
    end )
    mini( "Go", 34, "Go to line (Enter in the line box)", function()
        gotoLine( lineEnt:GetValue() )
    end )
    local hideFindBtn = make( "CNSXButton", findBar, "DButton" )
    hideFindBtn:Dock( RIGHT )
    hideFindBtn:SetWide( 24 )
    hideFindBtn:SetText( "x" )
    local function hideFind()
        findBar:SetVisible( false )
        findBar:SetTall( 0 )
        editorJS( "if(window.cnsxFocus)cnsxFocus();" )
    end
    hideFindBtn.DoClick = hideFind
    findEnt.OnEnter = function()
        find( false )
        findEnt:RequestFocus()
    end
    lineEnt.OnEnter = function()
        gotoLine( lineEnt:GetValue() )
    end

    local function showFind( focusLine )
        findBar:SetVisible( true )
        findBar:SetTall( 24 )
        if focusLine then
            lineEnt:RequestFocus()
        else
            findEnt:RequestFocus()
        end
    end
    frame._showFind = showFind
    frame._hideFind = hideFind

    local tabList = vgui.Create( "DHorizontalScroller", tabBar )
    tabList:Dock( FILL )
    frame.PaintTabs = function()
        tabList:Clear()
        for i, tab in ipairs( tabs ) do
            local b = make( "CNSXButton", tabList, "DButton" )
            b:SetWide( 136 )
            b:SetText( tabTitle( tab ) )
            b:SetTooltip( ( ROOT_LABEL[tab.root] or tab.root or "data" ) .. " / " .. ( tab.path ~= "" and tab.path or "(unsaved)" ) .. ( tab.dirty and "\nunsaved changes" or "" ) .. "\nright-click or middle-click to close" )
            if i == active then
                b:SetKind( "on" )
            end
            b.DoClick = function()
                selectTab( i )
            end
            b.DoRightClick = function()
                closeTab( i )
            end
            b.DoMiddleClick = b.DoRightClick
            tabList:AddPanel( b )
        end
    end

    local split = vgui.Create( "DHorizontalDivider", body )
    split:Dock( FILL )
    split:DockMargin( 0, 4, 0, 4 )
    split:SetDividerWidth( 4 )
    split:SetLeftMin( 180 )
    split:SetRightMin( 400 )

    local left = vgui.Create( "DPanel" )
    left.Paint = function( self, w, h )
        CNSX.PaintBox( 0, 0, w, h, CNSX.Theme.panel )
        if isfunction( CNSX.PaintGrain ) then
            CNSX.PaintGrain( 0, 0, w, h, 10 )
        end
    end

    CNSX.FieldLabel( left, "Browse" )
    rootBox = vgui.Create( "DComboBox", left )
    rootBox:Dock( TOP )
    rootBox:SetTall( 24 )
    rootBox:SetSortItems( false )
    rootBox:SetTooltip( "Where the file list, Inc and Save As point" )
    rootBox:AddChoice( "Server DATA", "data", true )
    rootBox:AddChoice( "Server GAME", "game" )
    rootBox:AddChoice( "Server LUA", "lua" )
    rootBox:AddChoice( "My DATA", "mine" )
    rootBox:AddChoice( "Player DATA", "remote" )
    CNSX.SkinCombo( rootBox )

    CNSX.FieldLabel( left, "Target player (Player DATA / On Ply)" )
    playerBox = vgui.Create( "DComboBox", left )
    playerBox:Dock( TOP )
    playerBox:SetTall( 24 )
    playerBox:SetSortItems( false )
    playerBox:SetTooltip( "Superadmin used by Player DATA and On Ply. Refresh updates the list." )
    CNSX.SkinCombo( playerBox, "pick a player..." )
    rootBox.OnSelect = function()
        relist()
    end
    playerBox.OnSelect = function()
        if comboData( rootBox ) == "remote" then
            relist()
        end
    end

    CNSX.FieldLabel( left, "Path (Enter to list)" )
    pathEntry = vgui.Create( "DTextEntry", left )
    pathEntry:Dock( TOP )
    pathEntry:SetTall( 22 )
    pathEntry:SetPlaceholderText( "folder or file path" )
    CNSX.SkinEntry( pathEntry )
    pathEntry.OnEnter = function()
        relist()
    end

    local nav = vgui.Create( "DPanel", left )
    nav:Dock( TOP )
    nav:SetTall( 22 )
    nav:DockMargin( 0, 2, 0, 2 )
    nav.Paint = function() end

    local function navBtn( label, tip, fn )
        local b = make( "CNSXButton", nav, "DButton" )
        b:Dock( LEFT )
        b:SetWide( 56 )
        b:SetText( label )
        b:SetTooltip( tip )
        b.DoClick = fn

        return b
    end

    listBtn = navBtn( "List", "List the folder in the Path box", function()
        local root = browseRoot()
        local path = pathEntry:GetValue()
        -- a file path lists its folder
        if string.GetExtensionFromFilename( path ) and root ~= "remote" then
            path = string.TrimRight( string.GetPathFromFilename( path ) or "", "/" )
        end
        setStatus( "listing " .. ( ROOT_LABEL[root] or root ) )
        listSeq = listSeq + 1
        if root == "mine" then
            listLocal( path )
            return
        end
        if root == "remote" then
            local sid = comboData( playerBox )
            if not sid then
                logLine( "pick a player first", true )
                send( "players" )
                return
            end
            send( "remote_list", { sid = sid, path = path, seq = listSeq } )
            return
        end
        send( "list", { root = root, path = path, seq = listSeq } )
    end )
    navBtn( "Save", "Save the current tab to its own file (Ctrl+S). Unsaved or GAME/LUA tabs ask for a DATA path.", function()
        saveCurrent( false )
    end )
    navBtn( "As...", "Save the current tab to a new path (Ctrl+Shift+S). .lua is stored as .lua.txt", function()
        saveCurrent( true )
    end )
    navBtn( "Grep", "Find in files under the current folder (right-click the list for more)", function()
        startGrep( tree and tree._path or "" )
    end )

    tree = vgui.Create( "DListView", left )
    tree:Dock( FILL )
    tree:SetMultiSelect( false )
    tree:AddColumn( "name" )
    tree:AddColumn( "size" ):SetFixedWidth( 58 )
    tree:SetHideHeaders( true )
    CNSX.SkinList( tree )
    tree.OnRowSelected = function( _, _, line )
        if line._empty then
            return
        end
        if line._back then
            relist()
            return
        end
        if line._grepHit then
            local hit = line._grepHit
            for i, tab in ipairs( tabs ) do
                if tab.path == hit.path and tab.root == hit.root then
                    selectTab( i )
                    timer.Simple( 0.1, function()
                        gotoLine( hit.line )
                    end )
                    return
                end
            end
            openFile( hit.root, hit.path, hit.line )
            return
        end
        if line._up then
            local parent = string.GetPathFromFilename( tree._path or "" ) or ""
            pathEntry:SetText( string.TrimRight( parent, "/" ) )
            relist()
            return
        end
        if line._dir then
            pathEntry:SetText( line._path )
            relist()
            return
        end
        openFile( browseRoot(), line._path )
    end
    tree.OnRowRightClick = function( _, _, line )
        if line._empty or line._up or line._back or line._grepHit then
            fileMenu( nil )
            return
        end
        fileMenu( line )
    end

    local right = vgui.Create( "DPanel" )
    right.Paint = function() end

    editor = vgui.Create( "DHTML", right )
    editor:Dock( FILL )
    editor:SetAllowLua( false )
    editor._ready = false
    editor._sessions = {}
    -- AddFunction only works once the page has loaded (DHTML:AddFunction wiki note), so the whole bridge lives here
    editor.OnDocumentReady = function( self )
        self:AddFunction( "cnsx", "code", function( all, sel, seq )
            flushPull( tostring( all or "" ), tostring( sel or "" ), tonumber( seq ) or -1 )
        end )
        self:AddFunction( "cnsx", "changed", function()
            onEditorChanged()
        end )
        self:AddFunction( "cnsx", "cursor", function( line, col )
            cursorText = "Ln " .. tostring( line ) .. ", Col " .. tostring( col )
            updateStatus()
        end )
        -- Ace swallows keys while focused, so its own bindings forward shortcuts here
        self:AddFunction( "cnsx", "hotkey", function( key, arg )
            hotkey( tostring( key or "" ), tostring( arg or "" ) )
        end )
        self:AddFunction( "cnsx", "info", function( text )
            logLine( tostring( text or "" ) )
        end )
        self._ready = true
        self._sessions = {}
        self:RunJavascript( "if(window.cnsxReady)cnsxReady();" )
        pushApi()
        local tab = current()
        if tab then
            showTab( tab )
            timer.Create( "CNSX_Lint", 0.6, 1, runLint )
        end
    end
    editor:SetHTML( CNSX.EditorHTML( p ) )

    local bottom = vgui.Create( "DPanel", right )
    bottom:Dock( BOTTOM )
    bottom:SetTall( 176 )
    bottom.Paint = function( self, w, h )
        CNSX.PaintBox( 0, 0, w, h, CNSX.Theme.panel )
    end

    local actions = vgui.Create( "DHorizontalScroller", bottom )
    actions:Dock( TOP )
    actions:SetTall( 26 )

    local ACT_DANGER = { ["CL All"] = true, ["Both"] = true, ["Cmd"] = true }

    -- the result already plays a pass/fail sound, so no click sound here
    local function act( label, tip, fn )
        local b = make( "CNSXButton", actions, "DButton" )
        b:SetWide( 62 )
        actions:AddPanel( b )
        b:SetText( label )
        b:SetTooltip( tip )
        if ACT_DANGER[label] and b.SetKind then
            b:SetKind( "danger" )
        end
        b.DoClick = function()
            fn()
        end

        return b
    end

    act( "Check", "Compile on the server without running (the selection if there is one)", function()
        runAct( "check" )
    end )
    act( "SV Run", "Run on the server (Ctrl+Enter). print/Msg output and return values show below", function()
        runAct( "run_sv" )
    end )
    act( "CL Me", "Run on your own client (Ctrl+Shift+Enter)", function()
        runAct( "run_me" )
    end )
    act( "CL All", "Run on every superadmin's client; each one reports back", function()
        runAct( "run_cl" )
    end )
    act( "On Ply", "Run on the target player's client (must be superadmin); it reports back", function()
        runAct( "run_ply", { sid = comboData( playerBox ) } )
    end )
    act( "Both", "Run on the server and on every superadmin's client", function()
        runAct( "run_both" )
    end )
    act( "Inc", "Run the server file in the Path box (Server DATA/GAME/LUA)", function()
        local root = browseRoot()
        if root == "mine" or root == "remote" then
            logLine( "Inc runs a server file; pick Server DATA/GAME/LUA", true )
            return
        end
        send( "include", { path = pathEntry:GetValue(), root = root } )
    end )
    act( "Cmd", "Run the editor's first non-comment line (or the selection) as a server console command", function()
        pullBody( function( code, sel )
            local src = sel ~= "" and sel or code
            local cmd = ""
            for line in string.gmatch( src or "", "[^\r\n]+" ) do
                line = string.Trim( line )
                if line ~= "" and string.sub( line, 1, 2 ) ~= "--" and string.sub( line, 1, 2 ) ~= "//" then
                    cmd = line
                    break
                end
            end
            send( "cmd", { cmd = cmd } )
        end )
    end )
    act( "Hist", "Recent runs; pick one to open it in a new tab", openHistoryMenu )
    act( "Clear", "Clear the output log", function()
        logBox:SetText( "" )
    end )
    act( "Copy", "Copy the output log to the clipboard", function()
        SetClipboardText( logBox:GetText() )
        setStatus( "log copied" )
    end )
    act( "Refresh", "Reload the player list and the file list", function()
        send( "players" )
        relist()
    end )

    local statusRow = vgui.Create( "DPanel", bottom )
    statusRow:Dock( BOTTOM )
    statusRow:SetTall( 16 )
    statusRow.Paint = function() end

    sessionLbl = vgui.Create( "DLabel", statusRow )
    sessionLbl:Dock( RIGHT )
    sessionLbl:SetWide( 170 )
    sessionLbl:SetContentAlignment( 6 )
    sessionLbl:SetTextColor( CNSX.Theme.muted )
    sessionLbl:SetText( "" )
    sessionLbl.Think = function( self )
        if ( self._next or 0 ) > RealTime() then
            return
        end
        self._next = RealTime() + 1
        local idle = tonumber( CNSX._idle ) or 0
        if idle <= 0 then
            self:SetText( "" )
            return
        end
        local left = math.max( 0, math.min( idle - ( RealTime() - lastActivity ), ( CNSX._hardAt or 0 ) - RealTime() ) )
        self:SetText( string.format( "idle lock in %d:%02d", math.floor( left / 60 ), math.floor( left % 60 ) ) )
        self:SetTextColor( left < 120 and CNSX.Theme.err or CNSX.Theme.muted )
        if serverDirty and RealTime() - ( CNSX._lastSync or 0 ) > SERVER_SYNC_SECS then
            CNSX._lastSync = RealTime()
            syncServer()
        end
    end

    statusLbl = vgui.Create( "DLabel", statusRow )
    statusLbl:Dock( FILL )
    statusLbl:SetText( "ready" )
    statusLbl:SetTextColor( CNSX.Theme.muted )

    local replRow = vgui.Create( "DPanel", bottom )
    replRow:Dock( BOTTOM )
    replRow:SetTall( 22 )
    replRow:DockMargin( 0, 2, 0, 2 )
    replRow.Paint = function() end

    local replRealm = make( "CNSXButton", replRow, "DButton" )
    replRealm:Dock( LEFT )
    replRealm:SetWide( 40 )
    replRealm:SetText( "SV" )
    replRealm:SetTooltip( "Where the quick line runs: SV (server) or CL (your client). Click to switch." )
    replRealm.DoClick = function( self )
        self:SetText( self:GetText() == "SV" and "CL" or "SV" )
    end

    local replEnt = vgui.Create( "DTextEntry", replRow )
    replEnt:Dock( FILL )
    replEnt:SetPlaceholderText( "quick Lua: expression or statement, Enter runs, Up/Down history" )
    replEnt:SetHistoryEnabled( true )
    replEnt:SetFont( "CNSX_Mono" )
    CNSX.SkinEntry( replEnt )
    replEnt.OnEnter = function( self )
        local text = string.Trim( self:GetValue() or "" )
        if text == "" then
            return
        end
        self:AddHistory( text )
        self:SetText( "" )
        local code = text
        -- show the value of plain expressions
        if isfunction( CompileString( "return " .. text, "repl", false ) ) then
            code = "return " .. text
        end
        local realm = replRealm:GetText() == "CL" and "run_me" or "run_sv"
        logLine( "> " .. text )
        lastRunSelection = true
        send( realm, { code = code } )
        timer.Simple( 0, function()
            if IsValid( self ) then
                self:RequestFocus()
            end
        end )
    end

    logBox = vgui.Create( "DTextEntry", bottom )
    logBox:Dock( FILL )
    logBox:SetMultiline( true )
    logBox:SetEditable( false )
    logBox:SetFont( "CNSX_Mono" )
    logBox:SetText( "CNSX " .. tostring( CNSX.Version ) .. "  Ctrl+Enter run SV  Ctrl+Shift+Enter run CL  Ctrl+S save  Ctrl+F find  F1 wiki  click an error line to jump\n" )
    CNSX.SkinEntry( logBox )
    logBox.OnMouseReleased = function( self )
        local text = self:GetText() or ""
        local caret = self:GetCaretPos() or #text
        local prefix = string.sub( text, 1, caret )
        local cur = ( string.match( prefix, "([^\n]*)$" ) or "" ) .. ( string.match( string.sub( text, caret + 1 ), "^([^\n]*)" ) or "" )
        cur = string.gsub( cur, "^%d+:%d+:%d+%s*", "" )
        local n = CNSX.ParseErrLine( cur )
        if n then
            gotoLine( n )
        end
    end

    split:SetLeft( left )
    split:SetRight( right )
    split:SetLeftWidth( 250 )

    local oldThink = frame.Think
    frame.Think = function( self )
        if isfunction( oldThink ) then
            oldThink( self )
        else
            DFrame.Think( self )
        end
        if minimized then
            self:SetPos( 0, 0 )
            if self:GetWide() ~= ScrW() or self:GetTall() ~= 28 then
                self:SetSize( ScrW(), 28 )
            end
            local wantMouse = IsValid( g_ContextMenu ) and g_ContextMenu:IsVisible()
            if self:IsMouseInputEnabled() ~= wantMouse then
                self:SetMouseInputEnabled( wantMouse )
            end
        end
        if IsValid( body ) then
            body:SetVisible( not minimized )
        end
    end

    send( "players" )
    timer.Simple( 0.15, relist )
    lastActivity = RealTime()
end

-- local drafts win unless the server copy is newer (e.g. edited from another PC)
local function restoreTabs( serverTabs, serverT, partial )
    if #tabs > 0 then
        return
    end
    local localTabs, localActive, localT = loadLocalSession()
    local source, pick = localTabs, localActive
    -- a partial backup (large tabs left out) never replaces local drafts
    local newer = not partial and ( tonumber( serverT ) or 0 ) > ( localT or 0 )
    if istable( serverTabs ) and #serverTabs > 0 and ( not localTabs or newer ) then
        source, pick = serverTabs, 1
    end
    for _, row in ipairs( source or {} ) do
        if istable( row ) then
            tabs[#tabs + 1] = makeTab( row )
        end
    end
    if #tabs == 0 then
        tabs[1] = makeTab( { title = "untitled.lua", body = DEFAULT_BODY } )
    end
    active = math.Clamp( tonumber( pick ) or 1, 1, #tabs )
end

net.Receive( "CNSX_Open", function()
    if IsValid( CNSX._lock ) then
        CNSX._lock:Close()
    end
    local data = CNSX.NetRead()
    setSession( data.session )
    buildWindow()
    restoreTabs( data.tabs, data.t, data.partial )
    showTab( current() )
    repaintTabs()
    if data.err then
        logLine( data.err, true )
    end
end )

local OUT = {}

OUT.list = function( data )
    if data.err then
        logLine( "list failed: " .. tostring( data.err ), true )
        return
    end
    if tonumber( data.seq ) ~= listSeq then
        return
    end
    fillTree( data.rows, data.path, data.truncated )
end

OUT.file = function( data )
    if not data.body then
        logLine( tostring( data.path or "file" ) .. ": " .. tostring( data.err or "unreadable" ), true )
        return
    end
    local tab = addTab( string.GetFileFromFilename( data.path or "file" ), data.body, data.path, data.root, CNSX.GuessMode( data.path ), { readOnly = data.readOnly == true } )
    if data.err then
        logLine( data.err, true )
    end
    if tab and data.line then
        timer.Simple( 0.2, function()
            gotoLine( data.line )
        end )
    end
end

OUT.lock = function( data )
    if data.locked then
        if IsValid( frame ) then
            closeWindow()
        end
        chat.AddText( Color( 90, 160, 255 ), "[CNSX] ", Color( 230, 230, 230 ), "session locked" )
        return
    end
    if data.unlocked or data.deny then
        setSession( data.session )
        if IsValid( CNSX._lock ) then
            CNSX._lock:Close()
        end
        return
    end
    showLock( data )
end

OUT.saved = function( data )
    local tab = tabById( data.tabId )
    if not data.ok then
        logLine( "save failed: " .. tostring( data.path or "" ) .. " " .. tostring( data.err ), true )
        if tab then
            tab.closeAfterSave = nil
            tab.pendingBody = nil
        end
        return
    end
    logLine( ( data.auto and "autosaved " or "wrote " ) .. "server DATA/" .. tostring( data.path ) )
    if tab and tab.pendingBody then
        markSaved( tab, data.path, "data", tab.pendingBody )
        tab.pendingBody = nil
    end
end

OUT.fileop = function( data )
    logLine( tostring( data.msg ), not data.ok )
    if data.ok and data.from and data.to then
        for _, tab in ipairs( tabs ) do
            if tab.root == "data" and tab.path == data.from then
                tab.path = data.to
                tab.title = string.GetFileFromFilename( data.to )
            end
        end
        repaintTabs()
    end
    relist()
end

OUT.run = function( data )
    showRun( data )
end

OUT.grep = function( data )
    if data.err then
        logLine( "find failed: " .. tostring( data.err ), true )
        return
    end
    fillGrep( data )
end

OUT.errors = function( data )
    for _, e in ipairs( data.list or {} ) do
        logLine( "[server error] " .. tostring( e ), true )
    end
    if ( tonumber( data.dropped ) or 0 ) > 0 then
        logLine( "[server error] ... " .. data.dropped .. " more", true )
    end
end

OUT.api = function( data )
    if data.err then
        return
    end
    CNSX._svApi = { globals = data.globals, libs = data.libs, methods = data.methods }
    if editorReady() then
        editor:RunJavascript( "if(window.cnsxApi)cnsxApi('sv'," .. CNSX.Encode( CNSX._svApi ) .. ");" )
    end
end

OUT.players = function( data )
    if not IsValid( playerBox ) then
        return
    end
    local keep = comboData( playerBox )
    playerBox:Clear()
    local pick
    for i, row in ipairs( data.rows or {} ) do
        playerBox:AddChoice( tostring( row.nick ) .. ( row.sa and "" or "  (not superadmin)" ), row.sid )
        if row.sid == keep then
            pick = i
        end
    end
    local rows = data.rows or {}
    if not pick then
        for i, row in ipairs( rows ) do
            if row.sa and row.sid ~= LocalPlayer():SteamID64() then
                pick = i
                break
            end
        end
    end
    pick = pick or ( rows[1] and 1 )
    if pick then
        local onSelect = playerBox.OnSelect
        -- choosing programmatically must not trigger a remote listing
        playerBox.OnSelect = nil
        playerBox:ChooseOptionID( pick )
        playerBox.OnSelect = onSelect
    end
end

OUT.tabs = function( data )
    if istable( data.tabs ) and #data.tabs > 0 and #tabs == 0 then
        restoreTabs( data.tabs, data.t, data.partial )
        showTab( current() )
        repaintTabs()
    end
end

OUT.remote = function( data )
    if data.err and not data.rows and not data.body and not data.write then
        logLine( "player DATA: " .. tostring( data.err ), true )
        return
    end
    local from = tostring( data.from or "player" )
    local path = CNSX.SanitizePath( data.path )
    if istable( data.rows ) then
        if tonumber( data.seq ) == listSeq then
            fillTree( data.rows, path, data.truncated )
            logLine( "listed " .. from .. "'s DATA/" .. path )
        end
        return
    end
    if isstring( data.body ) then
        addTab( from .. ":" .. string.GetFileFromFilename( path ), data.body, path, "remote", CNSX.GuessMode( path ), { sid = data.sid, readOnly = data.readOnly == true } )
        logLine( "opened " .. from .. "'s DATA/" .. path .. ( data.err and ( " (" .. tostring( data.err ) .. ")" ) or "" ) )
        return
    end
    if data.write then
        logLine( data.ok and ( "wrote " .. from .. "'s DATA/" .. path ) or ( "remote save failed: " .. tostring( data.err ) ), not data.ok )
        -- only a tab that is waiting on a save to this very player
        local tab = tabById( data.tabId )
        if not tab or not tab.pendingBody or tab.pendingSid ~= data.sid then
            return
        end
        if data.ok then
            local body = tab.pendingBody
            tab.pendingBody = nil
            tab.sid = data.sid
            markSaved( tab, path, "remote", body )
            if indexOfTab( tab ) then
                tab.title = from .. ":" .. tab.title
                repaintTabs()
            end
        else
            tab.pendingBody = nil
            tab.closeAfterSave = nil
        end
    end
end

net.Receive( "CNSX_Out", function()
    local data = CNSX.NetRead()
    local fn = OUT[data.kind]
    if fn then
        fn( data )
    elseif data.err then
        logLine( tostring( data.err ), true )
    end
end )

-- code pushed by the server (CL Me / CL All / On Ply / Both). The sender logs its own run;
-- everyone else reports the result back to the admin who sent it
net.Receive( "CNSX_RunCl", function()
    if not CNSX.Allowed( LocalPlayer() ) then
        return
    end
    local data = CNSX.NetRead()
    local code = tostring( data.code or "" )
    if code == "" then
        return
    end
    local mine = data.admin == LocalPlayer():SteamID64()
    if not mine then
        MsgC( Color( 90, 160, 255 ), "[CNSX] ", Color( 230, 230, 230 ), "running " .. #code .. " bytes of Lua pushed by " .. tostring( data.from ) .. " (see the server audit log)\n" )
    end
    local ok, msg, out = CNSX.RunCaptured( code, "CNSX-CL" )
    if mine then
        showRun( { realm = "client", ok = ok, msg = msg, out = out } )
        return
    end
    net.Start( "CNSX_ClOut" )
        net.WriteUInt( tonumber( data.id ) or 0, 32 )
        CNSX.NetWrite( { ok = ok, msg = msg, out = out } )
    net.SendToServer()
end )

net.Receive( "CNSX_Remote", function()
    -- mirror the CNSX_RunCl rule: only superadmins expose their files to remote browsing
    if not CNSX.Allowed( LocalPlayer() ) then
        return
    end
    local data = CNSX.NetRead()
    local rid = tonumber( data.rid ) or 0
    local path = CNSX.SanitizePath( data.path )
    local out = { path = path }
    local verb
    if data.act == "remote_list" then
        out.rows, out.truncated = CNSX.ListDir( path, "DATA" )
        verb = "listed"
    elseif data.act == "remote_read" then
        local body, err, readOnly = CNSX.ReadText( path, "DATA" )
        out.body = body
        out.err = err
        out.readOnly = readOnly
        if not body then
            out.body = nil
        end
        verb = "opened"
    elseif data.act == "remote_write" then
        local ok, final, err = CNSX.WriteData( path, data.body )
        out.ok = ok
        out.path = final
        out.err = err
        verb = "wrote"
    else
        return
    end
    -- tell this player what an admin just did to their files
    chat.AddText( Color( 90, 160, 255 ), "[CNSX] ", Color( 230, 230, 230 ), tostring( data.adminNick or "an admin" ) .. " " .. verb .. " your DATA/" .. ( out.path or path ) )
    net.Start( "CNSX_RemoteOut" )
        net.WriteUInt( rid, 32 )
        CNSX.NetWrite( out )
    net.SendToServer()
end )

concommand.Add( "consolex", function()
    net.Start( "CNSX_Auth" )
        net.WriteUInt( 0, 2 )
        net.WriteString( "" )
    net.SendToServer()
end )

concommand.Add( "cnsx", function()
    RunConsoleCommand( "consolex" )
end )

hook.Add( "OnPlayerChat", "CNSX_ChatOpen", function( ply, text )
    if ply ~= LocalPlayer() then
        return
    end
    text = string.Trim( string.lower( tostring( text or "" ) ) )
    if text == "!cnsx" or text == "/cnsx" then
        RunConsoleCommand( "consolex" )
    end
end )

-- client Lua errors (e.g. from a hook your CL code added) show up in the open IDE
hook.Add( "OnLuaError", "CNSX_ClientErrors", function( err, realm )
    if not IsValid( logBox ) or realm == "server" then
        return
    end
    if ( CNSX._errNext or 0 ) > RealTime() then
        return
    end
    CNSX._errNext = RealTime() + 0.2
    logLine( "[client error] " .. string.sub( tostring( err ), 1, 400 ), true )
end )

loadPrefs()
