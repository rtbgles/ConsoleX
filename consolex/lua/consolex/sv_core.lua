if not SERVER then return end

resource.AddFile( "materials/consolex/cnsx_banner.png" )
resource.AddFile( "materials/consolex/cnsx_icon.png" )
resource.AddFile( "materials/consolex/cnsx_logo.jpg" )

CNSX.Sessions = CNSX.Sessions or {}
CNSX.Auth = CNSX.Auth or {}
CNSX.Fails = CNSX.Fails or {}
CNSX.PendingRemote = CNSX.PendingRemote or {}

local AUTH_FILE = "consolex/auth.json"

local function authLoad()
    file.CreateDir( "consolex" )
    return CNSX.Decode( file.Read( AUTH_FILE, "DATA" ) )
end

local function authSave( tbl )
    file.CreateDir( "consolex" )
    file.Write( AUTH_FILE, CNSX.Encode( tbl ) )
end

local function digest( str )
    str = tostring( str or "" )
    if util.SHA256 then
        local ok, hashed = pcall( util.SHA256, str )
        if ok and isstring( hashed ) and hashed ~= "" then
            return hashed
        end
    end
    return tostring( util.CRC( str ) ) .. tostring( util.CRC( str .. "#cnsx" ) )
end

local function newSalt()
    return digest( tostring( os.time() ) .. tostring( math.random() ) .. tostring( SysTime() ) .. tostring( engine.TickCount() ) )
end

local HASH_ROUNDS = 10000

function CNSX.HashPass( salt, pass )
    return digest( tostring( salt or "" ) .. "\n" .. tostring( pass or "" ) )
end

-- v2: iterated so an auth.json leak can't be brute-forced at raw SHA256 speed
function CNSX.HashPassV2( salt, pass )
    local h = CNSX.HashPass( salt, pass )
    for _ = 1, HASH_ROUNDS do
        h = digest( h .. tostring( salt or "" ) )
    end

    return h
end

local function storePass( pass )
    local salt = newSalt()
    authSave( { salt = salt, hash = CNSX.HashPassV2( salt, pass ), v = 2, t = os.time() } )
end

local function checkPass( auth, pass )
    if auth.v == 2 then
        return auth.hash == CNSX.HashPassV2( auth.salt, pass )
    end
    if auth.hash ~= CNSX.HashPass( auth.salt, pass ) then
        return false
    end
    storePass( pass )

    return true
end

function CNSX.HasMaster()
    local auth = authLoad()
    return isstring( auth.hash ) and auth.hash ~= ""
end

local function plyKey( ply )
    if not IsValid( ply ) then
        return "0"
    end
    return ply:SteamID64() or ply:SteamID() or tostring( ply:EntIndex() )
end

function CNSX.Authed( ply )
    if not IsValid( ply ) then
        return false
    end
    local row = CNSX.Auth[plyKey( ply )]
    if not row then
        return false
    end
    if CurTime() > ( row.expires or 0 ) then
        CNSX.Auth[plyKey( ply )] = nil
        return false
    end
    return true
end

function CNSX.GrantAuth( ply )
    local mins = 45
    local cv = GetConVar( "cnsx_session_min" )
    if cv then
        mins = math.Clamp( cv:GetInt(), 5, 240 )
    end
    CNSX.Auth[plyKey( ply )] = { expires = CurTime() + mins * 60 }
end

local function failAuth( ply )
    local id = ply:SteamID64() or "0"
    local row = CNSX.Fails[id] or { n = 0, lock = 0 }
    row.n = row.n + 1
    if row.n >= 5 then
        row.lock = CurTime() + 30
        row.n = 0
    end
    CNSX.Fails[id] = row
    return row.lock > CurTime(), math.max( 0, math.ceil( row.lock - CurTime() ) )
end

local function sid( ply )
    return ply:SteamID64() or "0"
end

local function userDir( ply )
    return "consolex/users/" .. sid( ply )
end

local function push( ply, kind, payload )
    payload = payload or {}
    payload.kind = kind
    net.Start( "CNSX_Out" )
        net.WriteString( CNSX.Encode( payload ) )
    net.Send( ply )
end

local function auditLine( ply, act, detail )
    local who = IsValid( ply ) and ( ply:Nick() .. " <" .. sid( ply ) .. ">" ) or "Console"
    local line = os.date( "%Y-%m-%d %H:%M:%S" ) .. "  " .. who .. "  " .. act
    ServerLog( "[CNSX] " .. line .. "\n" )
    file.CreateDir( "consolex/audit" )
    file.Append( "consolex/audit/" .. os.date( "%Y-%m-%d" ) .. ".txt", line .. ( detail and ( "\n" .. detail ) or "" ) .. "\n\n" )
