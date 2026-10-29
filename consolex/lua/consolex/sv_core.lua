if not SERVER then return end

resource.AddFile( "materials/consolex/cnsx_banner.png" )
resource.AddFile( "materials/consolex/cnsx_icon.png" )
resource.AddFile( "materials/consolex/cnsx_logo.jpg" )

CNSX.Sessions = CNSX.Sessions or {}
CNSX.Auth = CNSX.Auth or {}
CNSX.Fails = CNSX.Fails or {}
CNSX.PendingRemote = CNSX.PendingRemote or {}
CNSX.PendingCl = CNSX.PendingCl or {}
CNSX.GrepJobs = CNSX.GrepJobs or {}

local AUTH_FILE = "consolex/auth.json"
local MIN_NEW_PASS = 8
local SESSION_MAX = 12 * 3600

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

local function idleSeconds()
    local mins = 45
    local cv = GetConVar( "cnsx_session_min" )
    if cv then
        mins = math.Clamp( cv:GetInt(), 5, 240 )
    end

    return mins * 60
end

function CNSX.Authed( ply )
    if not IsValid( ply ) then
        return false
    end
    local row = CNSX.Auth[plyKey( ply )]
    if not row then
        return false
    end
    local now = CurTime()
    if now > ( row.expires or 0 ) or now > ( row.hardExpires or 0 ) then
        CNSX.Auth[plyKey( ply )] = nil
        return false
    end

    return true
end

-- idle timeout: every authenticated command pushes the expiry out again, up to a hard cap
local function touchAuth( ply )
    local row = CNSX.Auth[plyKey( ply )]
    if row then
        row.expires = math.min( CurTime() + idleSeconds(), row.hardExpires or 0 )
    end
end

function CNSX.GrantAuth( ply )
    local now = CurTime()
    CNSX.Auth[plyKey( ply )] = { expires = now + idleSeconds(), hardExpires = now + SESSION_MAX }
end

-- idle window plus time left before the hard cap; the client counts down from its last command
local function sessionInfo( ply )
    local row = CNSX.Auth[plyKey( ply )]
    if not row then
        return { idle = 0, hard = 0 }
    end

    return { idle = idleSeconds(), hard = math.max( 0, math.floor( row.hardExpires - CurTime() ) ) }
end

local function sid( ply )
    return ply:SteamID64() or "0"
end

local function failAuth( ply )
    local id = plyKey( ply )
    local row = CNSX.Fails[id] or { n = 0, lock = 0 }
    row.n = row.n + 1
    if row.n >= 5 then
        row.lock = CurTime() + 30
        row.n = 0
    end
    CNSX.Fails[id] = row

    return row.lock > CurTime(), math.max( 0, math.ceil( row.lock - CurTime() ) )
end

local function userDir( ply )
    return "consolex/users/" .. sid( ply )
end

local function push( ply, kind, payload )
    payload = payload or {}
    payload.kind = kind
    net.Start( "CNSX_Out" )
        CNSX.NetWrite( payload )
    net.Send( ply )
end
CNSX.Push = push

local function auditLine( ply, act, detail )
    local who = IsValid( ply ) and ( ply:Nick() .. " <" .. sid( ply ) .. ">" ) or "Console"
    local line = os.date( "%Y-%m-%d %H:%M:%S" ) .. "  " .. who .. "  " .. act
    ServerLog( "[CNSX] " .. line .. "\n" )
    file.CreateDir( "consolex/audit" )
    file.Append( "consolex/audit/" .. os.date( "%Y-%m-%d" ) .. ".txt", line .. ( detail and ( "\n" .. detail ) or "" ) .. "\n\n" )
end
CNSX.Audit = auditLine

-- same rule as CNSX.Allowed, which the client also applies before running pushed code
local function canRunClient( ply )
    return CNSX.Allowed( ply )
end

-- ct is the client's own clock at save time, so the client compares it with its local drafts without clock skew
-- ct is the client's own clock when its drafts were last saved, so the client can compare it with
-- its local drafts without clock skew; partial means large tabs were left out of this backup
function CNSX.SaveTabs( ply, tabs, ct, partial )
    file.CreateDir( "consolex" )
    file.CreateDir( userDir( ply ) )
    file.Write( userDir( ply ) .. "/tabs.json", CNSX.Encode( { tabs = istable( tabs ) and tabs or {}, t = os.time(), ct = tonumber( ct ), partial = partial == true } ) )
