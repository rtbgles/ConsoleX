-- Writes the editor page CNSX.EditorHTML builds, for tests/editor_page.js. luajit tests/dump_editor_html.lua out.html
local ROOT = "consolex/lua/consolex"
local env = setmetatable( { CLIENT = true, SERVER = false }, { __index = _G } )
env._G = env
local function enc( v )
    if type( v ) == "table" then
        local parts = {}
        for k, x in pairs( v ) do parts[#parts + 1] = string.format( "%q", k ) .. ":" .. enc( x ) end
        return "{" .. table.concat( parts, "," ) .. "}"
    end
    if type( v ) == "string" then return string.format( "%q", v ) end
    return tostring( v )
end
env.util = { TableToJSON = enc, AddNetworkString = function() end }
env.math = setmetatable( { Clamp = function( v, a, b ) return math.min( math.max( v, a ), b ) end }, { __index = math } )
env.CreateConVar = function() end
for _, f in ipairs( { "sh_core.lua", "cl_editor.lua" } ) do
    local fn = assert( loadfile( ROOT .. "/" .. f ) )
    setfenv( fn, env )
    fn()
end
local out = assert( io.open( arg[1], "w" ) )
out:write( env.CNSX.EditorHTML( { fontSize = 14, theme = "monokai", wrap = true } ) )
out:close()
