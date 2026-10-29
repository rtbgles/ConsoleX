CNSX = CNSX or {}
CNSX.Version = "1.6.0"

-- wire limits: payloads are JSON, LZMA-compressed, then sent as one net message (hard cap 64KB)
CNSX.MaxPacket = 63 * 1024
CNSX.MaxRaw = 2 * 1024 * 1024
-- largest file/code body the IDE edits; bigger files open truncated and read-only
CNSX.MaxCode = 512 * 1024
CNSX.MaxRead = 4 * 1024 * 1024

CNSX.Roots = {
    data = "DATA",
    game = "GAME",
    lua = "LUA"
}

if SERVER then
    CreateConVar( "cnsx_session_min", "45", { FCVAR_ARCHIVE, FCVAR_PROTECTED }, "Idle minutes before a CNSX unlock expires (5-240)" )
    CreateConVar( "cnsx_error_feed", "1", { FCVAR_ARCHIVE }, "Forward server Lua errors to open CNSX sessions" )
end

function CNSX.Allowed( ply )
    if not IsValid( ply ) then
        return false
    end
    if ply:IsSuperAdmin() then
        return true
    end
    if ply.IsListenServerHost and ply:IsListenServerHost() then
        return true
    end
    if game.SinglePlayer() then
        return true
    end
    local grp = string.lower( tostring( ply:GetUserGroup() or "" ) )

    return grp == "superadmin" or grp == "owner" or grp == "root"
end

if SERVER then
    util.AddNetworkString( "CNSX_Auth" )
    util.AddNetworkString( "CNSX_Open" )
    util.AddNetworkString( "CNSX_Cmd" )
    util.AddNetworkString( "CNSX_Out" )
    util.AddNetworkString( "CNSX_RunCl" )
    util.AddNetworkString( "CNSX_ClOut" )
    util.AddNetworkString( "CNSX_Remote" )
    util.AddNetworkString( "CNSX_RemoteOut" )
    util.AddNetworkString( "CNSX_Busy" )
end

function CNSX.SanitizePath( path )
    path = string.gsub( tostring( path or "" ), "\\", "/" )
    path = string.gsub( path, "%.%.", "" )
    path = string.gsub( path, "/+", "/" )
    path = string.gsub( path, "^/+", "" )
    path = string.gsub( path, "/+$", "" )

    return path
end

-- file.Write refuses anything outside this list (notably .lua), so such saves get ".txt" appended
CNSX.WriteExts = {
    txt = true, dat = true, json = true, xml = true, csv = true, dem = true, vcd = true,
    vtf = true, vmt = true, png = true, jpg = true, jpeg = true, mp3 = true, wav = true, ogg = true
}

function CNSX.WritablePath( path )
    path = string.lower( CNSX.SanitizePath( path ) )
    local ext = string.lower( string.GetExtensionFromFilename( path ) or "" )
    if CNSX.WriteExts[ext] then
        return path
    end

    return path .. ".txt"
end

-- shared by the server write and the client's local/remote writes; returns ok, finalPath, err
function CNSX.WriteData( path, body )
    path = CNSX.WritablePath( path )
    if path == "" or path == ".txt" then
        return false, path, "bad path"
    end
    if file.IsDir( path, "DATA" ) then
        return false, path, "a folder has that name"
    end
    local folder = string.GetPathFromFilename( path )
    if folder and folder ~= "" then
        file.CreateDir( string.TrimRight( folder, "/" ) )
    end
    body = tostring( body or "" )
    local res = file.Write( path, body )
    local ok = res
    if not isbool( res ) then
        ok = file.Read( path, "DATA" ) == body
    end
    if not ok then
        return false, path, "write failed"
    end

    return true, path
end

-- DATA-only file operations, shared by the server and the client's My DATA root
function CNSX.DeleteData( path )
    path = CNSX.SanitizePath( path )
    if path == "" or not file.Exists( path, "DATA" ) then
        return false, "missing"
    end
    if file.IsDir( path, "DATA" ) then
        local files, dirs = file.Find( path .. "/*", "DATA" )
        if #( files or {} ) > 0 or #( dirs or {} ) > 0 then
            return false, "folder is not empty"
        end
    end
    file.Delete( path, "DATA" )
    if file.Exists( path, "DATA" ) then
        return false, "delete failed"
    end

    return true