end

function CNSX.LoadTabs( ply )
    local raw = file.Read( userDir( ply ) .. "/tabs.json", "DATA" )
    local data = CNSX.Decode( raw )

    return istable( data.tabs ) and data.tabs or {}, tonumber( data.ct ) or 0, data.partial == true
end

local function openIDE( ply )
    local tabs, t, partial = CNSX.LoadTabs( ply )
    local info = sessionInfo( ply )
    -- saved tabs that no longer fit in one message must not stop the IDE from opening
    local packed = CNSX.Pack( { tabs = tabs, t = t, partial = partial, session = info } )
        or CNSX.Pack( { tabs = {}, session = info, err = "saved server tabs were too large to send" } )
    net.Start( "CNSX_Open" )
        CNSX.NetWritePacked( packed )
    net.Send( ply )
    push( ply, "lock", { unlocked = true, session = info } )
end

local function chunkName( ply )
    local nick = string.gsub( IsValid( ply ) and ply:Nick() or "console", "[^%a_]", "" )

    return "CNSX:" .. ( nick ~= "" and nick or "admin" )
end

local function runServer( ply, code )
    CNSX._runner = ply
    local ok, msg, out = CNSX.RunCaptured( code, chunkName( ply ) )
    CNSX._runner = nil

    return ok, msg, out
end

local function sendStatus( ply )
    push( ply, "lock", { needSet = not CNSX.HasMaster(), unlocked = CNSX.Authed( ply ), minLen = MIN_NEW_PASS } )
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
        push( ply, "lock", { err = "locked " .. math.ceil( fails.lock - CurTime() ) .. "s", needSet = not CNSX.HasMaster(), minLen = MIN_NEW_PASS } )
        return
    end
    pass = tostring( pass or "" )
    if not CNSX.HasMaster() then
        if #pass < MIN_NEW_PASS then
            push( ply, "lock", { err = "password must be " .. MIN_NEW_PASS .. "+ characters", needSet = true, minLen = MIN_NEW_PASS } )
            return
        end
        storePass( pass )
        if not file.Exists( AUTH_FILE, "DATA" ) then
            push( ply, "lock", { err = "could not write DATA/" .. AUTH_FILE, needSet = true, minLen = MIN_NEW_PASS } )
            return
        end
        auditLine( ply, "set master password (first launch)" )
        CNSX.GrantAuth( ply )
        ply:ChatPrint( "[CNSX] master password set" )
        openIDE( ply )
        return
    end
    if pass == "" then
        push( ply, "lock", { err = "enter the password", needSet = false } )
        return
    end
    if not checkPass( authLoad(), pass ) then
        local locked, wait = failAuth( ply )
        auditLine( ply, locked and ( "unlock FAILED, locked out for " .. wait .. "s" ) or "unlock FAILED" )
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
        push( ply, "lock", { err = tostring( err ), needSet = not CNSX.HasMaster(), minLen = MIN_NEW_PASS } )
    end
end )

-- token bucket: bursts (open window -> session + players + list) go through, floods don't
local CMD_BURST = 40
local CMD_RATE = 20

local function takeToken( ply )
    local now = SysTime()
    local bucket = ply.CNSXBucket
    if not bucket then
        bucket = { n = CMD_BURST, t = now }
        ply.CNSXBucket = bucket
    end
    bucket.n = math.min( CMD_BURST, bucket.n + ( now - bucket.t ) * CMD_RATE )
    bucket.t = now
    if bucket.n < 1 then
        return false
    end
    bucket.n = bucket.n - 1

    return true
end

local function findTarget( key )
    key = tostring( key or "" )
    local target = player.GetBySteamID64( key )
    if IsValid( target ) then
        return target
    end
    for _, p in ipairs( player.GetAll() ) do
        if p:Nick() == key or p:SteamID() == key then
            return p
        end
    end
end

-- client runs report back through CNSX_ClOut; only players we actually sent code to may answer
local CL_TIMEOUT = 30
local clSeq = 0

local function prunePendingCl()
    local now = CurTime()
    for id, pend in pairs( CNSX.PendingCl ) do
        if now - pend.t > CL_TIMEOUT then
            CNSX.PendingCl[id] = nil
        end
    end
end

