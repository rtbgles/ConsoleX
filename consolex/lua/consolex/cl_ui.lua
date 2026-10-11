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

local function defaultPrefs()
    return {
        w = 1100,
        h = 720,
        sounds = true,
        banner = true,
        blur = true,
        grain = true
    }
end

local function loadPrefs()
    local data = CNSX.Decode( file.Read( "consolex/prefs.json", "DATA" ) )
    local prefs = defaultPrefs()
    if istable( data ) then
        for k, v in pairs( data ) do
            prefs[k] = v
        end
    end
    CNSX.Prefs = prefs
    return prefs
end

local function savePrefs()
    file.CreateDir( "consolex" )
    file.Write( "consolex/prefs.json", CNSX.Encode( CNSX.Prefs or defaultPrefs() ) )
end

local function sfx( name )
    local prefs = CNSX.Prefs or loadPrefs()
    if prefs.sounds == false then
        return
    end
    surface.PlaySound( name )
end

local function send( act, extra )
    extra = extra or {}
    extra.act = act
    net.Start( "CNSX_Cmd" )
        net.WriteString( CNSX.Encode( extra ) )
    net.SendToServer()
end

local function setBusy( open )
    local prefs = CNSX.Prefs or loadPrefs()
    send( "session", {
        open = open and true or false,
        silent = prefs.sounds == false
    } )
end

local function persist()
    local blob = {}
    for i, tab in ipairs( tabs ) do
        blob[#blob + 1] = {
            title = tab.title,
            path = tab.path,
            root = tab.root,
            mode = tab.mode,
            body = tab.body or ""
        }
    end
    file.CreateDir( "consolex" )
    file.Write( "consolex/session.json", CNSX.Encode( { tabs = blob, active = active } ) )
    send( "tabs", { tabs = blob } )
end

local function loadLocalSession()
    local data = CNSX.Decode( file.Read( "consolex/session.json", "DATA" ) )
    if istable( data.tabs ) then
        return data.tabs, data.active
    end
end

local LOG_MAX = 24000