end

function CNSX.RenameData( from, to )
    from = CNSX.SanitizePath( from )
    if from == "" or not file.Exists( from, "DATA" ) then
        return false, from, "missing"
    end
    if file.IsDir( from, "DATA" ) then
        to = string.lower( CNSX.SanitizePath( to ) )
    else
        to = CNSX.WritablePath( to )
    end
    if to == "" or to == ".txt" then
        return false, to, "bad name"
    end
    if file.Exists( to, "DATA" ) then
        return false, to, "target exists"
    end
    local folder = string.GetPathFromFilename( to )
    if folder and folder ~= "" then
        file.CreateDir( string.TrimRight( folder, "/" ) )
    end
    if not file.Rename( from, to ) then
        return false, to, "rename failed"
    end

    return true, to
end

function CNSX.MkdirData( path )
    path = string.lower( CNSX.SanitizePath( path ) )
    if path == "" then
        return false, path, "bad path"
    end
    file.CreateDir( path )
    if not file.IsDir( path, "DATA" ) then
        return false, path, "mkdir failed"
    end

    return true, path
end

-- one directory level; dirs first, then files, with sizes. Returns rows, truncated
local LIST_MAX = 1000

function CNSX.ListDir( path, root )
    path = CNSX.SanitizePath( path )
    local wildcard = path == "" and "*" or ( path .. "/*" )
    local files, dirs = file.Find( wildcard, root )
    local rows = {}
    local truncated = false
    local function add( name, isDir )
        if #rows >= LIST_MAX then
            truncated = true
            return
        end
        local full = path == "" and name or ( path .. "/" .. name )
        rows[#rows + 1] = { name = name, dir = isDir, path = full, size = ( not isDir ) and file.Size( full, root ) or nil }
    end
    table.sort( dirs or {} )
    table.sort( files or {} )
    for _, name in ipairs( dirs or {} ) do
        add( name, true )
    end
    for _, name in ipairs( files or {} ) do
        add( name, false )
    end

    return rows, truncated
end

-- reads a text file for the editor; returns body, err, readOnly
function CNSX.ReadText( path, root )
    path = CNSX.SanitizePath( path )
    if path == "" or not file.Exists( path, root ) or file.IsDir( path, root ) then
        return nil, "missing"
    end
    local size = file.Size( path, root ) or 0
    if size > CNSX.MaxRead then
        return nil, "too large (" .. math.ceil( size / 1024 ) .. " KB)"
    end
    local body = file.Read( path, root )
    if not body then
        return nil, "unreadable"
    end
    if string.find( string.sub( body, 1, 8192 ), "\0", 1, true ) then
        return nil, "binary file (" .. #body .. " bytes)"
    end
    if #body > CNSX.MaxCode then
        return string.sub( body, 1, CNSX.MaxCode ), "truncated to " .. math.floor( CNSX.MaxCode / 1024 ) .. " KB; opened read-only", true
    end

    return body
end

function CNSX.RootName( key )
    key = string.lower( tostring( key or "data" ) )

    return CNSX.Roots[key] or "DATA"
end

function CNSX.Encode( tbl )
    return util.TableToJSON( tbl or {} ) or "{}"
end

function CNSX.Decode( raw )
    if not isstring( raw ) or raw == "" then
        return {}
    end
    local ok, data = pcall( util.JSONToTable, raw )
    if not ok or not istable( data ) then
        return {}
    end

    return data
end

-- returns the compressed payload, or nil and a reason
function CNSX.Pack( tbl )
    local raw = CNSX.Encode( tbl )
    if #raw > CNSX.MaxRaw then
        return nil, "payload too large (" .. math.ceil( #raw / 1024 ) .. " KB)"
    end
    local packed = util.Compress( raw )
    if not isstring( packed ) or packed == "" then
        return nil, "compress failed"
    end
    if #packed > CNSX.MaxPacket then
        return nil, "payload too large (" .. math.ceil( #packed / 1024 ) .. " KB compressed, limit " .. math.floor( CNSX.MaxPacket / 1024 ) .. " KB)"
    end

    return packed
end

-- call between net.Start and net.Send. Oversized payloads are replaced by an error that keeps kind/act/id,
-- so the receiver can report it instead of the message silently vanishing. Returns ok, err
function CNSX.NetWrite( tbl )
    local packed, err = CNSX.Pack( tbl )
    if not packed then
        packed = CNSX.Pack( { kind = tbl.kind, act = tbl.act, id = tbl.id, tabId = tbl.tabId, realm = tbl.realm, err = err } )
    end
    CNSX.NetWritePacked( packed )

    return err == nil, err
end

function CNSX.NetWritePacked( packed )
    net.WriteUInt( #packed, 16 )
    net.WriteData( packed, #packed )
end

function CNSX.NetRead()
    local len = net.ReadUInt( 16 )
    if not len or len <= 0 or len > CNSX.MaxPacket then
        return {}
    end
    local packed = net.ReadData( len )
    -- maxSize guards against decompression bombs
    local raw = util.Decompress( packed, CNSX.MaxRaw )
    if not isstring( raw ) then
        return {}
    end

    return CNSX.Decode( raw )
end

-- readable dump of return values: tables expand a few levels, capped in size
local PRETTY_MAX = 8000
local PRETTY_DEPTH = 3
local PRETTY_KEYS = 64

local function prettyKey( k )
    if isstring( k ) and string.match( k, "^[%a_][%w_]*$" ) then
        return k
    end

    return "[" .. ( isstring( k ) and string.format( "%q", k ) or tostring( k ) ) .. "]"
end

local function prettyValue( v, depth, seen, out )
    if #out > PRETTY_MAX then
        return
    end
    if isstring( v ) then
        out[#out + 1] = string.format( "%q", v )
        return
    end
    if not istable( v ) or IsColor( v ) then
        out[#out + 1] = tostring( v )
        return
    end
    if seen[v] then
        out[#out + 1] = "<cycle " .. tostring( v ) .. ">"
        return
    end
    if depth >= PRETTY_DEPTH then
        out[#out + 1] = tostring( v )
        return
    end
    seen[v] = true
    local keys = {}
    for k in pairs( v ) do
        keys[#keys + 1] = k
    end
    table.sort( keys, function( a, b )
        if isnumber( a ) and isnumber( b ) then
            return a < b
        end

        return tostring( a ) < tostring( b )
    end )
    if #keys == 0 then
        out[#out + 1] = "{}"
        seen[v] = nil
        return
    end
    local pad = string.rep( "    ", depth + 1 )
    out[#out + 1] = "{\n"
    for i, k in ipairs( keys ) do
        if i > PRETTY_KEYS then
            out[#out + 1] = pad .. "... " .. ( #keys - PRETTY_KEYS ) .. " more\n"
            break
        end
        out[#out + 1] = pad .. prettyKey( k ) .. " = "
        prettyValue( v[k], depth + 1, seen, out )
        out[#out + 1] = ",\n"
    end
    out[#out + 1] = string.rep( "    ", depth ) .. "}"
    seen[v] = nil
end

function CNSX.Pretty( v )
    local out = {}
    prettyValue( v, 0, {}, out )
    local s = table.concat( out )
    if #s > PRETTY_MAX then
        s = string.sub( s, 1, PRETTY_MAX ) .. "\n... (truncated)"
    end

    return s
end

local CAPTURE_MAX = 16000
local CAPTURED = { "print", "Msg", "MsgN", "MsgC", "ErrorNoHalt" }

local function joinArgs( sep, ... )
    local parts = {}
    for i = 1, select( "#", ... ) do
        local v = select( i, ... )
        if not IsColor( v ) then
            parts[#parts + 1] = tostring( v )
        end
    end

    return table.concat( parts, sep )
end

local function pack( ... )
    return { n = select( "#", ... ), ... }
end

local function traceback( err )
    local tb = debug.traceback( tostring( err ), 2 ) or tostring( err )
    -- drop the frames that belong to CNSX itself (everything from the xpcall down)
    local cut = string.find( tb, "\n%s*%[C%]: in function 'xpcall'" )
    if cut then
        tb = string.sub( tb, 1, cut - 1 )
    end

    return tb
end

--[[
    Compiles and runs code with print/Msg/MsgN/MsgC/ErrorNoHalt output captured (and still echoed to the console).
    Returns ok, message, captured output. Errors include a stack trace.
]]
function CNSX.RunCaptured( code, chunk )
    code = tostring( code or "" )
    if code == "" then
        return false, "empty", ""
    end
    local fn = CompileString( code, chunk or "CNSX", false )
    if not isfunction( fn ) then
        return false, tostring( fn or "compile error" ), ""
    end

    local buf, size = {}, 0
    local function add( s )
        if size >= CAPTURE_MAX then
            return
        end
        s = string.sub( s, 1, CAPTURE_MAX - size )
        size = size + #s
        buf[#buf + 1] = s
    end
    local orig, wrappers = {}, {}
    for _, name in ipairs( CAPTURED ) do
        orig[name] = _G[name]
    end
    wrappers.print = function( ... ) add( joinArgs( "\t", ... ) .. "\n" ) return orig.print( ... ) end
    wrappers.Msg = function( ... ) add( joinArgs( "", ... ) ) return orig.Msg( ... ) end
    wrappers.MsgN = function( ... ) add( joinArgs( "", ... ) .. "\n" ) return orig.MsgN( ... ) end
    wrappers.MsgC = function( ... ) add( joinArgs( "", ... ) ) return orig.MsgC( ... ) end
    wrappers.ErrorNoHalt = function( ... ) add( joinArgs( "", ... ) ) return orig.ErrorNoHalt( ... ) end
    for _, name in ipairs( CAPTURED ) do
        if isfunction( orig[name] ) then
            _G[name] = wrappers[name]
        end
    end

    local res = pack( xpcall( fn, traceback ) )

    -- restore, unless the code itself replaced the function on purpose
    for _, name in ipairs( CAPTURED ) do
        if _G[name] == wrappers[name] then
            _G[name] = orig[name]
        end
    end

    local out = table.concat( buf )
    if size >= CAPTURE_MAX then
        out = out .. "\n... (output truncated)"
    end
    if not res[1] then
        return false, tostring( res[2] ), out
    end
    if res.n <= 1 then
        return true, "ok", out
    end
    local parts = {}
    for i = 2, res.n do
        parts[#parts + 1] = CNSX.Pretty( res[i] )
    end

    return true, table.concat( parts, ", " ), out
end

-- API names for autocomplete; each realm collects its own and the editor tags entries SV/CL/SH
local META_CLASSES = {
    "Entity", "Player", "Weapon", "NPC", "Vehicle", "NextBot", "PhysObj", "Vector", "Angle", "VMatrix",
    "CTakeDamageInfo", "CEffectData", "CUserCmd", "CMoveData", "CNavArea", "CNavLadder", "PathFollower",
    "CRecipientFilter", "CSoundPatch", "ConVar", "File", "IMaterial", "ITexture", "IMesh", "IRestore", "ISave",
    "Color", "bf_read", "CLuaLocomotion", "SurfaceInfo", "Stack", "Tool", "ProjectedTexture", "IGModAudioChannel",
    "Panel", "CLuaEmitter", "CLuaParticle", "pixelvis_handle_t", "IVideoWriter", "CNewParticleEffect"
}
CNSX.MetaClasses = META_CLASSES

function CNSX.CollectAPI()
    local libs, globals, methods = {}, {}, {}
    local function ident( s )
        return isstring( s ) and string.match( s, "^[%a_][%w_]*$" ) ~= nil
    end
    for k, v in pairs( _G ) do
        if ident( k ) then
            if isfunction( v ) then
                globals[#globals + 1] = k
            elseif istable( v ) and k ~= "_G" and not IsColor( v ) then
                local n = 0
                for k2, v2 in pairs( v ) do
                    if isfunction( v2 ) and ident( k2 ) then
                        libs[#libs + 1] = k .. "." .. k2
                        n = n + 1
                        if n > 400 then
                            break
                        end
                    end
                end
            end
        end
    end
    for _, class in ipairs( META_CLASSES ) do
        local meta = FindMetaTable( class )
        if istable( meta ) then
            for k, v in pairs( meta ) do
                if isfunction( v ) and ident( k ) and not string.StartsWith( k, "__" ) then
                    methods[#methods + 1] = class .. ":" .. k
                end
            end
        end
    end
    table.sort( globals )
    table.sort( libs )
    table.sort( methods )

    return { globals = table.concat( globals, "\n" ), libs = table.concat( libs, "\n" ), methods = table.concat( methods, "\n" ) }
end

-- find in files: walks a tree inside a coroutine, a few ms per frame, so a big LUA/GAME search never hitches
local GREP_FILES = 6000
local GREP_HITS = 300
local GREP_BUDGET = 0.004
local GREP_FILE_MAX = 1024 * 1024
local GREP_EXTS = {
    lua = true, txt = true, json = true, cfg = true, vmt = true, xml = true, csv = true,
    md = true, html = true, js = true, css = true, properties = true, ini = true, dat = true
}

local function grepWorker( job )
    local hits, scanned = {}, 0
    local needle = job.case and job.query or string.lower( job.query )
    local function match( line )
        if not job.case then
            line = string.lower( line )
        end
        if job.pattern then
            local ok, found = pcall( string.find, line, needle )
            return ok and found ~= nil
        end

        return string.find( line, needle, 1, true ) ~= nil
    end
    local function walk( dir )
        local files, dirs = file.Find( dir == "" and "*" or ( dir .. "/*" ), job.root )
        for _, name in ipairs( files or {} ) do
            if scanned >= GREP_FILES or #hits >= GREP_HITS then
                return
            end
            local path = dir == "" and name or ( dir .. "/" .. name )
            local ext = string.lower( string.GetExtensionFromFilename( name ) or "" )
            if GREP_EXTS[ext] and ( file.Size( path, job.root ) or 0 ) <= GREP_FILE_MAX then
                scanned = scanned + 1
                local body = file.Read( path, job.root ) or ""
                local n = 0
                for line in string.gmatch( body .. "\n", "([^\n]*)\n" ) do
                    n = n + 1
                    if match( line ) then
                        hits[#hits + 1] = { path = path, line = n, text = string.sub( string.Trim( line ), 1, 160 ) }
                        if #hits >= GREP_HITS then
                            return
                        end
                    end
                end
            end
            if SysTime() - job.slice > GREP_BUDGET then
                coroutine.yield()
            end
        end
        for _, name in ipairs( dirs or {} ) do
            if scanned >= GREP_FILES or #hits >= GREP_HITS then
                return
            end
            walk( dir == "" and name or ( dir .. "/" .. name ) )
        end
    end
    walk( job.path )

    return hits, scanned
end

function CNSX.GrepNew( data, root )
    local query = tostring( data.query or "" )
    if query == "" or #query > 200 then
        return nil, "search text must be 1-200 characters"
    end
    local job = {
        root = root,
        path = CNSX.SanitizePath( data.path ),
        query = query,
        -- lowercasing a Lua pattern would flip classes (%S -> %s), so patterns are always case-sensitive
        case = data.case == true or data.pattern == true,
        pattern = data.pattern == true,
        started = SysTime()
    }
    job.co = coroutine.create( function()
        return grepWorker( job )
    end )

    return job
end

-- resumes a job for one time slice; returns the result table once finished, nil while still running
function CNSX.GrepStep( job )
    job.slice = SysTime()
    local ok, hits, scanned = coroutine.resume( job.co )
    if not ok then
        return { err = tostring( hits ) }
    end
    if coroutine.status( job.co ) ~= "dead" then
        return nil
    end

    return {
        path = job.path,
        query = job.query,
        hits = hits,
        scanned = scanned,
        capped = #hits >= GREP_HITS or scanned >= GREP_FILES,
        secs = math.Round( SysTime() - job.started, 2 )
    }
end