local function sendClient( admin, targets, code )
    prunePendingCl()
    clSeq = clSeq + 1
    local id = clSeq
    local packed, err = CNSX.Pack( { code = tostring( code or "" ), id = id, from = admin:Nick(), admin = sid( admin ) } )
    if not packed then
        return 0, err
    end
    local pend = { admin = sid( admin ), targets = {}, t = CurTime() }
    for _, p in ipairs( targets ) do
        -- the sender logs its own run locally; everyone else reports back
        if p ~= admin then
            pend.targets[sid( p )] = true
        end
        net.Start( "CNSX_RunCl" )
            CNSX.NetWritePacked( packed )
        net.Send( p )
    end
    if next( pend.targets ) then
        CNSX.PendingCl[id] = pend
    end

    return #targets
end

local function superadmins()
    local list = {}
    for _, p in ipairs( player.GetHumans() ) do
        if canRunClient( p ) then
            list[#list + 1] = p
        end
    end

    return list
end

local function fileop( ply, ok, msg, extra )
    extra = extra or {}
    extra.ok = ok
    extra.msg = msg
    push( ply, "fileop", extra )
end

local function startGrep( ply, data )
    local job, err = CNSX.GrepNew( data, CNSX.RootName( data.root ) )
    if not job then
        push( ply, "grep", { err = err } )
        return
    end
    job.ply = ply
    job.rootKey = data.root or "data"
    CNSX.GrepJobs[sid( ply )] = job
end

hook.Add( "Think", "CNSX_Grep", function()
    if not next( CNSX.GrepJobs ) then
        return
    end
    for key, job in pairs( CNSX.GrepJobs ) do
        if not IsValid( job.ply ) then
            CNSX.GrepJobs[key] = nil
        else
            local result = CNSX.GrepStep( job )
            if result then
                CNSX.GrepJobs[key] = nil
                result.root = job.rootKey
                push( job.ply, "grep", result )
            end
        end
    end
end )

local apiCache

local ACTS = {}

ACTS.list = function( ply, data )
    local rows, truncated = CNSX.ListDir( data.path or "", CNSX.RootName( data.root ) )
    push( ply, "list", { root = data.root or "data", path = CNSX.SanitizePath( data.path ), rows = rows, truncated = truncated, seq = tonumber( data.seq ) } )
end

ACTS.read = function( ply, data )
    local body, err, readOnly = CNSX.ReadText( data.path or "", CNSX.RootName( data.root ) )
    push( ply, "file", { root = data.root or "data", path = CNSX.SanitizePath( data.path ), body = body, err = err, readOnly = readOnly, line = data.line } )
end

ACTS.write = function( ply, data )
    if data.create and file.Exists( CNSX.WritablePath( data.path ), "DATA" ) then
        push( ply, "saved", { path = CNSX.WritablePath( data.path ), ok = false, err = "already exists", tabId = data.tabId } )
        return
    end
    local ok, path, err = CNSX.WriteData( data.path or "", data.body or "" )
    auditLine( ply, "write DATA/" .. path .. ( ok and "" or ( " FAILED: " .. tostring( err ) ) ) .. ( data.auto and " (autosave)" or "" ) )
    push( ply, "saved", { path = path, ok = ok, err = err, tabId = data.tabId, auto = data.auto } )
end

ACTS.delete = function( ply, data )
    local path = CNSX.SanitizePath( data.path )
    local ok, err = CNSX.DeleteData( path )
    auditLine( ply, "delete DATA/" .. path .. ( ok and "" or ( " FAILED: " .. tostring( err ) ) ) )
    fileop( ply, ok, ok and ( "deleted DATA/" .. path ) or ( "delete failed: " .. tostring( err ) ) )
end

ACTS.rename = function( ply, data )
    local from = CNSX.SanitizePath( data.path )
    local ok, to, err = CNSX.RenameData( from, data.to )
    auditLine( ply, "rename DATA/" .. from .. " -> " .. tostring( to ) .. ( ok and "" or ( " FAILED: " .. tostring( err ) ) ) )
    fileop( ply, ok, ok and ( "renamed to DATA/" .. to ) or ( "rename failed: " .. tostring( err ) ), { from = from, to = to } )
end

ACTS.mkdir = function( ply, data )
    local ok, path, err = CNSX.MkdirData( data.path )
    auditLine( ply, "mkdir DATA/" .. tostring( path ) .. ( ok and "" or ( " FAILED: " .. tostring( err ) ) ) )
    fileop( ply, ok, ok and ( "created DATA/" .. path ) or ( "mkdir failed: " .. tostring( err ) ) )
end

ACTS.grep = function( ply, data )
    startGrep( ply, data )
end

ACTS.loadtabs = function( ply )
    local tabs, t = CNSX.LoadTabs( ply )
    push( ply, "tabs", { tabs = tabs, t = t } )
end

ACTS.run_sv = function( ply, data )
    auditLine( ply, "run_sv", tostring( data.code or "" ) )
    local ok, msg, out = runServer( ply, data.code )
    push( ply, "run", { realm = "server", ok = ok, msg = msg, out = out } )
end

ACTS.run_me = function( ply, data )
    local sent, err = sendClient( ply, { ply }, data.code )
    if sent == 0 then
        push( ply, "run", { realm = "client", ok = false, msg = tostring( err ) } )
    end
end

ACTS.run_cl = function( ply, data )
    auditLine( ply, "run_cl", tostring( data.code or "" ) )
    local sent, err = sendClient( ply, superadmins(), data.code )
    if err then
        push( ply, "run", { realm = "clients", ok = false, msg = tostring( err ) } )
        return
    end
    push( ply, "run", { realm = "clients", ok = true, msg = "sent to " .. sent .. " superadmins; replies follow" } )
end

ACTS.run_ply = function( ply, data )
    local target = findTarget( data.sid )
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
    local sent, err = sendClient( ply, { target }, data.code )
    if sent == 0 then
        push( ply, "run", { realm = "player", ok = false, msg = tostring( err ) } )
        return
    end
    if target ~= ply then
        push( ply, "run", { realm = "player", ok = true, msg = "sent to " .. target:Nick() .. "; reply follows" } )
    end
end

ACTS.run_both = function( ply, data )
    auditLine( ply, "run_both", tostring( data.code or "" ) )
    local ok, msg, out = runServer( ply, data.code )
    push( ply, "run", { realm = "server", ok = ok, msg = msg, out = out } )
    local sent, err = sendClient( ply, superadmins(), data.code )
    push( ply, "run", { realm = "clients", ok = err == nil, msg = err or ( "sent to " .. sent .. " superadmins; replies follow" ) } )
end

ACTS.include = function( ply, data )
    local root = CNSX.RootName( data.root )
    local path = CNSX.SanitizePath( data.path )
    local body, err = CNSX.ReadText( path, root )
    if not body or err then
        push( ply, "run", { realm = "include", ok = false, msg = path .. "  " .. tostring( err or "missing" ) } )
        return
    end
    auditLine( ply, "include " .. root .. "/" .. path )
    local ok, msg, out = runServer( ply, body )
    push( ply, "run", { realm = "include", ok = ok, msg = path .. "  " .. tostring( msg ), out = out } )
end

ACTS.cmd = function( ply, data )
    local cmd = string.Trim( tostring( data.cmd or "" ) )
    cmd = string.gsub( cmd, "[\r\n]", " " )
    if cmd == "" then
        push( ply, "run", { realm = "cmd", ok = false, msg = "empty" } )
        return
    end
    auditLine( ply, "cmd " .. cmd )
    game.ConsoleCommand( cmd .. "\n" )
    push( ply, "run", { realm = "cmd", ok = true, msg = cmd .. "  (output goes to the server console)" } )
end

ACTS.check = function( ply, data )
    local fn = CompileString( tostring( data.code or "" ), chunkName( ply ), false )
    if isfunction( fn ) then
        push( ply, "run", { realm = "check", ok = true, msg = "compile ok" } )
    else
        push( ply, "run", { realm = "check", ok = false, msg = tostring( fn ) } )
    end
end

ACTS.players = function( ply )
    local rows = {}
    for _, p in ipairs( player.GetHumans() ) do
        rows[#rows + 1] = { nick = p:Nick(), sid = p:SteamID64(), admin = p:IsAdmin(), sa = canRunClient( p ) }
    end
    push( ply, "players", { rows = rows } )
end

ACTS.api = function( ply )
    apiCache = apiCache or CNSX.CollectAPI()
    push( ply, "api", apiCache )
end

ACTS.logout = function( ply )
    CNSX.Auth[plyKey( ply )] = nil
    auditLine( ply, "locked session" )
    push( ply, "lock", { locked = true } )
end

local REMOTE_TIMEOUT = 20
local remoteSeq = 0

local function pruneRemote()
    local now = CurTime()
    for id, pend in pairs( CNSX.PendingRemote ) do
        if now - pend.t > REMOTE_TIMEOUT then
            CNSX.PendingRemote[id] = nil
        end
    end
end

local function remoteAct( ply, data, act )
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
    local path = CNSX.SanitizePath( data.path )
    auditLine( ply, act .. " -> " .. target:Nick() .. " <" .. sid( target ) .. "> DATA/" .. path )
    pruneRemote()
    remoteSeq = remoteSeq + 1
    local rid = remoteSeq
    local packed, err = CNSX.Pack( {
        act = act,
        rid = rid,
        path = path,
        adminNick = ply:Nick(),
        body = act == "remote_write" and tostring( data.body or "" ) or nil
    } )
    if not packed then
        push( ply, "remote", { err = tostring( err ) } )
        return
    end
    -- everything the reply is about is remembered here; the target only supplies the result
    CNSX.PendingRemote[rid] = {
        admin = sid( ply ),
        target = sid( target ),
        act = act,
        path = path,
        tabId = data.tabId,
        seq = tonumber( data.seq ),
        t = CurTime()
    }
    net.Start( "CNSX_Remote" )
        CNSX.NetWritePacked( packed )
    net.Send( target )
end

ACTS.remote_list = function( ply, data ) remoteAct( ply, data, "remote_list" ) end
ACTS.remote_read = function( ply, data ) remoteAct( ply, data, "remote_read" ) end
ACTS.remote_write = function( ply, data ) remoteAct( ply, data, "remote_write" ) end

net.Receive( "CNSX_Cmd", function( _, ply )
    if not IsValid( ply ) then
        return
    end
    -- reject before decompressing/decoding so non-admins can't make the server do work
    if not CNSX.Allowed( ply ) then
        return
    end
    if not takeToken( ply ) then
        return
    end

    local data = CNSX.NetRead()
    local act = data.act

    if act == "auth_begin" then
        sendStatus( ply )
        return
    end

    if act == "auth" then
        local now = CurTime()
        if ( ply.CNSXNextAuth or 0 ) > now then
            return
        end
        ply.CNSXNextAuth = now + AUTH_COOLDOWN
        handleAuth( ply, data.pass )
        return
    end

    -- window open/close only drives the overhead banner
    if act == "session" then
        local open = data.open == true and CNSX.Authed( ply )
        ply:SetNWBool( "CNSX_Active", open )
        if not data.silent then
            ply:EmitSound( open and "buttons/button14.wav" or "buttons/button10.wav", open and 72 or 68, 100, open and 0.75 or 0.7, CHAN_STATIC )
        end
        return
    end

    if not CNSX.Authed( ply ) then
        if act ~= "tabs" then
            push( ply, "lock", { needSet = not CNSX.HasMaster(), err = "session expired, unlock again", minLen = MIN_NEW_PASS } )
        end
        return
    end

    if act == "tabs" then
        CNSX.SaveTabs( ply, data.tabs, data.ct, data.partial )
        return
    end

    local fn = ACTS[act]
    if not fn then
        return
    end
    touchAuth( ply )
    local ok, err = pcall( fn, ply, data )
    if not ok then
        ErrorNoHalt( "[CNSX] " .. tostring( act ) .. " failed: " .. tostring( err ) .. "\n" )
        push( ply, "run", { realm = tostring( act ), ok = false, msg = "internal error: " .. tostring( err ) } )
    end
end )

-- rebuild the reply from what the request allows, so a target can't steer the admin's tabs or tree
local REMOTE_ROWS = 1000

local function cleanRows( rows )
    local out = {}
    if not istable( rows ) then
        return out
    end
    for _, row in ipairs( rows ) do
        if #out >= REMOTE_ROWS then
            break
        end
        if istable( row ) and isstring( row.name ) and isstring( row.path ) then
            out[#out + 1] = { name = row.name, path = CNSX.SanitizePath( row.path ), dir = row.dir == true, size = tonumber( row.size ) }
        end
    end

    return out
end

net.Receive( "CNSX_RemoteOut", function( _, ply )
    if not IsValid( ply ) then
        return
    end
    -- find the request this player is answering before decoding anything they sent
    local rid = net.ReadUInt( 32 )
    local pend = CNSX.PendingRemote[rid]
    if not pend or pend.target ~= sid( ply ) or CurTime() - pend.t > REMOTE_TIMEOUT then
        return
    end
    CNSX.PendingRemote[rid] = nil
    local admin = player.GetBySteamID64( pend.admin )
    if not IsValid( admin ) or not CNSX.Allowed( admin ) or not CNSX.Authed( admin ) then
        return
    end
    local data = CNSX.NetRead()
    local out = { from = ply:Nick(), sid = sid( ply ), path = pend.path }
    if pend.act == "remote_list" then
        out.rows = cleanRows( data.rows )
        out.truncated = data.truncated == true
        out.seq = pend.seq
    elseif pend.act == "remote_read" then
        if isstring( data.body ) and #data.body <= CNSX.MaxCode then
            out.body = data.body
            out.readOnly = data.readOnly == true
        else
            out.err = isstring( data.err ) and string.sub( data.err, 1, 200 ) or "unreadable"
        end
    else
        out.ok = data.ok == true
        out.path = CNSX.WritablePath( pend.path )
        out.tabId = pend.tabId
        out.write = true
    end
    if isstring( data.err ) and not out.err then
        out.err = string.sub( data.err, 1, 200 )
    end
    push( admin, "remote", out )
end )

net.Receive( "CNSX_ClOut", function( _, ply )
    if not IsValid( ply ) then
        return
    end
    local id = net.ReadUInt( 32 )
    local pend = CNSX.PendingCl[id]
    local plySid = sid( ply )
    if not pend or not pend.targets[plySid] or CurTime() - pend.t > CL_TIMEOUT then
        return
    end
    pend.targets[plySid] = nil
    if not next( pend.targets ) then
        CNSX.PendingCl[id] = nil
    end
    local admin = player.GetBySteamID64( pend.admin )
    if not IsValid( admin ) or not CNSX.Authed( admin ) then
        return
    end
    local data = CNSX.NetRead()
    push( admin, "run", {
        realm = "client " .. ply:Nick(),
        ok = data.ok == true,
        msg = tostring( data.msg or "" ),
        out = isstring( data.out ) and data.out or nil
    } )
end )

-- live error feed: server Lua errors (e.g. from hooks your code added) show up in open IDEs
local errQueue = {}
local ERR_PER_FLUSH = 8

hook.Add( "OnLuaError", "CNSX_ErrorFeed", function( err )
    if #errQueue >= ERR_PER_FLUSH * 4 then
        return
    end
    local cv = GetConVar( "cnsx_error_feed" )
    if cv and not cv:GetBool() then
        return
    end
    errQueue[#errQueue + 1] = string.sub( tostring( err ), 1, 600 )
end )

timer.Create( "CNSX_ErrorFeed", 1, 0, function()
    if #errQueue == 0 then
        return
    end
    local batch, seen = {}, {}
    for _, e in ipairs( errQueue ) do
        if not seen[e] and #batch < ERR_PER_FLUSH then
            seen[e] = true
            batch[#batch + 1] = e
        end
    end
    local dropped = #errQueue - #batch
    errQueue = {}
    for _, p in ipairs( player.GetHumans() ) do
        if p:GetNWBool( "CNSX_Active", false ) and CNSX.Authed( p ) then
            push( p, "errors", { list = batch, dropped = dropped } )
        end
    end
end )

concommand.Add( "consolex", function( ply )
    if not IsValid( ply ) then
        return
    end
    if not CNSX.Allowed( ply ) then
        ply:ChatPrint( "[CNSX] superadmin only" )
        return
    end
    sendStatus( ply )
end )

hook.Add( "PlayerDisconnected", "CNSX_BusyClear", function( ply )
    if not IsValid( ply ) then
        return
    end
    ply:SetNWBool( "CNSX_Active", false )
    CNSX.Auth[plyKey( ply )] = nil
    CNSX.GrepJobs[sid( ply )] = nil
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
    if #pass < MIN_NEW_PASS then
        local usage = "[CNSX] usage: cnsx_setpass <password>  (" .. MIN_NEW_PASS .. "+ characters)"
        if IsValid( ply ) then
            ply:ChatPrint( usage )
        else
            print( usage )
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

-- server console only: end every unlocked session right now
concommand.Add( "cnsx_lockall", function( ply )
    if IsValid( ply ) then
        return
    end
    CNSX.Auth = {}
    auditLine( nil, "locked all sessions" )
    print( "[CNSX] all sessions locked" )
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
