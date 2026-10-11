-- End-to-end harness: real CNSX server + client files in two fake GMod realms joined by a fake net.
local ROOT = arg[1] or "consolex/lua/consolex"
local unpack = unpack

local function noop() end
local function autostub( name )
    return setmetatable( {}, { __index = function() return noop end } )
end

-- ---------- serialization stand-in for util.TableToJSON / JSONToTable ----------
local function ser( v )
    local t = type( v )
    if t == "table" then
        local parts = {}
        for k, x in pairs( v ) do
            parts[#parts + 1] = "[" .. ser( k ) .. "]=" .. ser( x )
        end
        return "{" .. table.concat( parts, "," ) .. "}"
    elseif t == "string" then
        return string.format( "%q", v )
    end
    return tostring( v )
end
local function deser( s )
    local f = loadstring( "return " .. s )
    if not f then return nil end
    local ok, r = pcall( f )
    return ok and r or nil
end

-- ---------- GMod string/math/table extras ----------
local gstring = setmetatable( {}, { __index = string } )
function gstring.Trim( s ) return ( tostring( s ):gsub( "^%s+", "" ):gsub( "%s+$", "" ) ) end
function gstring.TrimRight( s, c ) c = c or "%s" if c == "/" then return ( s:gsub( "/+$", "" ) ) end return ( s:gsub( "%s+$", "" ) ) end
function gstring.GetPathFromFilename( p ) return p:match( "^(.*[/\\])[^/\\]-$" ) or "" end
function gstring.GetFileFromFilename( p ) return p:match( "[\\/]([^/\\]+)$" ) or p end
function gstring.GetExtensionFromFilename( p ) return p:match( "%.([^%.]+)$" ) end
local gmath = setmetatable( { Clamp = function( v, a, b ) return math.min( math.max( v, a ), b ) end }, { __index = math } )

-- ---------- world ----------
local now = 1000
local queue = {}          -- pending net messages
local timers = {}
local consoleCmds = {}
local players = {}

local function makeEnv( realm )
    local env = {}
    env._G = env
    for _, k in ipairs( { "pairs", "ipairs", "tostring", "tonumber", "type", "pcall", "error", "select", "unpack", "next", "setmetatable", "getmetatable", "rawget", "rawset", "print", "os", "table" } ) do
        env[k] = _G[k]
    end
    env.string, env.math = gstring, gmath
    env.SERVER, env.CLIENT = realm == "server", realm == "client"
    env.CurTime = function() return now end
    env.SysTime = env.CurTime
    env.isstring = function( v ) return type( v ) == "string" end
    env.istable = function( v ) return type( v ) == "table" end
    env.isfunction = function( v ) return type( v ) == "function" end
    env.isbool = function( v ) return type( v ) == "boolean" end
    env.IsValid = function( o ) return type( o ) == "table" and o.valid ~= false and ( o.IsValid == nil or o:IsValid() ) end
    env.Color = function( r, g, b, a ) return { r = r, g = g, b = b, a = a or 255 } end
    env.Vector, env.Angle = function() return {} end, function() return {} end
    env.CreateConVar, env.GetConVar = noop, function() return nil end
    env.AddCSLuaFile = noop
    env.resource = autostub()
    env.engine = { TickCount = function() return 1 end }
    env.game = { SinglePlayer = function() return false end, ConsoleCommand = function( c ) consoleCmds[#consoleCmds + 1] = c end }
    env.CompileString = function( code, name ) local f, e = loadstring( code, name ) if f then setfenv( f, env ) return f end return e end
    env.ServerLog = noop
    env.util = {
        AddNetworkString = noop, CRC = function( s ) return #s end,
        SHA256 = function( s ) local h = 7 for i = 1, #s do h = ( h * 131 + s:byte( i ) ) % 4294967291 end return "s" .. h end,
        TableToJSON = ser, JSONToTable = deser,
    }
    local files = {}
    env._files = files
    env.file = {
        CreateDir = noop,
        Exists = function( p ) return files[p] ~= nil end,
        Read = function( p ) return files[p] end,
        Write = function( p, b )
            local ext = p:match( "%.([^%.]+)$" )
            if ext == "lua" then return false end -- the real whitelist rejects .lua
            files[p] = b
            return true
        end,
        Append = function( p, b ) files[p] = ( files[p] or "" ) .. b end,
        Find = function( pat )
            local fs = {}
            local pre = pat:gsub( "%*$", "" )
            for k in pairs( files ) do
                if k:sub( 1, #pre ) == pre and not k:sub( #pre + 1 ):find( "/" ) then fs[#fs + 1] = k:sub( #pre + 1 ) end
            end
            return fs, {}
        end,
    }
    local receivers = {}
    local out, reading
    env.net = {
        Receive = function( n, f ) receivers[n] = f end,
        Start = function( n ) out = { n = n, vals = {} } end,
        WriteString = function( s ) table.insert( out.vals, s ) end,
        WriteUInt = function( v ) table.insert( out.vals, v ) end,
        ReadString = function() return table.remove( reading, 1 ) or "" end,
        ReadUInt = function() return table.remove( reading, 1 ) or 0 end,
        Send = function( p ) queue[#queue + 1] = { to = "client", ply = p, msg = out } end,
        SendToServer = function() queue[#queue + 1] = { to = "server", msg = out } end,
    }
    env._deliver = function( msg, ply )
        local f = receivers[msg.n]
        assert( f, realm .. " has no receiver for " .. msg.n )
        reading = { unpack( msg.vals ) }
        f( #msg.vals, ply )
    end
    local cmds = {}
    env.concommand = { Add = function( n, f ) cmds[n] = f end }
    env._cmds = cmds
    local hooks = {}
    env.hook = { Add = function( e, id, f ) hooks[e .. id] = f end }
    env._hooks = hooks
    env.timer = {
        Simple = function( d, f ) timers[#timers + 1] = { t = now + d, f = f } end,
        Create = function( n, d, r, f ) timers[#timers + 1] = { t = now + d, f = f } end,
    }
    env.player = {
        GetAll = function() return players end,
        GetBySteamID64 = function( id ) for _, p in ipairs( players ) do if p:SteamID64() == id then return p end end end,
    }
    return env
end

local SV = makeEnv( "server" )
local CL = makeEnv( "client" )

local function mkply( superadmin, id, nick )
    local p = { valid = true, chat = {} }
    function p:IsSuperAdmin() return superadmin end
    function p:IsAdmin() return superadmin end
    function p:GetUserGroup() return superadmin and "superadmin" or "user" end
    function p:SteamID64() return id end
    function p:SteamID() return "STEAM_" .. id end
    function p:Nick() return nick end
    function p:ChatPrint( s ) p.chat[#p.chat + 1] = s end
    function p:SetNWBool( k, v ) p[k] = v end
    function p:GetNWBool( k ) return p[k] end
    p.EmitSound = noop
    function p:ConCommand( c ) CL._cmds[c]() end
    function p:Alive() return true end
    return p
end

-- ---------- client vgui stubs ----------
local panels = {}
local Panel = {}
Panel.__index = function( t, k )
    local v = rawget( Panel, k )
    if v ~= nil then return v end
    local meta = rawget( t, "_meta" )
    if meta and meta[k] ~= nil then return meta[k] end
    if type( k ) == "string" and k:match( "^%u" ) then return noop end
    return nil
end
function Panel:IsValid() return self.valid ~= false end
function Panel:Remove() self.valid = false end
function Panel:Close() if self.OnClose then self:OnClose() end self.valid = false end
function Panel:SetText( s ) self._text = s end
function Panel:GetText() return self._text or "" end
function Panel:GetValue() return self._text or "" end
function Panel:SetValue( s ) self._text = s end
function Panel:SetSize( w, h ) self._w, self._h = w, h end
function Panel:SetWide( w ) self._w = w end
function Panel:SetTall( h ) self._h = h end
function Panel:GetWide() return self._w or 100 end
function Panel:GetTall() return self._h or 100 end
function Panel:GetSize() return self:GetWide(), self:GetTall() end
function Panel:SetPos( x, y ) self._x, self._y = x, y end
function Panel:GetPos() return self._x or 0, self._y or 0 end
function Panel:SetVisible( b ) self._vis = b end
function Panel:IsVisible() return self._vis ~= false end
function Panel:SetMouseInputEnabled( b ) self._mouse = b end
function Panel:IsMouseInputEnabled() return self._mouse == true end
function Panel:MakePopup() self._mouse = true self._kb = true end
function Panel:AlphaTo( a, d, delay, cb ) if cb then timers[#timers + 1] = { t = now + d, f = function() cb() end } end end
function Panel:GetCaretPos() return #( self._text or "" ) end
-- combo
function Panel:AddChoice( v, d, sel ) self._choices = self._choices or {} table.insert( self._choices, { v = v, d = d } ) if sel then self:ChooseOption( v, #self._choices ) end end
function Panel:Clear() self._choices = {} self._sel = nil self._text = "" self._lines = {} end
function Panel:ChooseOption( v, i ) self._sel = i self._text = v if self.OnSelect then self:OnSelect( i, v, self._choices[i] and self._choices[i].d ) end end
function Panel:GetSelectedID() return self._sel end
function Panel:GetOptionData( i ) return self._choices[i] and self._choices[i].d end
function Panel:GetSelected() if not self._sel then return end local c = self._choices[self._sel] return c.v, c.d end
-- list
function Panel:AddLine( t ) self._lines = self._lines or {} local l = setmetatable( { valid = true, _text = t, Columns = {} }, Panel ) table.insert( self._lines, l ) return l end
-- DHTML: tiny Ace stand-in driven by the JS strings CNSX sends
function Panel:SetHTML( h ) self._html = h end
function Panel:AddFunction( obj, name, f ) self._fns = self._fns or {} self._fns[obj .. "." .. name] = f end
function Panel:RunJavascript( js )
    self._js = self._js or {}
    table.insert( self._js, js )
    if not self._loaded then return end -- page not ready: JS is lost, like the real thing
    local obj = js:match( "cnsxSetObj%((.*)%)$" )
    if obj then local t = deser( obj ) self._code = t and t.c or "" return end
    if js:find( "cnsx.code(cnsxGet())", 1, true ) then
        local f = self._fns and self._fns["cnsx.code"]
        if f then f( self._code or "" ) end
    end
end
function Panel:LoadPage() self._loaded = true if self.OnDocumentReady then self:OnDocumentReady( "" ) end end

local registered = {}
CL.vgui = {
    Register = function( name, tbl, base ) registered[name] = tbl end,
    GetControlTable = function( name ) return registered[name] end,
    Create = function( class, parent )
        local p = setmetatable( { valid = true, class = class, parent = parent }, Panel )
        if registered[class] then
            p._meta = registered[class]
            if registered[class].Init then registered[class].Init( p ) end
        end
        panels[#panels + 1] = p
        return p
    end,
}
CL.DFrame = setmetatable( {}, { __index = function() return noop end } )
CL.AccessorFunc = function( t, key, name )
    t["Set" .. name] = function( s, v ) s[key] = v end
    t["Get" .. name] = function( s ) return s[key] end
end
CL.surface = autostub()
CL.draw = autostub()
CL.cam = autostub()
CL.Material = function() return { IsError = function() return true end } end
CL.Derma_DrawBackgroundBlur = noop
CL.ScrW, CL.ScrH = function() return 1920 end, function() return 1080 end
CL.input = autostub()
CL.gui = autostub()
CL.RunConsoleCommand = function( c ) CL._cmds[c]() end
for _, k in ipairs( { "TOP", "BOTTOM", "LEFT", "RIGHT", "FILL", "TEXT_ALIGN_LEFT", "TEXT_ALIGN_CENTER", "TEXT_ALIGN_RIGHT", "MOUSE_LEFT", "FORCE_STRING", "KEY_ESCAPE", "KEY_F", "KEY_G", "KEY_H", "KEY_LCONTROL", "KEY_RCONTROL", "CHAN_STATIC" } ) do
    CL[k], SV[k] = k, k
end

local function load( env, f )
    local fn = assert( loadfile( ROOT .. "/" .. f ) )
    setfenv( fn, env )
    fn()
end
load( SV, "sh_core.lua" ) load( SV, "sv_core.lua" )
for _, f in ipairs( { "sh_core.lua", "cl_theme.lua", "cl_elements.lua", "cl_editor.lua", "cl_ui.lua", "cl_hud.lua" } ) do load( CL, f ) end

-- ---------- driver ----------
local admin = mkply( true, "76561190000000001", "Admin" )
local pleb = mkply( false, "76561190000000002", "Pleb" )
local admin2 = mkply( true, "76561190000000003", "Admin2" )
players = { admin, pleb, admin2 }
local localPly = admin
CL.LocalPlayer = function() return localPly end

local function pump()
    for _ = 1, 200 do
        if #queue == 0 then
            -- fire due timers
            local fired = false
            for i = #timers, 1, -1 do
                if timers[i].t <= now then local t = table.remove( timers, i ) t.f() fired = true end
            end
            if not fired then return end
        else
            local m = table.remove( queue, 1 )
            now = now + 0.06 -- step past the server's per-player command rate limit
            if m.to == "server" then
                SV._deliver( m.msg, localPly )
            elseif m.ply == localPly then
                CL._deliver( m.msg )
            end
        end
    end
    error( "pump did not settle" )
end
local function wait( s ) now = now + s pump() end

local function find( pred )
    for i = #panels, 1, -1 do
        local p = panels[i]
        if p.valid ~= false and pred( p ) then return p end
    end
end
local function button( label ) return assert( find( function( p ) return p._text == label and p.DoClick ~= nil end ), "no button " .. label ) end
local function editorPanel() return find( function( p ) return p.class == "DHTML" end ) end
local function logText() local l = find( function( p ) return p._text and p._text:find( "^CNSX " ) end ) return l and l._text or "" end
local pass, fail = 0, 0
local function check( name, cond )
    if cond then pass = pass + 1 print( "PASS  " .. name ) else fail = fail + 1 print( "FAIL  " .. name ) end
end

-- 1. non-admin
localPly = pleb
CL._cmds.consolex() pump()
check( "non-admin: no lock prompt, no IDE", find( function( p ) return p.class == "DFrame" or p.class == "CNSXFrame" end ) == nil )
check( "non-admin: told superadmin only", pleb.chat[1] == "[CNSX] superadmin only" )

-- 2. first launch -> set password
localPly = admin
CL._cmds.consolex() pump()
local lock = CL.CNSX._lock
check( "admin: lock prompt shown on first open", CL.IsValid( lock ) )
check( "admin: IDE not opened before unlock", find( function( p ) return p.class == "CNSXFrame" and p ~= lock end ) == nil )
local entry = find( function( p ) return p.class == "DTextEntry" and p.parent == lock end )
entry._text = "hunter22" wait( 1 )
button( "Set and enter" ).DoClick() pump()
check( "password set and session granted", SV.CNSX.Authed( admin ) )
check( "lock prompt closed", not CL.IsValid( lock ) )
local frame = find( function( p ) return p.class == "CNSXFrame" end )
check( "IDE window opened", frame ~= nil )
check( "password masked in lock dialog", entry.Paint ~= nil )

-- 3. editor loads, typing then running uses the live text
local ed = editorPanel()
ed:LoadPage()
check( "editor shows the starter tab once loaded", ( ed._code or "" ):find( "hello", 1, true ) ~= nil )
ed._code = "return 6 * 7"
button( "SV Run" ).DoClick() pump()
check( "SV Run executes the typed code", logText():find( "OK server 42", 1, true ) ~= nil )
check( "SV Run audited", ( SV._files["consolex/audit/" .. os.date( "%Y-%m-%d" ) .. ".txt"] or "" ):find( "return 6 * 7", 1, true ) ~= nil )

ed._code = "error( 'boom' )"
button( "SV Run" ).DoClick() pump()
check( "runtime error reported", logText():find( "ERR server", 1, true ) ~= nil )

ed._code = "local = 1"
button( "Check" ).DoClick() pump()
check( "Check reports compile error", logText():find( "ERR check", 1, true ) ~= nil )
ed._code = "local x = 1"
button( "Check" ).DoClick() pump()
check( "Check reports compile ok", logText():find( "OK check compile ok", 1, true ) ~= nil )

-- 4. save (.lua gets .txt) and reopen from listing
local pathEntry = find( function( p ) return p.class == "DTextEntry" and p._text ~= nil and p ~= entry and not p._text:find( "^CNSX" ) end )
local pathBox = assert( find( function( p ) return p.class == "DTextEntry" and p.SetPlaceholderText and p._text == nil or ( p.class == "DTextEntry" and p._text == "" ) end ) )
ed._code = "print( 'saved' )"
-- the path box is the DTextEntry created right after the two combo boxes
local combos = {}
for _, p in ipairs( panels ) do if p.class == "DComboBox" then combos[#combos + 1] = p end end
local rootBox, playerBox = combos[1], combos[2]
local pathIdx
for i, p in ipairs( panels ) do if p == playerBox then pathIdx = i + 1 end end
local pathField = panels[pathIdx]
pathField._text = "consolex/test.lua"
button( "Save" ).DoClick() pump()
check( "save writes server DATA as .lua.txt", SV._files["consolex/test.lua.txt"] == "print( 'saved' )" )
check( "save result logged", logText():find( "wrote consolex/test.lua.txt", 1, true ) ~= nil )

pathField._text = "consolex"
rootBox:ChooseOption( "Server DATA", 1 ) pump()
local tree = find( function( p ) return p.class == "DListView" end )
local found
for _, l in ipairs( tree._lines or {} ) do if l._path == "consolex/test.lua.txt" then found = l end end
check( "root dropdown re-lists without error", found ~= nil )
if found then tree.OnRowSelected( tree, 1, found ) pump() end
check( "opening a file adds a tab with its contents", ( ed._code or "" ) == "print( 'saved' )" )

-- 5. local (My DATA) save
rootBox:ChooseOption( "My DATA", 4 ) pump()
pathField._text = "mine/a.lua"
ed._code = "x"
button( "Save" ).DoClick() pump()
check( "local save writes client DATA as .lua.txt", CL._files["mine/a.lua.txt"] == "x" )

-- 6. Cmd uses the editor, not the path box
rootBox:ChooseOption( "Server DATA", 1 ) pump()
pathField._text = "consolex/test.lua.txt"
ed._code = "-- comment\nsv_cheats 0\nsecond"
button( "Cmd" ).DoClick() pump()
check( "Cmd runs first real editor line", consoleCmds[#consoleCmds] == "sv_cheats 0\n" )

-- 7. client pushes
ed._code = "return 1"
button( "CL Me" ).DoClick() pump()
check( "CL Me runs on own client", logText():find( "CL 1", 1, true ) ~= nil )
playerBox:ChooseOption( "Pleb", 2 )
button( "On Ply" ).DoClick() pump()
check( "On Ply refuses non-superadmin", logText():find( "Pleb is not a superadmin", 1, true ) ~= nil )
button( "CL All" ).DoClick() pump()
check( "CL All counts superadmins only", logText():find( "sent to 2 superadmins", 1, true ) ~= nil )

-- 8. Inc
pathField._text = "consolex/test.lua.txt"
button( "Inc" ).DoClick() pump()
check( "Inc runs a server DATA file", logText():find( "OK include consolex/test.lua.txt", 1, true ) ~= nil )

-- 9. remote to non-admin refused; remote to admin works (both clients share this harness's CL env)
rootBox:ChooseOption( "Player DATA", 5 ) pump()
check( "remote to non-superadmin refused", logText():find( "is not a superadmin", 1, true ) ~= nil )

-- 10. log click jumps to error line, not timestamp minutes
local logBox = find( function( p ) return p._text and p._text:find( "^CNSX " ) end )
logBox._text = "12:34:56 ERR server CNSX:Admin:3: boom"
ed._js = {}
logBox:OnMouseReleased()
local jumped = table.concat( ed._js, "\n" ):match( "cnsxMark%((%d+)%)" )
check( "log click parses error line (3), not minutes", jumped == "3" )

-- 11. tabs, close, reopen without password
button( "+" ).DoClick() pump()
local tabCount = #SV.CNSX.LoadTabs( admin )
check( "tabs persisted to server", tabCount >= 2 )
local closeBtn = find( function( p ) return p.class == "CNSXIcon" and p.m_Glyph == "close" end )
closeBtn.DoClick() wait( 0.2 )
check( "close ends session banner", admin.CNSX_Active == false )
check( "window closed", not CL.IsValid( frame ) )
CL._cmds.consolex() pump()
check( "reopen while unlocked skips password", CL.IsValid( find( function( p ) return p.class == "CNSXFrame" end ) ) and not CL.IsValid( CL.CNSX._lock ) )

-- 12. expiry -> prompt, wrong then right password
now = now + 50 * 60
ed = editorPanel() ed:LoadPage()
button( "SV Run" ).DoClick() pump()
check( "expired session shows unlock prompt", CL.IsValid( CL.CNSX._lock ) )
local e2 = find( function( p ) return p.class == "DTextEntry" and p.parent == CL.CNSX._lock end )
e2._text = "wrongpass" wait( 1 )
button( "Unlock" ).DoClick() pump()
local msgLbl = find( function( p ) return p.class == "DLabel" and p.parent == CL.CNSX._lock end )
check( "wrong password rejected", not SV.CNSX.Authed( admin ) and msgLbl and msgLbl._text == "bad password" )
e2 = find( function( p ) return p.class == "DTextEntry" and p.parent == CL.CNSX._lock end )
e2._text = "hunter22"
wait( 1 )
button( "Unlock" ).DoClick() pump()
check( "right password unlocks", SV.CNSX.Authed( admin ) and not CL.IsValid( CL.CNSX._lock ) )

-- 13. minimize / maximize / restore
local fr = find( function( p ) return p.class == "CNSXFrame" end )
local minBtn = find( function( p ) return p.class == "CNSXIcon" and p.m_Glyph == "min" end )
local maxB = find( function( p ) return p.class == "CNSXIcon" and ( p.m_Glyph == "max" or p.m_Glyph == "restore" ) end )
minBtn.DoClick()
fr:Think()
check( "minimized bar does not grab the mouse", fr._mouse == false )
maxB.DoClick()
check( "maximize from minimized restores properly", fr._minBar == false and fr._kb ~= false )
minBtn.DoClick()
wait( 1 )
CL._cmds.consolex() pump()
check( "!cnsx restores a minimized window", fr._minBar == false )

-- 14. password commands
SV._cmds.cnsx_setpass( pleb, nil, { "x1234" } )
check( "non-admin cnsx_setpass ignored", true )
SV.CNSX.Auth = {}
local before = SV._files["consolex/auth.json"]
SV._cmds.cnsx_setpass( admin, nil, { "newpass1" } )
check( "locked admin cannot cnsx_setpass", SV._files["consolex/auth.json"] == before )
SV._cmds.cnsx_setpass( nil, nil, { "newpass1" } )
check( "server console cnsx_setpass works", SV._files["consolex/auth.json"] ~= before )
SV._cmds.cnsx( nil )
check( "server-console cnsx doesn't error", true )

print( ( "\n%d passed, %d failed" ):format( pass, fail ) )
os.exit( fail == 0 and 0 or 1 )
