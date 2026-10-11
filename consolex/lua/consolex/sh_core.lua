CNSX = CNSX or {}
CNSX.Version = "1.5.1"
CNSX.MaxNet = 62000
CNSX.MaxCode = 62000

CNSX.Roots = {
    data = "DATA",
    game = "GAME",
    lua = "LUA"
}

CreateConVar( "cnsx_session_min", "45", { FCVAR_ARCHIVE, FCVAR_PROTECTED }, "Minutes a CNSX unlock lasts" )

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
    util.AddNetworkString( "CNSX_Remote" )
    util.AddNetworkString( "CNSX_RemoteOut" )
    util.AddNetworkString( "CNSX_Busy" )
end

function CNSX.SanitizePath( path )
    path = string.gsub( tostring( path or "" ), "\\", "/" )
    path = string.gsub( path, "%.%.", "" )
    path = string.gsub( path, "^/+", "" )
    return path
end

function CNSX.RootName( key )
    key = string.lower( tostring( key or "data" ) )
    return CNSX.Roots[key] or "DATA"
end

function CNSX.Encode( tbl )
    local raw = util.TableToJSON( tbl or {} ) or "{}"
    if #raw > CNSX.MaxNet then
        return util.TableToJSON( { err = "payload too large" } ) or "{}"
    end
    return raw
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

if SERVER then
    -- network strings registered at top
end