local function logLine( text, bad )
    if not IsValid( logBox ) then
        return
    end
    local prefix = os.date( "%H:%M:%S " )
    text = tostring( text )
    if bad and not string.find( text, "^ERR" ) then
        text = "[!] " .. text
    end
    local all = logBox:GetText() .. prefix .. text .. "\n"
    if #all > LOG_MAX then
        all = string.sub( all, -LOG_MAX )
    end
    logBox:SetText( all )
    logBox:SetCaretPos( #logBox:GetText() )
end

local function current()
    return tabs[active]
end

local function setStatus( text )
    if IsValid( statusLbl ) then
        statusLbl:SetText( text or "" )
    end
end

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

local function gotoLine( n )
    n = tonumber( n )
    if not n then
        return
    end
    editorJS( "if(window.cnsxMark)cnsxMark(" .. math.floor( n ) .. ");" )
    setStatus( "line " .. math.floor( n ) )
end

local function findNext( needle, back )
    editorJS( "if(window.cnsxFind)cnsxFind(" .. jsQuote( needle ) .. "," .. ( back and "true" or "false" ) .. ");" )
end

local function applyBody( body )
    if not editorReady() then
        return
    end
    editor:RunJavascript( "if(window.cnsxSetObj)cnsxSetObj(" .. CNSX.Encode( { c = body or "" } ) .. ")" )
    local tab = current()
    local mode = CNSX.Modes[tab and tab.mode or "lua"] or "ace/mode/lua"
    editor:RunJavascript( "if(window.cnsxMode)cnsxMode(" .. jsQuote( mode ) .. ")" )
end

local function pullBody( cb )
    if not editorReady() then
        cb( current() and current().body or "" )
        return
    end
    editor._cb = cb
    editor:RunJavascript( "if(window.cnsx&&cnsx.code)cnsx.code(cnsxGet());" )
    timer.Simple( 0.25, function()
        if isfunction( editor._cb ) then
            editor._cb( current() and current().body or "" )
            editor._cb = nil
        end
    end )
end

local function selectTab( i )
    pullBody( function( code )
        if tabs[active] then
            tabs[active].body = code
        end
        active = i
        local tab = tabs[active]
        if tab then
            applyBody( tab.body or "" )
            if IsValid( pathEntry ) then
                pathEntry:SetText( tab.path or "" )
            end
            setStatus( ( tab.root or "data" ) .. " / " .. ( tab.path or "untitled" ) )
        end
        persist()
        if IsValid( frame ) and frame.PaintTabs then
            frame.PaintTabs()
        end
    end )
end

local function addTab( title, body, path, root, mode )
    if path and path ~= "" then
        for i, tab in ipairs( tabs ) do
            if tab.path == path and tab.root == ( root or "data" ) then
                logLine( "already open: " .. path .. " (close the tab to reload it)" )
                selectTab( i )
                return
            end
        end
    end
    tabs[#tabs + 1] = {
        title = title or "untitled.lua",
        body = body or "-- CNSX\nprint('hello')\n",
        path = path or "",
        root = root or "data",
        mode = mode or "lua"
    }
    selectTab( #tabs )
end

local function closeTab( i )
    table.remove( tabs, i )
    if #tabs == 0 then
        addTab( "untitled.lua" )
        return
    end
    selectTab( math.Clamp( i, 1, #tabs ) )
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

local function fillTree( rows, path )
    if not IsValid( tree ) then
        return
    end
    tree:Clear()
    local function tint( line )
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
    if ( path or "" ) ~= "" then
        tint( tree:AddLine( ".." ) )
    end
    if not rows or #rows == 0 then
        local empty = tree:AddLine( "(empty — hit List)" )
        empty._empty = true
        tint( empty )
    end
    for _, row in ipairs( rows or {} ) do
        local line = tree:AddLine( ( row.dir and "[dir] " or "" ) .. ( row.name or row.path or "" ) )
        line._path = row.path
        line._dir = row.dir
        tint( line )
    end
    setStatus( ( path or "" ) == "" and "/" or path )
end

local function showLock( info )
    info = info or {}
    if IsValid( CNSX._lock ) then
        CNSX._lock:Close()
    end
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
    msg:SetText( info.err or ( info.needSet and "first launch — choose a password (4+ chars)" or "superadmin master password" ) )
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
        if #pass < 4 then
            msg:SetText( "password too short (4+)" )
            msg:SetTextColor( Color( 255, 90, 90 ) )
            return
        end
        net.Start( "CNSX_Auth" )
            net.WriteUInt( 1, 2 )
            net.WriteString( pass )
        net.SendToServer()
        msg:SetText( "checking..." )
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

local function applySize()
    local prefs = CNSX.Prefs or loadPrefs()
    rest.w = math.Clamp( tonumber( prefs.w ) or 1100, 720, 1920 )
    rest.h = math.Clamp( tonumber( prefs.h ) or 720, 420, 1200 )
    if IsValid( frame ) and not frame._maxed and not minimized then
        frame:SetSize( rest.w, rest.h )
    end
end

local function openPrefs()
    if IsValid( CNSX._prefsFrame ) then
        CNSX._prefsFrame:MakePopup()
        return
    end
    local prefs = loadPrefs()
    local win = vgui.Create( vgui.GetControlTable( "CNSXFrame" ) and "CNSXFrame" or "DFrame" )
    win:SetSize( 380, 340 )
    win._subtitle = "preferences"
    win:Center()
    win:SetTitle( "" )
    win:ShowCloseButton( true )
    win:MakePopup()
    CNSX._prefsFrame = win
    win.OnClose = function()
        CNSX._prefsFrame = nil
    end
    if win.Paint and not vgui.GetControlTable( "CNSXFrame" ) then
        win.Paint = function( self, w, h )
            draw.RoundedBox( 10, 0, 0, w, h, Color( 12, 18, 32 ) )
            draw.RoundedBox( 10, 0, 0, w, 32, Color( 16, 28, 56 ) )
            draw.SimpleText( "preferences", "DermaDefault", 12, 16, Color( 200, 220, 255 ), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
        end
    end

    local wrap = vgui.Create( "DPanel", win )
    wrap:Dock( FILL )
    wrap:DockMargin( 10, 8, 10, 10 )
    wrap.Paint = function() end

    local hint = vgui.Create( "DLabel", wrap )
    hint:Dock( TOP )
    hint:SetTall( 18 )
    hint:SetText( "toggles save immediately" )
    hint:SetTextColor( Color( 140, 170, 220 ) )

    local function row( label )
        local r = vgui.Create( "DPanel", wrap )
        r:Dock( TOP )
        r:SetTall( 30 )
        r:DockMargin( 0, 4, 0, 0 )
        r.Paint = function() end
        local lab = vgui.Create( "DLabel", r )
        lab:Dock( LEFT )
        lab:SetWide( 150 )
        lab:SetText( label )
        lab:SetTextColor( Color( 220, 230, 255 ) )
        return r
    end

    local rW = row( "Width" )
    local wEnt = vgui.Create( "DTextEntry", rW )
    wEnt:Dock( FILL )
    wEnt:SetText( tostring( prefs.w ) )
    CNSX.SkinEntry( wEnt )

    local rH = row( "Height" )
    local hEnt = vgui.Create( "DTextEntry", rH )
    hEnt:Dock( FILL )
    hEnt:SetText( tostring( prefs.h ) )
    CNSX.SkinEntry( hEnt )

    local function commit()
        prefs.w = math.Clamp( tonumber( wEnt:GetValue() ) or prefs.w or 1100, 720, 1920 )
        prefs.h = math.Clamp( tonumber( hEnt:GetValue() ) or prefs.h or 720, 420, 1200 )
        CNSX.Prefs = prefs
        savePrefs()
        applySize()
    end

    local function toggle( name, key )
        local r = row( name )
        local b = make( "CNSXButton", r, "DButton" )
        b:Dock( FILL )
        local function stamp()
            local on = prefs[key] ~= false
            b:SetText( on and "on" or "off" )
            if b.SetKind then
                b:SetKind( on and "on" or "default" )
            end
        end
        stamp()
        b.DoClick = function()
            prefs[key] = not ( prefs[key] ~= false )
            CNSX.Prefs = prefs
            savePrefs()
            stamp()
            if key == "sounds" and prefs.sounds ~= false then
                surface.PlaySound( "buttons/button14.wav" )
            end
        end
    end
    toggle( "Sounds", "sounds" )
    toggle( "Overhead banner", "banner" )
    toggle( "Blur behind", "blur" )
    toggle( "Grain", "grain" )

    local apply = make( "CNSXButton", wrap, "DButton" )
    apply:Dock( BOTTOM )
    apply:SetTall( 28 )
    apply:SetText( "Apply size" )
    apply.DoClick = function()
        commit()
        sfx( "buttons/button15.wav" )
    end
end

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
    local prefs = loadPrefs()
    rest.w = tonumber( prefs.w ) or rest.w
    rest.h = tonumber( prefs.h ) or rest.h
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
    local function chromeBtn( glyph, x, fn )
        local b = make( "CNSXIcon", chrome, "DButton" )
        b:SetPos( x, 0 )
        b:SetSize( 28, 20 )
        b:SetGlyph( glyph )
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
            persist()
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
    end )
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
    end )
    chromeBtn( "close", 72, function()
        if frame._closing then
            return
        end
        persist()
        setBusy( false )
        if not frame._maxed and not minimized then
            local p = CNSX.Prefs or loadPrefs()
            p.w, p.h = frame:GetWide(), frame:GetTall()
            savePrefs()
        end
        frame._closing = true
        if isfunction( frame.AlphaTo ) then
            local closing = frame
            closing:AlphaTo( 0, 0.15, 0, function()
                if IsValid( closing ) then
                    closing:Close()
                end
                if frame == closing then
                    frame = nil
                end
            end )
        else
            frame:Close()
            frame = nil
        end
    end )

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

    local addBtn = make( "CNSXButton", tabBar, "DButton" )
    addBtn:Dock( RIGHT )
    addBtn:SetWide( 28 )
    addBtn:SetText( "+" )
    addBtn.DoClick = function()
        addTab( "untitled.lua" )
    end

    local prefBtn = make( "CNSXButton", tabBar, "DButton" )
    prefBtn:Dock( RIGHT )
    prefBtn:SetWide( 56 )
    prefBtn:SetText( "Prefs" )
    prefBtn.DoClick = function()
        openPrefs()
    end
    local findBtn = make( "CNSXButton", tabBar, "DButton" )
    findBtn:Dock( RIGHT )
    findBtn:SetWide( 44 )
    findBtn:SetText( "Find" )
    findBtn.DoClick = function()
        if isfunction( frame._showFind ) then
            frame._showFind( false )
        end
    end

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
    replEnt:SetWide( 160 )
    replEnt:SetPlaceholderText( "replace" )
    CNSX.SkinEntry( replEnt )

    local lineEnt = vgui.Create( "DTextEntry", findBar )
    lineEnt:Dock( LEFT )
    lineEnt:SetWide( 56 )
    lineEnt:SetPlaceholderText( "line" )
    CNSX.SkinEntry( lineEnt )

    local function mini( label, fn )
        local b = make( "CNSXButton", findBar, "DButton" )
        b:Dock( LEFT )
        b:SetWide( 52 )
        b:SetText( label )
        b.DoClick = fn
    end
    mini( "Next", function()
        findNext( findEnt:GetValue(), false )
    end )
    mini( "Prev", function()
        findNext( findEnt:GetValue(), true )
    end )
    mini( "Rep", function()
        editorJS( "if(window.cnsxReplace)cnsxReplace(" .. jsQuote( replEnt:GetValue() ) .. ");" )
    end )
    mini( "All", function()
        editorJS( "if(window.cnsxReplaceAll)cnsxReplaceAll(" .. jsQuote( findEnt:GetValue() ) .. "," .. jsQuote( replEnt:GetValue() ) .. ");" )
    end )
    mini( "Go", function()
        gotoLine( lineEnt:GetValue() )
    end )
    local hideFindBtn = make( "CNSXButton", findBar, "DButton" )
    hideFindBtn:Dock( RIGHT )
    hideFindBtn:SetWide( 24 )
    hideFindBtn:SetText( "x" )
    local function hideFind()
        findBar:SetVisible( false )
        findBar:SetTall( 0 )
    end
    hideFindBtn.DoClick = hideFind
    findEnt.OnEnter = function()
        findNext( findEnt:GetValue(), false )
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
            b:SetWide( 130 )
            b:SetText( string.sub( tostring( tab.title or "untitled" ), 1, 18 ) )
            b:SetTooltip( ( tab.root or "data" ) .. " / " .. ( tab.path ~= "" and tab.path or "(unsaved)" ) .. "\nright-click or middle-click to close" )
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

    -- forward-declared: the combo OnSelect handlers below are created before the button
    local listBtn

    CNSX.FieldLabel( left, "Browse" )
    rootBox = vgui.Create( "DComboBox", left )
    rootBox:Dock( TOP )
    rootBox:SetTall( 24 )
    rootBox:SetSortItems( false )
    rootBox:SetTooltip( "Where the file list, Save and Inc point" )
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
    playerBox:SetTooltip( "Superadmin used by Player DATA and On Ply. Refresh updates the list." )
    CNSX.SkinCombo( playerBox, "pick a player..." )
    rootBox.OnSelect = function()
        listBtn.DoClick()
    end
    playerBox.OnSelect = function()
        if comboData( rootBox ) == "remote" then
            listBtn.DoClick()
        end
    end

    CNSX.FieldLabel( left, "Path (Enter to list)" )
    pathEntry = vgui.Create( "DTextEntry", left )
    pathEntry:Dock( TOP )
    pathEntry:SetTall( 22 )
    pathEntry:SetPlaceholderText( "folder or file path" )
    CNSX.SkinEntry( pathEntry )
    pathEntry.OnEnter = function()
        listBtn.DoClick()
    end

    local nav = vgui.Create( "DPanel", left )
    nav:Dock( TOP )
    nav:SetTall( 22 )
    nav.Paint = function() end

    listBtn = make( "CNSXButton", nav, "DButton" )
    listBtn:Dock( LEFT )
    listBtn:SetWide( 60 )
    listBtn:SetText( "List" )
    listBtn:SetTooltip( "List the folder in the Path box" )
    listBtn.DoClick = function()
        local root = comboData( rootBox ) or "data"
        setStatus( "listing " .. root )
        if root == "mine" then
            local path = CNSX.SanitizePath( pathEntry:GetValue() )
            local wildcard = path == "" and "*" or ( path .. "/*" )
            local files, dirs = file.Find( wildcard, "DATA" )
            local rows = {}
            for _, name in ipairs( dirs or {} ) do
                rows[#rows + 1] = { name = name, dir = true, path = path == "" and name or ( path .. "/" .. name ) }
            end
            for _, name in ipairs( files or {} ) do
                rows[#rows + 1] = { name = name, dir = false, path = path == "" and name or ( path .. "/" .. name ) }
            end
            fillTree( rows, path )
            return
        end
        if root == "remote" then
            local sid = comboData( playerBox )
            if not sid then
                logLine( "pick a player first", true )
                send( "players", {} )
                return
            end
            send( "remote_list", { sid = sid, path = pathEntry:GetValue(), root = "data" } )
            return
        end
        send( "list", { root = root, path = pathEntry:GetValue() } )
    end

    local saveBtn = make( "CNSXButton", nav, "DButton" )
    saveBtn:Dock( LEFT )
    saveBtn:SetWide( 60 )
    saveBtn:SetText( "Save" )
    saveBtn:SetTooltip( "Save the editor to the Path box (DATA only; .lua is saved as .lua.txt)" )
    saveBtn.DoClick = function()
        pullBody( function( code )
            local tab = current()
            if not tab then
                return
            end
            tab.body = code
            local path = pathEntry:GetValue()
            if path == "" then
                path = "consolex/scratch.txt"
            end
            tab.path = path
            local root = comboData( rootBox ) or "data"
            if root == "mine" then
                local ok, final, err = CNSX.WriteData( path, code )
                logLine( ok and ( "saved local DATA/" .. final ) or ( "local save failed: " .. tostring( err ) ), not ok )
            elseif root == "remote" then
                local sid = comboData( playerBox )
                if not sid then
                    logLine( "pick a player first", true )
                    return
                end
                send( "remote_write", { sid = sid, path = path, body = code } )
                logLine( "saving to player DATA/" .. CNSX.WritablePath( path ) )
            else
                if root ~= "data" then
                    logLine( "GAME/LUA are read-only; saving a copy to server DATA instead" )
                end
                send( "write", { path = path, body = code } )
                logLine( "saving server DATA/" .. CNSX.WritablePath( path ) )
            end
            tab.title = string.GetFileFromFilename( path )
            persist()
        end )
    end

    tree = vgui.Create( "DListView", left )
    tree:Dock( FILL )
    tree:AddColumn( "files" )
    tree:SetHideHeaders( true )
    CNSX.SkinList( tree )
    tree.OnRowSelected = function( _, _, line )
        if line._empty then
            return
        end
        local path = line._path
        if not path then
            local cur = CNSX.SanitizePath( pathEntry:GetValue() )
            local parent = string.GetPathFromFilename( cur ) or ""
            pathEntry:SetText( string.TrimRight( parent, "/" ) )
            listBtn.DoClick()
            return
        end
        if line._dir then
            pathEntry:SetText( path )
            listBtn.DoClick()
            return
        end
        pathEntry:SetText( path )
        local root = comboData( rootBox ) or "data"
        if root == "mine" then
            local body = file.Read( path, "DATA" ) or ""
            addTab( string.GetFileFromFilename( path ), body, path, "mine", CNSX.GuessMode( path ) )
            return
        end
        if root == "remote" then
            local sid = comboData( playerBox )
            send( "remote_read", { sid = sid, path = path, root = "data" } )
            return
        end
        send( "read", { root = root, path = path } )
    end

    local right = vgui.Create( "DPanel" )
    right.Paint = function() end

    editor = vgui.Create( "DHTML", right )
    editor:Dock( FILL )
    CNSX.AttachEditor( editor )
    editor.OnDocumentReady = function( self )
        self:AddFunction( "cnsx", "code", function( val )
            if isfunction( self._cb ) then
                self._cb( tostring( val or "" ) )
                self._cb = nil
            end
        end )
        -- Ace swallows keys while focused, so its own bindings forward Ctrl+F/G/H and Esc here
        self:AddFunction( "cnsx", "hotkey", function( key )
            if not IsValid( frame ) then
                return
            end
            if key == "find" then
                frame._showFind( false )
            elseif key == "line" then
                frame._showFind( true )
            elseif key == "esc" then
                frame._hideFind()
            end
        end )
        self._ready = true
        local tab = current()
        if tab then
            applyBody( tab.body or "" )
        end
    end
    editor:SetHTML( CNSX.EditorHTML( "lua" ) )

    local bottom = vgui.Create( "DPanel", right )
    bottom:Dock( BOTTOM )
    bottom:SetTall( 132 )
    bottom.Paint = function( self, w, h )
        CNSX.PaintBox( 0, 0, w, h, CNSX.Theme.panel )
    end

    local actions = vgui.Create( "DHorizontalScroller", bottom )
    actions:Dock( TOP )
    actions:SetTall( 26 )

    local ACT_TIPS = {
        ["Check"] = "Compile on the server without running",
        ["SV Run"] = "Run the editor code on the server",
        ["CL Me"] = "Run the editor code on your own client",
        ["CL All"] = "Run the editor code on every superadmin's client",
        ["On Ply"] = "Run the editor code on the target player (must be superadmin)",
        ["Both"] = "Run on the server and on every superadmin's client",
        ["Inc"] = "Run the server file in the Path box",
        ["Cmd"] = "Run the editor's first non-comment line as a server console command",
        ["Refresh"] = "Reload the player list and the file list"
    }
    local ACT_DANGER = { ["CL All"] = true, ["Both"] = true, ["Cmd"] = true }

    -- the result already plays a pass/fail sound, so no click sound here
    local function act( label, fn )
        local b = make( "CNSXButton", actions, "DButton" )
        b:SetWide( 72 )
        actions:AddPanel( b )
        b:SetText( label )
        b:SetTooltip( ACT_TIPS[label] )
        if ACT_DANGER[label] and b.SetKind then
            b:SetKind( "danger" )
        end
        b.DoClick = function()
            fn()
        end
        return b
    end

    act( "Check", function()
        pullBody( function( code )
            send( "check", { code = code } )
        end )
    end )
    act( "SV Run", function()
        pullBody( function( code )
            send( "run_sv", { code = code } )
        end )
    end )
    act( "CL Me", function()
        pullBody( function( code )
            send( "run_me", { code = code } )
        end )
    end )
    act( "CL All", function()
        pullBody( function( code )
            send( "run_cl", { code = code } )
        end )
    end )
    act( "On Ply", function()
        pullBody( function( code )
            send( "run_ply", { code = code, sid = comboData( playerBox ) } )
        end )
    end )
    act( "Both", function()
        pullBody( function( code )
            send( "run_both", { code = code } )
        end )
    end )
    act( "Inc", function()
        local root = comboData( rootBox ) or "data"
        if root == "mine" or root == "remote" then
            logLine( "Inc runs a server file; pick Server DATA/GAME/LUA", true )
            return
        end
        send( "include", { path = pathEntry:GetValue(), root = root } )
    end )
    act( "Cmd", function()
        pullBody( function( code )
            local cmd = ""
            for line in string.gmatch( code or "", "[^\r\n]+" ) do
                line = string.Trim( line )
                if line ~= "" and string.sub( line, 1, 2 ) ~= "--" and string.sub( line, 1, 2 ) ~= "//" then
                    cmd = line
                    break
                end
            end
            send( "cmd", { cmd = cmd } )
        end )
    end )
    act( "Refresh", function()
        send( "players", {} )
        listBtn.DoClick()
    end )

    logBox = vgui.Create( "DTextEntry", bottom )
    logBox:Dock( FILL )
    logBox:SetMultiline( true )
    logBox:SetEditable( false )
    logBox:SetFont( "CNSX_Mono" )
    logBox:SetText( "CNSX " .. tostring( CNSX.Version ) .. "  Find Ctrl+F  Go Ctrl+G  Esc closes find. Prefs save live.\n" )
    CNSX.SkinEntry( logBox )
    logBox.OnMouseReleased = function( self )
        local text = self:GetText() or ""
        local caret = self:GetCaretPos() or #text
        local prefix = string.sub( text, 1, caret )
        local cur = string.match( prefix, "([^\n]*)$" ) or ""
        cur = string.gsub( cur, "^%d+:%d+:%d+%s*", "" )
        local n = CNSX.ParseErrLine( cur )
        if n then
            gotoLine( n )
        end
    end

    statusLbl = vgui.Create( "DLabel", bottom )
    statusLbl:Dock( BOTTOM )
    statusLbl:SetTall( 16 )
    statusLbl:SetText( "ready" )
    statusLbl:SetTextColor( CNSX.Theme.muted )

    split:SetLeft( left )
    split:SetRight( right )
    split:SetLeftWidth( 240 )

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

    send( "players", {} )
    timer.Simple( 0.15, function()
        if IsValid( listBtn ) then
            listBtn.DoClick()
        end
    end )

    local localTabs = loadLocalSession()
    if localTabs and #localTabs > 0 and #tabs == 0 then
        for _, tab in ipairs( localTabs ) do
            tabs[#tabs + 1] = tab
        end
        active = 1
        applyBody( tabs[1].body or "" )
    elseif #tabs == 0 then
        addTab( "untitled.lua" )
    end
    frame.PaintTabs()
end

net.Receive( "CNSX_Open", function()
    if IsValid( CNSX._lock ) then
        CNSX._lock:Close()
    end
    local data = CNSX.Decode( net.ReadString() )
    buildWindow()
    if istable( data.tabs ) and #data.tabs > 0 and #tabs <= 1 then
        tabs = data.tabs
        active = 1
        if tabs[1] then
            applyBody( tabs[1].body or "" )
        end
        if IsValid( frame ) and frame.PaintTabs then
            frame.PaintTabs()
        end
    end
end )

net.Receive( "CNSX_Out", function()
    local data = CNSX.Decode( net.ReadString() )
    if data.kind == "list" then
        fillTree( data.rows, data.path )
        return
    end
    if data.kind == "file" then
        if data.err and not data.body then
            logLine( data.err, true )
            return
        end
        addTab( string.GetFileFromFilename( data.path or "file" ), data.body, data.path, data.root, CNSX.GuessMode( data.path ) )
        if data.err then
            logLine( data.err )
        end
        return
    end
    if data.kind == "lock" then
        if data.unlocked or data.deny then
            if IsValid( CNSX._lock ) then
                CNSX._lock:Close()
            end
            return
        end
        showLock( data )
        return
    end
    if data.kind == "saved" then
        logLine( data.ok and ( "wrote " .. tostring( data.path ) ) or ( "save failed: " .. tostring( data.err ) ), not data.ok )
        return
    end
    if data.kind == "run" then
        logLine( ( data.ok and "OK " or "ERR " ) .. tostring( data.realm ) .. " " .. tostring( data.msg ), not data.ok )
        if isfunction( CNSX.FlashRim ) then
            CNSX.FlashRim( data.ok ~= false )
        end
        if not data.ok then
            local n = CNSX.ParseErrLine( data.msg )
            if n then
                gotoLine( n )
            end
        end
        return
    end
    if data.kind == "players" then
        if IsValid( playerBox ) then
            local keep = comboData( playerBox )
            playerBox:Clear()
            local pick = 1
            for i, row in ipairs( data.rows or {} ) do
                playerBox:AddChoice( row.nick, row.sid )
                if row.sid == keep then
                    pick = i
                end
            end
            if istable( data.rows ) and data.rows[pick] then
                playerBox:ChooseOption( data.rows[pick].nick, pick )
            end
        end
        return
    end
    if data.kind == "tabs" and istable( data.tabs ) and #data.tabs > 0 then
        tabs = data.tabs
        active = 1
        applyBody( tabs[1].body or "" )
        if IsValid( frame ) and frame.PaintTabs then
            frame.PaintTabs()
        end
        return
    end
    if data.kind == "remote" then
        if data.rows then
            fillTree( data.rows, data.path )
            logLine( "remote list from " .. tostring( data.from ) )
        end
        if data.body then
            addTab( ( data.from or "ply" ) .. "_" .. string.GetFileFromFilename( data.path or "file" ), data.body, data.path, "remote", CNSX.GuessMode( data.path ) )
            logLine( "remote file " .. tostring( data.path ) )
        end
        if data.ok ~= nil then
            logLine( data.ok and ( "wrote player DATA/" .. tostring( data.path ) ) or "remote save failed", not data.ok )
        end
        if data.err then
            logLine( data.err, true )
        end
    end
end )

net.Receive( "CNSX_RunCl", function()
    if not LocalPlayer():IsSuperAdmin() then
        return
    end
    local code = net.ReadString()
    print( "[CNSX] running " .. #code .. " bytes of Lua pushed by a superadmin (see server audit log)" )
    local fn, err = CompileString( code, "CNSX-CL", false )
    if not isfunction( fn ) then
        logLine( tostring( fn or err ), true )
        return
    end
    local ok, res = pcall( fn )
    logLine( ok and ( "CL " .. tostring( res or "ok" ) ) or tostring( res ), not ok )
end )

net.Receive( "CNSX_Remote", function()
    -- mirror the CNSX_RunCl rule: only superadmins expose their files to remote browsing
    if not LocalPlayer():IsSuperAdmin() then
        return
    end
    local data = CNSX.Decode( net.ReadString() )
    local out = { admin = data.admin, path = data.path }
    local root = "DATA"
    if data.act == "remote_list" then
        local path = CNSX.SanitizePath( data.path )
        local wildcard = path == "" and "*" or ( path .. "/*" )
        local files, dirs = file.Find( wildcard, root )
        local rows = {}
        for _, name in ipairs( dirs or {} ) do
            rows[#rows + 1] = { name = name, dir = true, path = path == "" and name or ( path .. "/" .. name ) }
        end
        for _, name in ipairs( files or {} ) do
            rows[#rows + 1] = { name = name, dir = false, path = path == "" and name or ( path .. "/" .. name ) }
        end
        out.rows = rows
    elseif data.act == "remote_read" then
        out.body = file.Read( CNSX.SanitizePath( data.path ), root ) or ""
        if #out.body > CNSX.MaxCode then
            out.body = string.sub( out.body, 1, CNSX.MaxCode )
            out.err = "truncated"
        end
    elseif data.act == "remote_write" then
        local ok, path, err = CNSX.WriteData( data.path, data.body )
        out.ok = ok
        out.path = path
        out.err = err
    end
    net.Start( "CNSX_RemoteOut" )
        net.WriteString( CNSX.Encode( out ) )
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

loadPrefs()
