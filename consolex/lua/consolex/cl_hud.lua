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
    if bannerMat and not bannerMat:IsError() then
        return bannerMat
    end
    bannerMat = Material( "consolex/cnsx_banner.png", "smooth noclamp vertexalpha" )
    return bannerMat
end

hook.Add( "PostDrawTranslucentRenderables", "CNSX_Overhead", function()
    local prefs = CNSX.Prefs
    if prefs and prefs.banner == false then
        return
    end
    local ang = Angle( 0, EyeAngles().y - 90, 90 )
    for _, ply in ipairs( player.GetAll() ) do
        if not IsValid( ply ) then
        elseif not ply:Alive() then
        elseif not ply:GetNWBool( "CNSX_Active", false ) then
        else
            local pos = ply:EyePos() + Vector( 0, 0, 16 )
            if pos:DistToSqr( EyePos() ) <= 9000000 then
                cam.Start3D2D( pos, ang, 0.065 )
                    draw.RoundedBox( 8, -118, -22, 236, 44, Color( 10, 16, 32, 230 ) )
                    surface.SetDrawColor( 56, 110, 220, 220 )
                    surface.DrawRect( -118, -22, 236, 3 )
                    surface.DrawRect( -118, 19, 236, 3 )
                    local logo = logoMat()
                    if logo and not logo:IsError() then
                        surface.SetMaterial( logo )
                        surface.SetDrawColor( 255, 255, 255, 255 )
                        surface.DrawTexturedRect( -110, -16, 96, 32 )
                    else
                        draw.SimpleText( "CNSX", "CNSX_Overhead", -62, 0, Color( 90, 160, 255 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
                    end
                    draw.SimpleText( "IN SESSION", "CNSX_OverheadSub", 52, -4, Color( 200, 220, 255 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
                    draw.SimpleText( ply:Nick(), "CNSX_OverheadSub", 52, 12, Color( 140, 170, 220 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
                cam.End3D2D()
            end
        end
    end
end )
