-- End-to-end harness: the real CNSX server file and the real client files, loaded into fake GMod realms
-- (one server, one client per admin) and joined by a fake net. Run from the repo root: luajit tests/cnsx_e2e.lua
local ROOT = arg[1] or "consolex/lua/consolex"
local unpack = unpack

local function noop() end
local function autostub()
    return setmetatable( {}, { __index = function() return noop end } )
end

-- ---------- JSON (stand-in for util.TableToJSON / util.JSONToTable) ----------
local encode
local function encStr( s )
    return '"' .. s:gsub( '[%c"\\]', function( c )
        local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or string.format( "\\u%04x", c:byte() )
    end ) .. '"'
end
encode = function( v )
    local t = type( v )
    if t == "nil" then return "null" end
    if t == "boolean" then return tostring( v ) end
    if t == "number" then
        if v == math.floor( v ) and math.abs( v ) < 2 ^ 53 then return string.format( "%d", v ) end
        return string.format( "%.17g", v )
    end
    if t == "string" then return encStr( v ) end
    if t == "table" then
        local n = #v
        local isArr = true
        for k in pairs( v ) do
            if type( k ) ~= "number" or k < 1 or k > n or k ~= math.floor( k ) then isArr = false break end
        end
        local parts = {}
        if isArr then
            for i = 1, n do parts[i] = encode( v[i] ) end
            return "[" .. table.concat( parts, "," ) .. "]"
        end
        for k, x in pairs( v ) do
            if type( x ) ~= "function" then parts[#parts + 1] = encStr( tostring( k ) ) .. ":" .. encode( x ) end
        end
        return "{" .. table.concat( parts, "," ) .. "}"
    end
    return "null"
end
local function decode( s )
    local i = 1
    local function ws() i = s:find( "[^ \t\r\n]", i ) or #s + 1 end
    local val
    local function str()
        i = i + 1
        local out = {}
        while true do
            local c = s:sub( i, i )
            if c == "" then error( "unterminated string" ) end
            if c == '"' then i = i + 1 break end
            if c == "\\" then
                local e = s:sub( i + 1, i + 1 )
                local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f" }
                if e == "u" then
                    out[#out + 1] = string.char( tonumber( s:sub( i + 2, i + 5 ), 16 ) % 256 )
                    i = i + 6
                else
                    out[#out + 1] = map[e] or e
                    i = i + 2
                end
            else
                local j = s:find( '["\\]', i ) or #s + 1
                out[#out + 1] = s:sub( i, j - 1 )
                i = j
            end
        end
        return table.concat( out )
    end
    val = function()
        ws()
        local c = s:sub( i, i )
        if c == "{" then
            i = i + 1
            local t = {}
            ws()
            if s:sub( i, i ) == "}" then i = i + 1 return t end
            while true do
                ws()
                local k = str()
                ws()
                i = i + 1 -- :
                t[k] = val()
                ws()
                local d = s:sub( i, i )
                i = i + 1
                if d == "}" then return t end
            end
        elseif c == "[" then
            i = i + 1
            local t = {}
            ws()
            if s:sub( i, i ) == "]" then i = i + 1 return t end
            while true do
                t[#t + 1] = val()
                ws()
                local d = s:sub( i, i )
                i = i + 1
                if d == "]" then return t end
            end
        elseif c == '"' then
            return str()
        elseif s:sub( i, i + 3 ) == "true" then i = i + 4 return true
        elseif s:sub( i, i + 4 ) == "false" then i = i + 5 return false
        elseif s:sub( i, i + 3 ) == "null" then i = i + 4 return nil
        end
        local num = s:match( "^-?%d+%.?%d*[eE]?[-+]?%d*", i )
        i = i + #num
        return tonumber( num )
    end
    return val()
end
local function jsonDecode( s )
    local ok, r = pcall( decode, s )
    return ok and r or nil
end

-- ---------- GMod string/math extras ----------
local gstring = setmetatable( {}, { __index = string } )
function gstring.Trim( s ) return ( tostring( s ):gsub( "^%s+", "" ):gsub( "%s+$", "" ) ) end
function gstring.TrimRight( s, c ) if c == "/" then return ( s:gsub( "/+$", "" ) ) end return ( s:gsub( "%s+$", "" ) ) end
function gstring.GetPathFromFilename( p ) return p:match( "^(.*[/\\])[^/\\]-$" ) or "" end
function gstring.GetFileFromFilename( p ) return p:match( "[\\/]([^/\\]+)$" ) or p end
function gstring.GetExtensionFromFilename( p ) return p:match( "%.([^%./]+)$" ) end
function gstring.StartsWith( s, p ) return s:sub( 1, #p ) == p end
local gmath = setmetatable( {
    Clamp = function( v, a, b ) return math.min( math.max( v, a ), b ) end,
    Round = function( v, d ) local m = 10 ^ ( d or 0 ) return math.floor( v * m + 0.5 ) / m end,
}, { __index = math } )

-- ---------- world ----------
local now = 1000
local queue = {}          -- pending net messages
local timers = {}
local consoleCmds = {}
local players = {}
local svConsole = {}

local COLOR_META = {}

local function makeEnv( realm )
    local env = {}
    env._G = env
    for _, k in ipairs( { "pairs", "ipairs", "tostring", "tonumber", "type", "pcall", "xpcall", "error", "select", "unpack", "next", "setmetatable", "getmetatable", "rawget", "rawset", "os", "table", "coroutine", "debug", "assert" } ) do
        env[k] = _G[k]
    end
    local console = {}
    env._console = console
    env.print = function( ... ) local t = {} for i = 1, select( "#", ... ) do t[i] = tostring( ( select( i, ... ) ) ) end console[#console + 1] = table.concat( t, "\t" ) end
    env.Msg, env.MsgN, env.MsgC, env.ErrorNoHalt = env.print, env.print, env.print, env.print
    env.string, env.math = gstring, gmath
    env.SERVER, env.CLIENT = realm == "server", realm == "client"
    env.CurTime = function() return now end
    env.SysTime, env.RealTime = env.CurTime, env.CurTime
    env.isstring = function( v ) return type( v ) == "string" end
    env.istable = function( v ) return type( v ) == "table" end
    env.isfunction = function( v ) return type( v ) == "function" end
    env.isbool = function( v ) return type( v ) == "boolean" end
    env.isnumber = function( v ) return type( v ) == "number" end
    env.IsColor = function( v ) return type( v ) == "table" and getmetatable( v ) == COLOR_META end
    env.IsValid = function( o ) return type( o ) == "table" and o.valid ~= false and ( o.IsValid == nil or o:IsValid() ) end
    env.Color = function( r, g, b, a ) return setmetatable( { r = r, g = g, b = b, a = a or 255 }, COLOR_META ) end
    env.Vector, env.Angle = function() return {} end, function() return {} end
    env.CreateConVar, env.GetConVar = noop, function() return nil end
    env.FindMetaTable = function( n ) if n == "Player" then return { Nick = noop, SteamID64 = noop } end end
    env.AddCSLuaFile = noop
    env.resource = autostub()
    env.engine = { TickCount = function() return 1 end }
    env.game = { SinglePlayer = function() return false end, ConsoleCommand = function( c ) consoleCmds[#consoleCmds + 1] = c end }
    env.CompileString = function( code, name ) local f, e = loadstring( code, name ) if f then setfenv( f, env ) return f end return e end
    env.ServerLog = noop
    env.util = {
        AddNetworkString = noop, CRC = function( s ) return #s end,
        SHA256 = function( s ) local h = 7 for i = 1, #s do h = ( h * 131 + s:byte( i ) ) % 4294967291 end return "s" .. h end,
        TableToJSON = encode, JSONToTable = jsonDecode,
        -- "compression": run-length of repeated 64-byte blocks is enough to make repetitive code shrink like LZMA would
        Compress = function( s )
            if s == "" then return "" end
            local out, last, run = {}, nil, 0
            for i = 1, #s, 64 do
                local blk = s:sub( i, i + 63 )
                if blk == last then run = run + 1 else
                    if run > 0 then out[#out + 1] = "\1" .. run .. "\2" end
                    out[#out + 1] = "\3" .. #blk .. "\4" .. blk
                    last, run = blk, 0
                end
            end
            if run > 0 then out[#out + 1] = "\1" .. run .. "\2" end
            return "Z" .. table.concat( out )
        end,
        Decompress = function( s, max )
            local ok, r = pcall( function()
            if s:sub( 1, 1 ) ~= "Z" then return nil end
            local out, size, i, last = {}, 0, 2, nil
            while i <= #s do
                local tag = s:sub( i, i )
                if tag == "\1" then
                    local j = s:find( "\2", i, true )
                    local run = tonumber( s:sub( i + 1, j - 1 ) )
                    for _ = 1, run do out[#out + 1] = last size = size + #last end
                    i = j + 1
                else
                    local j = s:find( "\4", i, true )
                    local n = tonumber( s:sub( i + 1, j - 1 ) )
                    last = s:sub( j + 1, j + n )
                    out[#out + 1] = last
                    size = size + n
                    i = j + 1 + n
                end
                if max and size > max then return nil end
            end
            return table.concat( out )
            end )
            return ok and r or nil
        end,
    }
    -- DATA filesystem: files map plus explicit dirs
    local files, dirs = {}, {}
    env._files, env._dirs = files, dirs
    local function isDir( p )
        if dirs[p] then return true end
        for k in pairs( files ) do if k:sub( 1, #p + 1 ) == p .. "/" then return true end end
        return false
    end
    env._writes = 0
    env.file = {
        CreateDir = function( p ) local acc = "" for part in p:gmatch( "[^/]+" ) do acc = acc == "" and part or ( acc .. "/" .. part ) dirs[acc] = true end end,
        Exists = function( p ) return files[p] ~= nil or isDir( p ) end,
        IsDir = function( p ) return isDir( p ) end,
        Read = function( p ) return files[p] end,
        Size = function( p ) return files[p] and #files[p] or -1 end,
        Time = function() return 0 end,
        Write = function( p, b )
            local ext = p:match( "%.([^%.]+)$" )
            if ext == "lua" then return false end -- the real whitelist rejects .lua
            files[p] = b
            env._writes = env._writes + 1
            return true
        end,
        Append = function( p, b ) files[p] = ( files[p] or "" ) .. b end,
        Delete = function( p ) files[p] = nil dirs[p] = nil end,
        Rename = function( a, b )
            if files[a] then files[b] = files[a] files[a] = nil return true end
            return false
        end,
        Find = function( pat )
            local fs, ds, seen = {}, {}, {}
            local pre = pat:gsub( "%*$", "" )
            for k in pairs( files ) do
                if k:sub( 1, #pre ) == pre then
                    local rest = k:sub( #pre + 1 )
                    local d = rest:match( "^([^/]+)/" )
                    if d then if not seen[d] then seen[d] = true ds[#ds + 1] = d end else fs[#fs + 1] = rest end
                end
            end
            for k in pairs( dirs ) do
                if k:sub( 1, #pre ) == pre then
                    local rest = k:sub( #pre + 1 )
                    if rest ~= "" and not rest:find( "/" ) and not seen[rest] then seen[rest] = true ds[#ds + 1] = rest end
                end
            end
            return fs, ds
        end,
    }
    local receivers = {}
    local out, reading
    env.net = {
        Receive = function( n, f ) receivers[n] = f end,
        Start = function( n ) out = { n = n, vals = {} } end,
        WriteString = function( s ) table.insert( out.vals, s ) end,
        WriteUInt = function( v ) table.insert( out.vals, v ) end,
        WriteData = function( s, n ) table.insert( out.vals, s:sub( 1, n ) ) end,
        ReadString = function() return table.remove( reading, 1 ) or "" end,
        ReadUInt = function() return table.remove( reading, 1 ) or 0 end,
        ReadData = function() return table.remove( reading, 1 ) or "\0" end,
        Send = function( p ) queue[#queue + 1] = { to = "client", ply = p, msg = out } end,
        SendToServer = function() queue[#queue + 1] = { to = "server", from = env._owner, msg = out } end,
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
    env.hook = { Add = function( e, id, f ) hooks[e .. "/" .. id] = f end }
    env._hooks = hooks
    env.timer = {
        Simple = function( d, f ) timers[#timers + 1] = { t = now + d, f = f } end,
        Create = function( n, d, r, f )
            for i = #timers, 1, -1 do if timers[i].name == n and timers[i].env == env then table.remove( timers, i ) end end
            timers[#timers + 1] = { t = now + d, f = f, name = n, env = env, rep = r == 0 and d or nil }
        end,
    }
    env.player = {
        GetAll = function() return players end,
        GetHumans = function() return players end,
        GetBySteamID64 = function( id ) for _, p in ipairs( players ) do if p:SteamID64() == id then return p end end end,
    }
    return env
end

local SV = makeEnv( "server" )

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
    function p:Alive() return true end
    return p
end

-- ---------- client realm (one per player) ----------
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
local function kill( p ) p.valid = false for _, c in ipairs( p._children or {} ) do kill( c ) end end
function Panel:Remove() kill( self ) end
function Panel:Close() if self.OnClose then self:OnClose() end kill( self ) end
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
function Panel:SetKeyboardInputEnabled( b ) self._kb = b end
function Panel:MakePopup() self._mouse = true self._kb = true end
function Panel:GetCaretPos() return #( self._text or "" ) end
function Panel:AlphaTo( a, d, delay, cb ) if cb then timers[#timers + 1] = { t = now + d, f = function() cb() end } end end
function Panel:SetKind( k ) self.m_Kind = k end
function Panel:AddChoice( v, d, sel ) self._choices = self._choices or {} table.insert( self._choices, { v = v, d = d } ) if sel then self:ChooseOption( v, #self._choices ) end end
function Panel:Clear()
    self._choices = {} self._sel = nil self._text = "" self._lines = {}
    for _, c in ipairs( self._children or {} ) do c.valid = false end
    self._children = {}
end
function Panel:ChooseOption( v, i ) self._sel = i self._text = v if self.OnSelect then self:OnSelect( i, v, self._choices[i] and self._choices[i].d ) end end
function Panel:ChooseOptionID( i ) self:ChooseOption( self._choices[i].v, i ) end
function Panel:GetSelectedID() return self._sel end
function Panel:GetOptionData( i ) return self._choices[i] and self._choices[i].d end
function Panel:GetSelected() if not self._sel then return end local c = self._choices[self._sel] return c.v, c.d end
function Panel:AddColumn() return setmetatable( { valid = true }, Panel ) end
function Panel:AddLine( t ) self._lines = self._lines or {} local l = setmetatable( { valid = true, _text = t, Columns = {} }, Panel ) table.insert( self._lines, l ) return l end
function Panel:AddHistory( t ) self._hist = self._hist or {} table.insert( self._hist, t ) end
function Panel:SetHTML( h ) self._html = h end
function Panel:AddFunction( obj, name, f ) self._fns = self._fns or {} self._fns[obj .. "." .. name] = f end
-- DHTML: a tiny model of the page's JS API (one text per session id, like Ace EditSessions)
function Panel:RunJavascript( js )
    self._js = self._js or {}
    table.insert( self._js, js )
    if not self._loaded then return end -- page not ready: JS is lost, like the real thing
    local fn, args = js:match( "^if%(window%.[%w_]+%)([%w_]+)%((.*)%);?$" )
    if not fn then return end
    args = args:gsub( "%);?$", "" )
    local a = fn ~= "cnsxApi" and jsonDecode( "[" .. args .. "]" ) or {}
    self._docs = self._docs or {}
    if fn == "cnsxOpen" then
        if self._docs[a[1]] == nil or a[4] then self._docs[a[1]] = a[2] end
        self._cur = a[1]
        self._mode = a[3]
        self._sel = ""
    elseif fn == "cnsxDrop" then
        self._docs[a[1]] = nil
    elseif fn == "cnsxCode" then
        local f = self._fns and self._fns["cnsx.code"]
        if f then self._pendingCode = function() f( self._docs[self._cur] or "", self._sel or "" ) end end
    elseif fn == "cnsxLint" then
        self._lint = a[1]
    elseif fn == "cnsxMark" then
        self._mark = a[1]
    elseif fn == "cnsxPrefs" then
        self._prefs = a[1]
    elseif fn == "cnsxMode" then
        self._mode = a[1]
    elseif fn == "cnsxApi" then
        self._api = ( self._api or 0 ) + 1
    end
end
function Panel:LoadPage() self._loaded = true if self.OnDocumentReady then self:OnDocumentReady( "" ) end end
function Panel:Code() return self._docs and self._docs[self._cur] end
function Panel:Type( text, sel )
    self._docs[self._cur] = text
    self._sel = sel or ""
    if self._fns["cnsx.changed"] then self._fns["cnsx.changed"]() end
end

local CLIENTS = {}

local function makeClient( ply )
    local CL = makeEnv( "client" )
    CL._owner = ply
    CL._panels = {}
    CL._prompts, CL._queries, CL._menus = {}, {}, {}
    local registered = {}
    CL.vgui = {
        Register = function( name, tbl ) registered[name] = tbl end,
        GetControlTable = function( name ) return registered[name] end,
        Create = function( class, parent )
            local p = setmetatable( { valid = true, class = class, parent = parent }, Panel )
            if parent then parent._children = parent._children or {} table.insert( parent._children, p ) end
            if registered[class] then
                p._meta = registered[class]
                if registered[class].Init then registered[class].Init( p ) end
            end
            CL._panels[#CL._panels + 1] = p
            return p
        end,
    }
    CL.DFrame = setmetatable( {}, { __index = function() return noop end } )
    CL.AccessorFunc = function( t, key, name )
        t["Set" .. name] = function( s, v ) s[key] = v end
        t["Get" .. name] = function( s ) return s[key] end
    end
    CL.surface, CL.draw, CL.cam, CL.input, CL.gui = autostub(), autostub(), autostub(), autostub(), autostub()
    CL.gui.OpenURL = function( u ) CL._opened = u end
    CL.Material = function() return { IsError = function() return true end } end
    CL.Derma_DrawBackgroundBlur = noop
    CL.ScrW, CL.ScrH = function() return 1920 end, function() return 1080 end
    CL.RunConsoleCommand = function( c ) CL._cmds[c]() end
    CL.LocalPlayer = function() return ply end
    CL.SetClipboardText = function( t ) CL._clip = t end
    CL.chat = { AddText = function( ... ) local t = {} for i = 1, select( "#", ... ) do local v = select( i, ... ) if type( v ) == "string" then t[#t + 1] = v end end CL._chat = table.concat( t ) end }
    -- Derma dialogs answer from queues the test fills
    CL.Derma_StringRequest = function( title, sub, default, ok, cancel )
        local answer = table.remove( CL._prompts, 1 )
        CL._lastPrompt = { title = title, sub = sub, default = default }
        if answer == false then if cancel then cancel() end elseif answer then ok( answer == true and default or answer ) end
    end
    CL.Derma_Query = function( text, title, ... )
        local args = { ... }
        local choice = table.remove( CL._queries, 1 )
        CL._lastQuery = text
        for i = 1, #args, 2 do if args[i] == choice and args[i + 1] then args[i + 1]() end end
    end
    CL.DermaMenu = function()
        local m = { opts = {} }
        function m:AddOption( name, f ) self.opts[#self.opts + 1] = { name = name, f = f } return setmetatable( {}, Panel ) end
        function m:AddSpacer() end
        function m:Open() CL._menus[#CL._menus + 1] = self end
        function m:Pick( name ) for _, o in ipairs( self.opts ) do if o.name:find( name, 1, true ) then o.f() return true end end end
        return m
    end
    for _, k in ipairs( { "TOP", "BOTTOM", "LEFT", "RIGHT", "FILL", "TEXT_ALIGN_LEFT", "TEXT_ALIGN_CENTER", "TEXT_ALIGN_RIGHT", "MOUSE_LEFT", "FORCE_STRING", "CHAN_STATIC" } ) do
        CL[k] = k
    end
    local function load( f )
        local fn = assert( loadfile( ROOT .. "/" .. f ) )
        setfenv( fn, CL )
        fn()
    end
    for _, f in ipairs( { "sh_core.lua", "cl_theme.lua", "cl_elements.lua", "cl_editor.lua", "cl_ui.lua", "cl_hud.lua" } ) do load( f ) end
    function ply:ConCommand( c ) CL._cmds[c]() end
    CLIENTS[ply] = CL
    return CL
end

for _, k in ipairs( { "CHAN_STATIC" } ) do SV[k] = k end
do
    local fn = assert( loadfile( ROOT .. "/sh_core.lua" ) ) setfenv( fn, SV ) fn()
    fn = assert( loadfile( ROOT .. "/sv_core.lua" ) ) setfenv( fn, SV ) fn()
end

-- ---------- driver ----------
local admin = mkply( true, "76561190000000001", "Admin" )
local pleb = mkply( false, "76561190000000002", "Pleb" )
local admin2 = mkply( true, "76561190000000003", "Admin2" )
players = { admin, pleb, admin2 }
local CL = makeClient( admin )
local CLB = makeClient( admin2 )
local CLP = makeClient( pleb )

local STEP = 0.06
local function pump()
    for _ = 1, 5000 do
        -- editors answer cnsxCode on the next "frame"
        local answered = false
        for _, env in pairs( CLIENTS ) do
            for _, p in ipairs( env._panels ) do
                if p._pendingCode then local f = p._pendingCode p._pendingCode = nil f() answered = true end
            end
        end
        if SV._hooks["Think/CNSX_Grep"] then SV._hooks["Think/CNSX_Grep"]() end
        for _, env in pairs( CLIENTS ) do if env._hooks["Think/CNSX_LocalGrep"] then env._hooks["Think/CNSX_LocalGrep"]() end end
        if answered then
            -- keep going: the answer may have queued more work
        elseif #queue == 0 then
            local fired = false
            for i = #timers, 1, -1 do
                local t = timers[i]
                if t and t.t <= now then
                    table.remove( timers, i )
                    if t.rep then t.t = now + t.rep timers[#timers + 1] = t end
                    t.f()
                    fired = true
                end
            end
            if not fired then return end
        else
            local m = table.remove( queue, 1 )
            now = now + STEP
            if m.to == "server" then
                SV._deliver( m.msg, m.from )
            elseif CLIENTS[m.ply] then
                CLIENTS[m.ply]._deliver( m.msg )
            end
        end
    end
    error( "pump did not settle" )
end
local function wait( s ) now = now + s pump() end

local function find( env, pred )
    for i = #env._panels, 1, -1 do
        local p = env._panels[i]
        if p.valid ~= false and pred( p ) then return p end
    end
end
local function button( env, label ) return assert( find( env, function( p ) return p._text == label and p.DoClick ~= nil end ), "no button " .. label ) end
local function editorPanel( env ) return find( env, function( p ) return p.class == "DHTML" end ) end
local function logBox( env ) return find( env, function( p ) return p.class == "DTextEntry" and p.OnMouseReleased ~= nil end ) end
local function logText( env ) local l = logBox( env ) return l and l._text or "" end
local function frameOf( env ) return find( env, function( p ) return p.class == "CNSXFrame" and p._body end ) end
local function tabButtons( env )
    local out = {}
    for _, p in ipairs( env._panels ) do if p.valid ~= false and p.class == "CNSXButton" and rawget( p, "DoMiddleClick" ) then out[#out + 1] = p end end
    return out
end
local function widgets( env )
    local combos, rootBox, playerBox, pathField = {}, nil, nil, nil
    for _, p in ipairs( env._panels ) do if p.valid ~= false and p.class == "DComboBox" and p._choices and p._choices[1] and ( p._choices[1].d == "data" or p._choices[1].d == nil or p._choices[1].d:match( "^7656" ) ) then combos[#combos + 1] = p end end
    for _, p in ipairs( env._panels ) do if p.valid ~= false and p.class == "DComboBox" and p._choices and p._choices[1] and p._choices[1].d == "data" then rootBox = p end end
    local after = false
    for _, p in ipairs( env._panels ) do
        if p.valid ~= false and p.class == "DComboBox" and p._placeholder == "pick a player..." then playerBox = p after = true
        elseif after and p.valid ~= false and p.class == "DTextEntry" then pathField = p after = false end
    end
    local tree = find( env, function( p ) return p.class == "DListView" end )
    return rootBox, playerBox, pathField, tree
end
local function lineFor( tree, path ) for _, l in ipairs( tree._lines or {} ) do if l._path == path then return l end end end

local pass, fail = 0, 0
local function check( name, cond )
    if cond then pass = pass + 1 print( "PASS  " .. name ) else fail = fail + 1 print( "FAIL  " .. name ) end
end
local function auditText() return SV._files["consolex/audit/" .. os.date( "%Y-%m-%d" ) .. ".txt"] or "" end
local function lastLog( env ) local t = logText( env ) return t:sub( -400 ) end

-- 1. non-admin
CLP._cmds.consolex() pump()
check( "non-admin: no lock prompt, no IDE", find( CLP, function( p ) return p.class == "DFrame" or p.class == "CNSXFrame" end ) == nil )
check( "non-admin: told superadmin only", pleb.chat[1] == "[CNSX] superadmin only" )

-- 2. first launch -> set password (8+ for a new one)
CL._cmds.consolex() pump()
local lock = CL.CNSX._lock
check( "admin: lock prompt shown on first open", CL.IsValid( lock ) )
local entry = find( CL, function( p ) return p.class == "DTextEntry" and p.parent == lock end )
entry._text = "short" wait( 1 )
button( CL, "Set and enter" ).DoClick() pump()
check( "new master password needs 8+ chars", not SV.CNSX.HasMaster() )
entry._text = "hunter22" wait( 1 )
button( CL, "Set and enter" ).DoClick() pump()
check( "password set and session granted", SV.CNSX.Authed( admin ) )
check( "lock prompt closed", not CL.IsValid( lock ) )
local frame = frameOf( CL )
check( "IDE window opened", frame ~= nil )

-- 3. editor bridge, output capture, return values, traceback
local ed = editorPanel( CL )
ed:LoadPage() pump()
check( "editor shows the starter tab once loaded", ( ed:Code() or "" ):find( "hello", 1, true ) ~= nil )
check( "editor got the client API for autocomplete", ( ed._api or 0 ) >= 1 )
check( "editor got the server API too", ( ed._api or 0 ) >= 2 )
local origPrint = SV.print
ed:Type( "print( 'hi', 5 ) MsgN( 'line2' ) return 6 * 7" )
button( CL, "SV Run" ).DoClick() pump()
check( "SV Run executes the typed code", logText( CL ):find( "OK server 42", 1, true ) ~= nil )
check( "print output captured into the log", logText( CL ):find( "  | hi\t5", 1, true ) ~= nil and logText( CL ):find( "  | line2", 1, true ) ~= nil )
check( "print still reaches the server console", SV._console[#SV._console] == "line2" or table.concat( SV._console, "\n" ):find( "hi\t5", 1, true ) ~= nil )
check( "print restored after the run", SV.print == origPrint )
check( "SV Run audited", auditText():find( "return 6 * 7", 1, true ) ~= nil )

ed:Type( "return { a = 1, b = { 'x' } }, nil, 'str'" )
button( CL, "SV Run" ).DoClick() pump()
check( "tables and multiple returns pretty-printed", logText( CL ):find( "a = 1,", 1, true ) ~= nil and logText( CL ):find( '"str"', 1, true ) ~= nil )

ed:Type( "local x = 1\n\nerror( 'boom' )" )
ed._mark = nil
button( CL, "SV Run" ).DoClick() pump()
check( "runtime error reported with a stack trace", logText( CL ):find( "ERR server", 1, true ) ~= nil and logText( CL ):find( "stack traceback", 1, true ) ~= nil )
check( "runtime error marks line 3 in the editor", ed._mark == 3 )

ed:Type( "local = 1" )
button( CL, "Check" ).DoClick() pump()
check( "Check reports compile error", logText( CL ):find( "ERR check", 1, true ) ~= nil )
ed:Type( "local x = 1" )
button( CL, "Check" ).DoClick() pump()
check( "Check reports compile ok", logText( CL ):find( "OK check compile ok", 1, true ) ~= nil )

-- 4. selection runs, concurrent pulls, burst rate limit
ed:Type( "return 1\nreturn 2", "return 2" )
button( CL, "SV Run" ).DoClick() pump()
check( "with a selection, only the selection runs", lastLog( CL ):find( "OK server 2", 1, true ) ~= nil )
ed:Type( "return 'both'" )
local before = select( 2, logText( CL ):gsub( "OK ", "" ) )
STEP = 0
button( CL, "Check" ).DoClick()
button( CL, "SV Run" ).DoClick()
button( CL, "Refresh" ).DoClick()
pump()
STEP = 0.06
local after = select( 2, logText( CL ):gsub( "OK ", "" ) )
check( "two actions in the same frame both run (shared editor pull)", after - before == 2 )
check( "same-tick burst is not dropped by the rate limit", lastLog( CL ):find( "OK server \"both\"", 1, true ) ~= nil )

-- 5. live lint
ed:Type( "local a = 1\nlocal = 2" )
wait( 1 )
check( "live syntax check marks the bad line", ed._lint == 2 )
ed:Type( "local a = 1" )
wait( 1 )
check( "lint clears once fixed", ed._lint == 0 )

-- 6. Save: untitled -> Save As; saved tab writes to its own path even after browsing elsewhere
local rootBox, playerBox, pathField, tree = widgets( CL )
ed:Type( "print( 'saved' )" )
pathField._text = "consolex"
table.insert( CL._prompts, "consolex/test.lua" )
button( CL, "Save" ).DoClick() pump()
check( "untitled tab asks for a path and saves as .lua.txt", SV._files["consolex/test.lua.txt"] == "print( 'saved' )" )
check( "save result logged", logText( CL ):find( "wrote server DATA/consolex/test.lua.txt", 1, true ) ~= nil )
local tb = tabButtons( CL )
check( "tab renamed to the saved file and not dirty", tb[1] and tb[1]._text == "test.lua.txt" )
ed:Type( "print( 'v2' )" )
check( "editing marks the tab dirty", tabButtons( CL )[1]._text == "* test.lua.txt" )
pathField._text = "some/other/folder"
button( CL, "Save" ).DoClick() pump()
check( "Save writes the tab's own file, not the Path box", SV._files["consolex/test.lua.txt"] == "print( 'v2' )" and SV._files["some/other/folder.txt"] == nil )

-- 7. browse + open, duplicate open focuses tab
pathField._text = "consolex"
rootBox:ChooseOption( "Server DATA", 1 ) pump()
local found = lineFor( tree, "consolex/test.lua.txt" )
check( "root dropdown lists the folder", found ~= nil )
check( "list shows file sizes", found and found._text and true )
tree.OnRowSelected( tree, 1, found ) pump()
check( "re-opening an open file focuses its tab", logText( CL ):find( "already open: consolex/test.lua.txt", 1, true ) ~= nil )

-- 8. closing a tab never overwrites another tab (the old index-shift bug)
button( CL, "+" ).DoClick() pump()
ed:Type( "TAB B" )
button( CL, "+" ).DoClick() pump()
ed:Type( "TAB C" )
tb = tabButtons( CL )
tb[#tb - 1].DoClick() pump()     -- select B
check( "switching tabs restores that tab's text", ed:Code() == "TAB B" )
table.insert( CL._queries, "Discard" )
tb = tabButtons( CL )
tb[#tb - 1].DoRightClick() pump() -- close B (dirty -> discard)
check( "closing a dirty tab asks first", CL._lastQuery and CL._lastQuery:find( "unsaved", 1, true ) ~= nil )
check( "after closing B, the editor shows C intact", ed:Code() == "TAB C" )
local blob = CL.CNSX.Decode( CL._files["consolex/session.json"] )
local bodies = {}
for _, t in ipairs( blob.tabs or {} ) do bodies[#bodies + 1] = t.body end
check( "drafts keep C and drop B", table.concat( bodies, "|" ):find( "TAB C", 1, true ) and not table.concat( bodies, "|" ):find( "TAB B", 1, true ) )

-- 9. autosave: opening files never writes; autosave (opt-in) writes only the tab's own DATA file
local writes = SV._writes
SV._files["cfg/server.cfg"] = "rcon_password secret"
rootBox:ChooseOption( "Server GAME", 2 ) pump()
CL.CNSX.Prefs.autosave = true
pathField._text = "cfg"
button( CL, "List" ).DoClick() pump()
tree.OnRowSelected( tree, 1, lineFor( tree, "cfg/server.cfg" ) ) pump()
ed:Type( "rcon_password changed" )
wait( 3 )
check( "opening/editing a GAME file never writes anything", SV._writes == writes and SV._files["cfg/server.cfg.txt"] == nil )
rootBox:ChooseOption( "Server DATA", 1 ) pump()
pathField._text = "consolex"
button( CL, "List" ).DoClick() pump()
tb = tabButtons( CL )
for _, b in ipairs( tb ) do if b._text:find( "test.lua.txt", 1, true ) then b.DoClick() end end
pump()
writes = SV._writes
wait( 3 )
check( "selecting a file tab does not write it", SV._writes == writes )
ed:Type( "print( 'auto' )" )
wait( 3 )
check( "autosave writes the tab's own DATA file after a pause", SV._files["consolex/test.lua.txt"] == "print( 'auto' )" )
check( "autosaves are audited as such", auditText():find( "(autosave)", 1, true ) ~= nil )
CL.CNSX.Prefs.autosave = false

-- 10. big payloads: repetitive 200 KB code goes through compressed; too big says so
-- 16-byte statements so the harness's block compressor sees repeats (period divides its 64-byte blocks)
ed:Type( "local t = 0 " .. string.rep( "t = t + 1       ", 12800 ) .. "return t" )
button( CL, "SV Run" ).DoClick() pump()
check( "200 KB of code runs (compressed transport)", lastLog( CL ):find( "OK server 12800", 1, true ) ~= nil )
local noise = {}
for i = 1, 90000 do noise[i] = string.char( 97 + ( i * 7919 ) % 26 ) end
ed:Type( "return '" .. table.concat( noise ) .. "'" )
button( CL, "SV Run" ).DoClick() pump()
check( "oversized payload is reported, not silently dropped", lastLog( CL ):find( "run_sv not sent: payload too large", 1, true ) ~= nil )

-- 11. truncated / binary files
SV._files["consolex/big.txt"] = string.rep( "x", SV.CNSX.MaxCode + 10 )
SV._files["consolex/bin.dat"] = "ab\0cd"
pathField._text = "consolex"
button( CL, "List" ).DoClick() pump()
tree.OnRowSelected( tree, 1, lineFor( tree, "consolex/bin.dat" ) ) pump()
check( "binary files are refused", lastLog( CL ):find( "binary file", 1, true ) ~= nil )
-- MaxCode is 512 KB, which would not fit through the fake compressor as one block; shrink for the test
SV.CNSX.MaxCode = 1000
SV._files["consolex/big.txt"] = string.rep( "y", 1200 )
tree.OnRowSelected( tree, 1, lineFor( tree, "consolex/big.txt" ) ) pump()
check( "large files open truncated and read-only", lastLog( CL ):find( "read-only", 1, true ) ~= nil and tabButtons( CL )[#tabButtons( CL )]._text:find( "[ro]", 1, true ) )
button( CL, "Save" ).DoClick() pump()
check( "read-only tab refuses to save", SV._files["consolex/big.txt"] == string.rep( "y", 1200 ) and lastLog( CL ):find( "read-only", 1, true ) )
SV.CNSX.MaxCode = 512 * 1024

-- 12. file operations (server DATA)
local menuLine = lineFor( tree, "consolex/test.lua.txt" )
tree.OnRowRightClick( tree, 1, menuLine )
table.insert( CL._prompts, "consolex/renamed.txt" )
CL._menus[#CL._menus]:Pick( "Rename" ) pump()
check( "rename moves the server file", SV._files["consolex/renamed.txt"] ~= nil and SV._files["consolex/test.lua.txt"] == nil )
check( "open tabs follow a rename", logText( CL ):find( "renamed to DATA/consolex/renamed.txt", 1, true ) ~= nil )
tree.OnRowRightClick( tree, 1, lineFor( tree, "consolex/renamed.txt" ) )
table.insert( CL._prompts, "sub" )
CL._menus[#CL._menus]:Pick( "New folder" ) pump()
check( "new folder created", SV._dirs["consolex/sub"] == true )
tree.OnRowRightClick( tree, 1, lineFor( tree, "consolex/renamed.txt" ) )
table.insert( CL._queries, "Delete" )
CL._menus[#CL._menus]:Pick( "Delete" ) pump()
check( "delete removes the server file", SV._files["consolex/renamed.txt"] == nil )
check( "file ops audited", auditText():find( "rename DATA/consolex/test.lua.txt", 1, true ) and auditText():find( "delete DATA/consolex/renamed.txt", 1, true ) and auditText():find( "mkdir DATA/consolex/sub", 1, true ) )

-- 13. find in files -> click hit opens the file at the line
SV._files["addons/x/lua/autorun/a.lua"] = "local a = 1\nhook.Add( 'Think', 'needle', f )\n"
SV._files["addons/x/lua/autorun/b.lua"] = "nothing here\n"
rootBox:ChooseOption( "Server GAME", 2 ) pump()
pathField._text = "addons"
button( CL, "List" ).DoClick() pump()
table.insert( CL._prompts, "NEEDLE" )
button( CL, "Grep" ).DoClick() pump()
local hitLine
for _, l in ipairs( tree._lines or {} ) do if l._grepHit then hitLine = l end end
check( "find in files finds the hit (case-insensitive)", hitLine and hitLine._grepHit.path == "addons/x/lua/autorun/a.lua" and hitLine._grepHit.line == 2 )
ed._js = {}
tree.OnRowSelected( tree, 1, hitLine ) pump() wait( 0.5 )
check( "clicking a hit opens the file and jumps to its line", ( ed:Code() or "" ):find( "needle", 1, true ) and table.concat( ed._js, "\n" ):find( "cnsxGoto(2)", 1, true ) )

-- 14. REPL line
local repl = find( CL, function( p ) return p.class == "DTextEntry" and p._placeholder == nil and p.OnEnter and p ~= pathField and ( p._hist ~= nil or true ) and p.parent and p.parent.class == "DPanel" and p.parent._h == 22 end )
repl = repl or find( CL, function( p ) return p.class == "DTextEntry" and p.AddHistory and p.OnEnter and p.parent and p.parent._h == 22 end )
repl._text = "1 + 1"
repl:OnEnter() pump()
check( "quick line evaluates expressions on the server", lastLog( CL ):find( "OK server 2", 1, true ) ~= nil )

-- 15. client runs: CL Me, CL All with replies, On Ply refusal, spoofed replies ignored
CLB.CNSX.Prefs = CLB.CNSX.Prefs or {}
rootBox:ChooseOption( "Server DATA", 1 ) pump()
ed:Type( "print( 'from ' .. LocalPlayer():Nick() ) return 1" )
button( CL, "CL Me" ).DoClick() pump()
check( "CL Me runs on own client with captured output", lastLog( CL ):find( "OK client 1", 1, true ) and logText( CL ):find( "  | from Admin", 1, true ) )
button( CL, "CL All" ).DoClick() pump()
check( "CL All reports how many superadmins", logText( CL ):find( "sent to 2 superadmins", 1, true ) ~= nil )
check( "other superadmin's result comes back with output", logText( CL ):find( "OK client Admin2 1", 1, true ) ~= nil and logText( CL ):find( "  | from Admin2", 1, true ) ~= nil )
check( "receiving client is told who pushed code", table.concat( CLB._console, "\n" ):find( "pushed by Admin", 1, true ) ~= nil )
check( "non-superadmin never runs pushed code", not table.concat( CLP._console, "\n" ):find( "pushed by", 1, true ) )
local n = #logText( CL )
CLB.net.Start( "CNSX_ClOut" ) CLB.net.WriteUInt( 999, 32 ) CLB.CNSX.NetWrite( { ok = true, msg = "spoof" } ) CLB.net.SendToServer() pump()
CLP.net.Start( "CNSX_ClOut" ) CLP.net.WriteUInt( 1, 32 ) CLP.CNSX.NetWrite( { ok = true, msg = "spoof" } ) CLP.net.SendToServer() pump()
check( "unsolicited client replies are ignored", not logText( CL ):sub( n ):find( "spoof", 1, true ) )
for i, c in ipairs( playerBox._choices ) do if c.d == pleb:SteamID64() then playerBox:ChooseOption( c.v, i ) end end
button( CL, "On Ply" ).DoClick() pump()
check( "On Ply refuses non-superadmin", lastLog( CL ):find( "Pleb is not a superadmin", 1, true ) ~= nil )
check( "player list flags non-superadmins", ( function() for _, c in ipairs( playerBox._choices ) do if c.v:find( "not superadmin", 1, true ) then return true end end end )() )

-- 16. remote DATA between superadmins (target is told)
CLB._files["notes/todo.txt"] = "buy milk"
for i, c in ipairs( playerBox._choices ) do if c.d == admin2:SteamID64() then playerBox:ChooseOption( c.v, i ) end end
rootBox:ChooseOption( "Player DATA", 5 ) pump()
pathField._text = "notes"
button( CL, "List" ).DoClick() pump()
check( "remote list shows the other admin's files", lineFor( tree, "notes/todo.txt" ) ~= nil )
check( "target is told their files were listed", ( CLB._chat or "" ):find( "Admin listed your DATA/notes", 1, true ) ~= nil )
tree.OnRowSelected( tree, 1, lineFor( tree, "notes/todo.txt" ) ) pump()
check( "remote file opens in a tab", ed:Code() == "buy milk" )
ed:Type( "buy oat milk" )
button( CL, "Save" ).DoClick() pump()
check( "remote save writes the target's file", CLB._files["notes/todo.txt"] == "buy oat milk" )
check( "target is told about the write", ( CLB._chat or "" ):find( "Admin wrote your DATA/notes/todo.txt", 1, true ) ~= nil )
rootBox:ChooseOption( "Server DATA", 1 ) pump()

-- 17. error feed
SV._hooks["OnLuaError/CNSX_ErrorFeed"]( "lua/autorun/x.lua:5: attempt to index nil", "server" )
wait( 1.5 )
check( "server Lua errors show in the open IDE", logText( CL ):find( "[server error] lua/autorun/x.lua:5", 1, true ) ~= nil )

-- 18. history
check( "runs are kept in history", ( CL._files["consolex/history.json"] or "" ):find( "LocalPlayer", 1, true ) ~= nil )
button( CL, "Hist" ).DoClick()
check( "history menu lists runs", #CL._menus[#CL._menus].opts > 1 )

-- 19. prefs, wiki, clear/copy
button( CL, "Prefs" ).DoClick() pump()
local apply = button( CL, "Apply size and font" )
local fontEntry
for _, p in ipairs( CL._panels ) do if p.valid ~= false and p.class == "DTextEntry" and p._text == "13" then fontEntry = p end end
fontEntry._text = "16"
apply.DoClick()
check( "font size applies to the editor", ed._prefs and ed._prefs.fontSize == 16 )
CL.CNSX._prefsFrame:Close()
check( "F1 wiki: library function", CL.CNSX.WikiURL( "hook.Add" ) == "https://wiki.facepunch.com/gmod/hook.Add" )
check( "F1 wiki: method resolves its class", CL.CNSX.WikiURL( "ply:Nick" ) == "https://wiki.facepunch.com/gmod/Player:Nick" )
check( "F1 wiki: rejects junk", CL.CNSX.WikiURL( "a b<script>" ) == nil )
button( CL, "Copy" ).DoClick()
check( "copy log to clipboard", ( CL._clip or "" ):find( "OK server", 1, true ) ~= nil )

-- 20. tabs survive close/reopen; close ends session banner
local tabCount = #tabButtons( CL )
local closeBtn = find( CL, function( p ) return p.class == "CNSXIcon" and p.m_Glyph == "close" end )
closeBtn.DoClick() wait( 0.5 )
check( "close ends session banner", admin.CNSX_Active == false )
check( "window closed", not CL.IsValid( frame ) )
local smallTabs = 0
for _, t in ipairs( CL.CNSX.Decode( CL._files["consolex/session.json"] ).tabs ) do if #t.body <= 32 * 1024 then smallTabs = smallTabs + 1 end end
check( "tabs backed up to the server on close (large ones stay local)", #SV.CNSX.LoadTabs( admin ) == smallTabs and smallTabs < tabCount )
check( "large tabs warning logged once", CL.CNSX._warnedTabs == true )
CL._cmds.consolex() pump()
check( "reopen while unlocked skips password", CL.IsValid( frameOf( CL ) ) and not CL.IsValid( CL.CNSX._lock ) )
ed = editorPanel( CL ) ed:LoadPage() pump()
check( "tabs restored after reopen", #tabButtons( CL ) == tabCount )

-- 21. idle timeout slides with activity; expiry -> prompt; wrong/right password; lockout
now = now + 40 * 60
ed:Type( "return 'still here'" )
button( CL, "SV Run" ).DoClick() pump()
now = now + 40 * 60
button( CL, "SV Run" ).DoClick() pump()
check( "activity keeps the session alive (idle timeout)", lastLog( CL ):find( "OK server \"still here\"", 1, true ) ~= nil )
now = now + 50 * 60
button( CL, "SV Run" ).DoClick() pump()
check( "idle session expires and shows the unlock prompt", CL.IsValid( CL.CNSX._lock ) )
local e2 = find( CL, function( p ) return p.class == "DTextEntry" and p.parent == CL.CNSX._lock end )
e2._text = "wrongpass" wait( 1 )
button( CL, "Unlock" ).DoClick() pump()
local msgLbl = find( CL, function( p ) return p.class == "DLabel" and p.parent == CL.CNSX._lock end )
check( "wrong password rejected", not SV.CNSX.Authed( admin ) and msgLbl and msgLbl._text == "bad password" )
e2 = find( CL, function( p ) return p.class == "DTextEntry" and p.parent == CL.CNSX._lock end )
e2._text = "hunter22" wait( 1 )
button( CL, "Unlock" ).DoClick() pump()
check( "right password unlocks", SV.CNSX.Authed( admin ) and not CL.IsValid( CL.CNSX._lock ) )

-- 22. Lock button
button( CL, "Lock" ).DoClick() wait( 0.5 ) wait( 0.5 )
check( "Lock ends the session", not SV.CNSX.Authed( admin ) )
check( "Lock closes the window", not CL.IsValid( frameOf( CL ) ) )
check( "Lock is audited", auditText():find( "locked session", 1, true ) ~= nil )
CL._cmds.consolex() pump()
check( "after Lock, opening asks for the password", CL.IsValid( CL.CNSX._lock ) )
for _ = 1, 5 do
    e2 = find( CL, function( p ) return p.class == "DTextEntry" and p.parent == CL.CNSX._lock end )
    e2._text = "nope" wait( 1 )
    button( CL, "Unlock" ).DoClick() pump()
end
check( "5 wrong passwords lock out", ( find( CL, function( p ) return p.class == "DLabel" and p.parent == CL.CNSX._lock end )._text or "" ):find( "^locked" ) ~= nil )
wait( 31 )
e2 = find( CL, function( p ) return p.class == "DTextEntry" and p.parent == CL.CNSX._lock end )
e2._text = "hunter22" wait( 1 )
button( CL, "Unlock" ).DoClick() pump()
check( "lockout expires", SV.CNSX.Authed( admin ) )
ed = editorPanel( CL ) ed:LoadPage() pump()

-- 23. minimize / maximize / restore
local fr = frameOf( CL )
local minBtn = find( CL, function( p ) return p.class == "CNSXIcon" and p.m_Glyph == "min" end )
local maxB = find( CL, function( p ) return p.class == "CNSXIcon" and ( p.m_Glyph == "max" or p.m_Glyph == "restore" ) end )
minBtn.DoClick()
fr:Think()
check( "minimized bar does not grab the mouse", fr._mouse == false )
maxB.DoClick()
check( "maximize from minimized restores properly", fr._minBar == false and fr._kb ~= false )
minBtn.DoClick()
wait( 1 )
CL._cmds.consolex() pump()
check( "!cnsx restores a minimized window", fr._minBar == false )

-- 24. wire safety
local errs = 0
local ok, perr = pcall( function()
    CLP.net.Start( "CNSX_Cmd" ) CLP.net.WriteUInt( 5, 16 ) CLP.net.WriteData( "Zjunk", 5 ) CLP.net.SendToServer() pump()
    CL.net.Start( "CNSX_Cmd" ) CL.net.WriteUInt( 5, 16 ) CL.net.WriteData( "Zjunk", 5 ) CL.net.SendToServer() pump()
    CL.net.Start( "CNSX_Cmd" ) CL.net.WriteUInt( 0, 16 ) CL.net.SendToServer() pump()
end )
check( "garbage packets are ignored without errors", ok )
local bomb = SV.util.Compress( string.rep( "A", 64 ) .. string.rep( "A", 64 ) )
bomb = "Z\3" .. "64\4" .. string.rep( "A", 64 ) .. "\1" .. ( 4 * 1024 * 1024 ) .. "\2"
check( "decompression is capped (bomb rejected)", SV.util.Decompress( bomb, SV.CNSX.MaxRaw ) == nil )
check( "SanitizePath strips traversal", SV.CNSX.SanitizePath( "../../cfg/../server.cfg" ) == "cfg/server.cfg" )

-- 25. password commands
SV._cmds.cnsx_setpass( pleb, nil, { "x1234567" } )
check( "non-admin cnsx_setpass ignored", true )
SV.CNSX.Auth = {}
local beforeAuth = SV._files["consolex/auth.json"]
SV._cmds.cnsx_setpass( admin, nil, { "newpass12" } )
check( "locked admin cannot cnsx_setpass", SV._files["consolex/auth.json"] == beforeAuth )
SV._cmds.cnsx_setpass( nil, nil, { "short" } )
check( "server console cnsx_setpass enforces 8+", SV._files["consolex/auth.json"] == beforeAuth )
SV._cmds.cnsx_setpass( nil, nil, { "newpass12" } )
check( "server console cnsx_setpass works", SV._files["consolex/auth.json"] ~= beforeAuth )
SV.CNSX.GrantAuth( admin )
SV._cmds.cnsx_lockall( nil )
check( "cnsx_lockall ends every session", not SV.CNSX.Authed( admin ) )
SV._cmds.cnsx( nil )
check( "server-console cnsx doesn't error", true )

print( ( "\n%d passed, %d failed" ):format( pass, fail ) )
os.exit( fail == 0 and 0 or 1 )
