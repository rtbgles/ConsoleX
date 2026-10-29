if not CLIENT then return end

surface.CreateFont( "CNSX_Overhead", {
    font = "Tahoma",
    size = 32,
    weight = 800,
    antialias = true
} )
surface.CreateFont( "CNSX_OverheadSub", {
    font = "Tahoma",
    size = 16,
    weight = 500,
    antialias = true
} )

local bannerMat

local function logoMat()
    if not bannerMat then
        bannerMat = Material( "consolex/cnsx_banner.png", "smooth noclamp vertexalpha" )
    end

    return bannerMat
end

local BOX_COL = Color( 10, 16, 32, 230 )
local LOGO_COL = Color( 90, 160, 255 )
local TITLE_COL = Color( 200, 220, 255 )
local NAME_COL = Color( 140, 170, 220 )
local HEAD_OFFSET = Vector( 0, 0, 16 )
local MAX_DIST_SQR = 3000 * 3000

hook.Add( "PostDrawTranslucentRenderables", "CNSX_Overhead", function( depth, skybox, skybox3d )
    -- this hook also runs for the depth and skybox passes; drawing there would double up or leak into the sky
    if depth or skybox or skybox3d then
        return
    end
    local prefs = CNSX.Prefs
    if prefs and prefs.banner == false then
        return
    end
    local eye = EyePos()
    local ang = Angle( 0, EyeAngles().y - 90, 90 )
    for _, ply in ipairs( player.GetAll() ) do
        if IsValid( ply ) and ply:Alive() and not ply:IsDormant() and ply:GetNWBool( "CNSX_Active", false ) then
            local pos = ply:EyePos() + HEAD_OFFSET
            if pos:DistToSqr( eye ) <= MAX_DIST_SQR then
                cam.Start3D2D( pos, ang, 0.065 )
                    draw.RoundedBox( 8, -118, -22, 236, 44, BOX_COL )
                    surface.SetDrawColor( 56, 110, 220, 220 )
                    surface.DrawRect( -118, -22, 236, 3 )
                    surface.DrawRect( -118, 19, 236, 3 )
                    local logo = logoMat()
                    if logo and not logo:IsError() then
                        surface.SetMaterial( logo )
                        surface.SetDrawColor( 255, 255, 255, 255 )
                        surface.DrawTexturedRect( -110, -16, 96, 32 )
                    else
                        draw.SimpleText( "CNSX", "CNSX_Overhead", -62, 0, LOGO_COL, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
                    end
                    draw.SimpleText( "IN SESSION", "CNSX_OverheadSub", 52, -4, TITLE_COL, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
                    draw.SimpleText( ply:Nick(), "CNSX_OverheadSub", 52, 12, NAME_COL, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
                cam.End3D2D()
            end
        end
    end
end )
