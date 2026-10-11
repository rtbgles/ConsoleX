if SERVER then
    AddCSLuaFile()
    AddCSLuaFile( "consolex/sh_core.lua" )
    AddCSLuaFile( "consolex/cl_theme.lua" )
    AddCSLuaFile( "consolex/cl_elements.lua" )
    AddCSLuaFile( "consolex/cl_editor.lua" )
    AddCSLuaFile( "consolex/cl_ui.lua" )
    AddCSLuaFile( "consolex/cl_hud.lua" )
end

include( "consolex/sh_core.lua" )

if SERVER then
    include( "consolex/sv_core.lua" )
end

if CLIENT then
    include( "consolex/cl_theme.lua" )
    include( "consolex/cl_elements.lua" )
    include( "consolex/cl_editor.lua" )
    include( "consolex/cl_ui.lua" )
    include( "consolex/cl_hud.lua" )
end