end
CNSX.Audit = auditLine

local function canRunClient( ply )
    return IsValid( ply ) and ply:IsSuperAdmin()
end

local function listDir( path, root )
    path = CNSX.SanitizePath( path )
    local wildcard = path == "" and "*" or ( path .. "/*" )
    local files, dirs = file.Find( wildcard, root )
    local rows = {}
    for _, name in ipairs( dirs or {} ) do
        rows[#rows + 1] = { name = name, dir = true, path = path == "" and name or ( path .. "/" .. name ) }
    end
    for _, name in ipairs( files or {} ) do
        rows[#rows + 1] = { name = name, dir = false, path = path == "" and name or ( path .. "/" .. name ) }
    end
    table.sort( rows, function( a, b )
        if a.dir ~= b.dir then
            return a.dir
        end
        return a.name < b.name
    end )
    while #rows > 160 do
        rows[#rows] = nil
    end
    return rows
end

local function readFile( path, root )
    path = CNSX.SanitizePath( path )
    if not file.Exists( path, root ) then
        return nil, "missing"
    end
    local body = file.Read( path, root )
    if not body then
        return nil, "unreadable"
    end
    if #body > CNSX.MaxCode then
        return string.sub( body, 1, CNSX.MaxCode ), "truncated"
    end
    return body
end

local function writeData( path, body )
    path = CNSX.SanitizePath( path )
    if path == "" then
        return false, "bad path"
    end
    local folder = string.GetPathFromFilename( path )
    if folder and folder ~= "" then
        file.CreateDir( string.TrimRight( folder, "/" ) )
    end
    file.Write( path, tostring( body or "" ) )
    return file.Exists( path, "DATA" )
end

function CNSX.SaveTabs( ply, tabs )
    file.CreateDir( "consolex" )
    file.CreateDir( userDir( ply ) )
    file.Write( userDir( ply ) .. "/tabs.json", CNSX.Encode( { tabs = tabs or {}, t = os.time() } ) )
end

function CNSX.LoadTabs( ply )
    local raw = file.Read( userDir( ply ) .. "/tabs.json", "DATA" )
    local data = CNSX.Decode( raw )
    return istable( data.tabs ) and data.tabs or {}
end

local function openIDE( ply )
    local payload = CNSX.Encode( { tabs = CNSX.LoadTabs( ply ) } )
    net.Start( "CNSX_Open" )
        net.WriteString( payload )
    net.Send( ply )
    push( ply, "lock", { unlocked = true } )
end

local function runServer( ply, code )
    code = tostring( code or "" )
    if code == "" then
        return false, "empty"
    end
    CNSX._runner = ply
    local fn, err = CompileString( code, "CNSX:" .. ply:Nick(), false )
    if not isfunction( fn ) then
        CNSX._runner = nil
        return false, tostring( fn or err or "compile" )
    end
    local ok, res = pcall( fn )
    CNSX._runner = nil
    if not ok then
        return false, tostring( res )
    end
    return true, tostring( res == nil and "ok" or res )
end

local function sendStatus( ply )
    push( ply, "lock", { needSet = not CNSX.HasMaster(), unlocked = CNSX.Authed( ply ) } )
    if CNSX.Authed( ply ) then
        openIDE( ply )
    end
end

local function handleAuth( ply, pass )
    if not CNSX.Allowed( ply ) then
        push( ply, "lock", { err = "superadmin only", deny = true } )
        return
    end
    local id = plyKey( ply )
    local fails = CNSX.Fails[id]
    if fails and fails.lock and fails.lock > CurTime() then
        push( ply, "lock", { err = "locked " .. math.ceil( fails.lock - CurTime() ) .. "s", needSet = not CNSX.HasMaster() } )
        return
    end
    pass = tostring( pass or "" )
    if #pass < 4 then
        push( ply, "lock", { err = "password too short", needSet = not CNSX.HasMaster() } )
        return
    end
    if not CNSX.HasMaster() then
        storePass( pass )
        if not file.Exists( AUTH_FILE, "DATA" ) then
            push( ply, "lock", { err = "could not write DATA/" .. AUTH_FILE, needSet = true } )
            return
        end
        auditLine( ply, "set master password (first launch)" )
        CNSX.GrantAuth( ply )
        ply:ChatPrint( "[CNSX] master password set" )
        openIDE( ply )
        return
    end
    if not checkPass( authLoad(), pass ) then
        local locked, wait = failAuth( ply )
        auditLine( ply, "unlock FAILED" )
        push( ply, "lock", { err = locked and ( "locked " .. wait .. "s" ) or "bad password", needSet = false } )
        return
    end
    CNSX.Fails[id] = nil
    auditLine( ply, "unlocked" )
    CNSX.GrantAuth( ply )
    openIDE( ply )
end

local AUTH_COOLDOWN = 0.5

net.Receive( "CNSX_Auth", function( _, ply )
    if not IsValid( ply ) then
        return
    end
    local now = CurTime()
    if ( ply.CNSXNextAuth or 0 ) > now then
        return
    end
    ply.CNSXNextAuth = now + AUTH_COOLDOWN
    if not CNSX.Allowed( ply ) then
        ply:ChatPrint( "[CNSX] superadmin only" )
        push( ply, "lock", { err = "superadmin only", deny = true } )
        return
    end
    local mode = net.ReadUInt( 2 )
    local pass = net.ReadString()
    if mode == 0 then
        sendStatus( ply )
        return
    end
    local ok, err = pcall( handleAuth, ply, pass )
    if not ok then
        push( ply, "lock", { err = tostring( err ), needSet = not CNSX.HasMaster() } )
    end
end )

net.Receive( "CNSX_Cmd", function( _, ply )
    if not IsValid( ply ) then
        return
    end
    local now = CurTime()
    if ( ply.CNSXNextCmd or 0 ) > now then
        return
    end
    ply.CNSXNextCmd = now + 0.05

    -- reject before decoding so non-admins can't make the server parse 64KB JSON
    if not CNSX.Allowed( ply ) then
        return
    end

    local data = CNSX.Decode( net.ReadString() )
    local act = data.act

    if act == "auth_begin" then
        sendStatus( ply )
        return
    end

    if act == "auth" then
        if ( ply.CNSXNextAuth or 0 ) > now then
            return
        end
        ply.CNSXNextAuth = now + AUTH_COOLDOWN
        handleAuth( ply, data.pass )
        return
    end

    if not CNSX.Authed( ply ) then
        push( ply, "lock", { needSet = not CNSX.HasMaster(), err = "unlock required" } )
        return
    end

    if act == "list" then
        local root = CNSX.RootName( data.root )
        push( ply, "list", { root = data.root or "data", path = data.path or "", rows = listDir( data.path or "", root ) } )
        return
    end

    if act == "read" then
        local root = CNSX.RootName( data.root )
        local body, err = readFile( data.path or "", root )
        push( ply, "file", { root = data.root, path = data.path, body = body or "", err = err } )
        return
    end

    if act == "write" then
        auditLine( ply, "write DATA/" .. CNSX.SanitizePath( data.path ) )
        local ok, err = writeData( data.path or "", data.body or "" )
        push( ply, "saved", { path = data.path, ok = ok, err = err } )
        return
    end

    if act == "tabs" then
        CNSX.SaveTabs( ply, data.tabs )
        return
    end

    if act == "loadtabs" then
        push( ply, "tabs", { tabs = CNSX.LoadTabs( ply ) } )
        return
    end

    if act == "run_sv" then
        auditLine( ply, "run_sv", tostring( data.code or "" ) )
        local ok, msg = runServer( ply, data.code )
        push( ply, "run", { realm = "server", ok = ok, msg = msg } )
        return
    end

    if act == "run_me" then
        net.Start( "CNSX_RunCl" )
            net.WriteString( string.sub( tostring( data.code or "" ), 1, CNSX.MaxCode ) )
        net.Send( ply )
        push( ply, "run", { realm = "client", ok = true, msg = "sent to you" } )
        return
    end

    if act == "run_cl" then
        auditLine( ply, "run_cl", tostring( data.code or "" ) )
        local sent = 0
        for _, p in ipairs( player.GetAll() ) do
            if canRunClient( p ) then
                net.Start( "CNSX_RunCl" )
                    net.WriteString( string.sub( tostring( data.code or "" ), 1, CNSX.MaxCode ) )
                net.Send( p )
                sent = sent + 1
            end
        end
        push( ply, "run", { realm = "clients", ok = true, msg = "sent to " .. sent .. " superadmins" } )
        return
    end

    if act == "run_ply" then
        local target = player.GetBySteamID64( tostring( data.sid or "" ) )
        if not IsValid( target ) then
            for _, p in ipairs( player.GetAll() ) do
                if p:Nick() == data.sid or p:SteamID() == data.sid then
                    target = p
                    break
                end
            end
        end
        if not IsValid( target ) then
            push( ply, "run", { realm = "player", ok = false, msg = "no player" } )
            return
        end
        -- the client only executes CNSX code if it is a superadmin; say so instead of reporting a fake success
        if not canRunClient( target ) then
            push( ply, "run", { realm = "player", ok = false, msg = target:Nick() .. " is not a superadmin" } )
            return
        end
        auditLine( ply, "run_ply -> " .. target:Nick() .. " <" .. sid( target ) .. ">", tostring( data.code or "" ) )
        net.Start( "CNSX_RunCl" )
            net.WriteString( string.sub( tostring( data.code or "" ), 1, CNSX.MaxCode ) )
        net.Send( target )
        push( ply, "run", { realm = "player", ok = true, msg = "sent to " .. target:Nick() } )
        return
    end

    if act == "run_both" then
        auditLine( ply, "run_both", tostring( data.code or "" ) )
        local ok, msg = runServer( ply, data.code )
        for _, p in ipairs( player.GetAll() ) do
            if canRunClient( p ) then
                net.Start( "CNSX_RunCl" )
                    net.WriteString( string.sub( tostring( data.code or "" ), 1, CNSX.MaxCode ) )
                net.Send( p )
            end
        end
        push( ply, "run", { realm = "both", ok = ok, msg = "sv " .. tostring( msg ) .. " + superadmins" } )
        return
    end

    if act == "include" then
        local root = CNSX.RootName( data.root )
        local body, err = readFile( data.path or "", root )
        if not body then
            push( ply, "run", { realm = "include", ok = false, msg = err or "missing" } )
            return
        end
        auditLine( ply, "include " .. CNSX.RootName( data.root ) .. "/" .. CNSX.SanitizePath( data.path ) )
        local ok, msg = runServer( ply, body )
        push( ply, "run", { realm = "include", ok = ok, msg = tostring( data.path ) .. "  " .. tostring( msg ) } )
        return
    end

    if act == "cmd" then
        local cmd = string.Trim( tostring( data.cmd or data.code or "" ) )
        if cmd == "" then
            push( ply, "run", { realm = "cmd", ok = false, msg = "empty" } )
            return
        end
        auditLine( ply, "cmd " .. cmd )
        game.ConsoleCommand( cmd .. "\n" )
        push( ply, "run", { realm = "cmd", ok = true, msg = cmd } )
        return
    end

    if act == "session" then
        local open = data.open == true
        ply:SetNWBool( "CNSX_Active", open )
        if not data.silent then
            if open then
                ply:EmitSound( "buttons/button14.wav", 72, 100, 0.75, CHAN_STATIC )
            else
                ply:EmitSound( "buttons/button10.wav", 68, 100, 0.7, CHAN_STATIC )
            end
        end
        return
    end

    if act == "check" then
        local fn, err = CompileString( tostring( data.code or "" ), "CNSX-check", false )
        if isfunction( fn ) then
            push( ply, "run", { realm = "check", ok = true, msg = "compile ok" } )
        else
            push( ply, "run", { realm = "check", ok = false, msg = tostring( fn or err ) } )
        end
        return
    end

    if act == "players" then
        local rows = {}
        for _, p in ipairs( player.GetAll() ) do
            rows[#rows + 1] = { nick = p:Nick(), sid = p:SteamID64(), admin = p:IsAdmin() }
        end
        push( ply, "players", { rows = rows } )
        return
    end

    if act == "remote_list" or act == "remote_read" or act == "remote_write" then
        local target = player.GetBySteamID64( tostring( data.sid or "" ) )
        if not IsValid( target ) then
            push( ply, "remote", { err = "player offline" } )
            return
        end
        -- remote file access is admin-to-admin only; ordinary players' files are off limits
        if not canRunClient( target ) then
            push( ply, "remote", { err = target:Nick() .. " is not a superadmin" } )
            return
        end
        auditLine( ply, act .. " -> " .. target:Nick() .. " <" .. sid( target ) .. "> DATA/" .. CNSX.SanitizePath( data.path ) )
        CNSX.PendingRemote[ply:SteamID64()] = { sid = target:SteamID64(), t = CurTime() }
        net.Start( "CNSX_Remote" )
            net.WriteString( CNSX.Encode( {
                act = act,
                path = data.path or "",
                root = "data",
                admin = ply:SteamID64(),
                body = data.body
            } ) )
        net.Send( target )
        return
    end
end )

local REMOTE_TIMEOUT = 20

net.Receive( "CNSX_RemoteOut", function( _, ply )
    if not IsValid( ply ) then
        return
    end
    -- find the request this player is answering before decoding anything they sent
    local plySid = ply:SteamID64()
    local adminSid
    for aSid, pend in pairs( CNSX.PendingRemote ) do
        if pend.sid == plySid and CurTime() - pend.t <= REMOTE_TIMEOUT then
            adminSid = aSid
            break
        end
    end
    if not adminSid then
        return
    end
    CNSX.PendingRemote[adminSid] = nil
    local admin = player.GetBySteamID64( adminSid )
    if not IsValid( admin ) or not CNSX.Allowed( admin ) or not CNSX.Authed( admin ) then
        return
    end
    local data = CNSX.Decode( net.ReadString() )
    data.from = ply:Nick()
    data.sid = ply:SteamID64()
    push( admin, "remote", data )
end )

concommand.Add( "consolex", function( ply )
    if not IsValid( ply ) then
        return
    end
    if not CNSX.Allowed( ply ) then
        ply:ChatPrint( "[CNSX] superadmin only" )
        return
    end
    file.CreateDir( "consolex" )
    file.CreateDir( userDir( ply ) )
    if CNSX.Authed( ply ) then
        net.Start( "CNSX_Open" )
            net.WriteString( CNSX.Encode( { tabs = CNSX.LoadTabs( ply ) } ) )
        net.Send( ply )
        return
    end
    push( ply, "lock", { needSet = not CNSX.HasMaster() } )
end )

hook.Add( "PlayerDisconnected", "CNSX_BusyClear", function( ply )
    if not IsValid( ply ) then
        return
    end
    ply:SetNWBool( "CNSX_Active", false )
    CNSX.Auth[plyKey( ply )] = nil
    CNSX.PendingRemote[ply:SteamID64() or ""] = nil
end )

concommand.Add( "cnsx_setpass", function( ply, _, args )
    if IsValid( ply ) and not CNSX.Allowed( ply ) then
        return
    end
    if IsValid( ply ) and not CNSX.Authed( ply ) then
        ply:ChatPrint( "[CNSX] unlock first (or run cnsx_setpass from the server console)" )
        return
    end
    local pass = table.concat( args or {}, " " )
    if #pass < 4 then
        if IsValid( ply ) then
            ply:ChatPrint( "[CNSX] usage: cnsx_setpass <password>" )
        else
            print( "[CNSX] usage: cnsx_setpass <password>" )
        end
        return
    end
    storePass( pass )
    CNSX.Auth = {}
    if IsValid( ply ) then
        CNSX.GrantAuth( ply )
    end
    auditLine( ply, "changed master password" )
    local msg = "[CNSX] master password updated; other sessions must unlock again"
    if IsValid( ply ) then
        ply:ChatPrint( msg )
    else
        print( msg )
    end
end )

concommand.Add( "cnsx_clearpass", function( ply )
    if IsValid( ply ) and not CNSX.Allowed( ply ) then
        return
    end
    if IsValid( ply ) and not CNSX.Authed( ply ) then
        ply:ChatPrint( "[CNSX] unlock first" )
        return
    end
    authSave( {} )
    CNSX.Auth = {}
    auditLine( ply, "cleared master password" )
    local msg = "[CNSX] master password cleared — next open must set one"
    if IsValid( ply ) then
        ply:ChatPrint( msg )
    else
        print( msg )
    end
end )

concommand.Add( "cnsx", function( ply )
    if not IsValid( ply ) then
        return
    end
    ply:ConCommand( "consolex" )
end )

hook.Add( "PlayerSay", "CNSX_ChatOpen", function( ply, text )
    text = string.Trim( string.lower( tostring( text or "" ) ) )
    if text ~= "!cnsx" and text ~= "/cnsx" then
        return
    end
    if not CNSX.Allowed( ply ) then
        ply:ChatPrint( "[CNSX] superadmin only" )
        return ""
    end
    ply:ConCommand( "consolex" )
    return ""
end )
