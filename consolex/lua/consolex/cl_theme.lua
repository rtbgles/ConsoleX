if not CLIENT then return end

CNSX.Theme = {
    bg = Color( 10, 10, 12 ),
    panel = Color( 18, 18, 22 ),
    bar = Color( 22, 8, 10 ),
    accent = Color( 196, 28, 36 ),
    accent2 = Color( 120, 16, 22 ),
    text = Color( 236, 236, 238 ),
    muted = Color( 140, 140, 148 ),
    line = Color( 48, 16, 18 ),
    ok = Color( 80, 200, 110 ),
    err = Color( 255, 70, 70 ),
    raised = Color( 22, 30, 48 ),
    hair = Color( 50, 70, 110 )
}

function CNSX.PaintBox( x, y, w, h, col )
    col = col or CNSX.Theme.panel
    surface.SetDrawColor( col.r or 18, col.g or 18, col.b or 22, col.a or 255 )
    surface.DrawRect( x, y, w, h )
end

function CNSX.PaintFrame( self, w, h )
    local t = CNSX.Theme
    CNSX.PaintBox( 0, 0, w, h, t.bg )
    CNSX.PaintBox( 0, 0, w, 28, t.bar )
    CNSX.PaintBox( 0, 28, w, 2, t.accent )
    surface.SetDrawColor( t.accent )
    surface.DrawOutlinedRect( 0, 0, w, h, 1 )
    draw.SimpleText( "CNSX  /  ConsoleX", "DermaDefaultBold", 10, 14, t.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
end

function CNSX.Chip( parent, label, w, kind )
    local btn = vgui.Create( "DButton", parent )
    btn:SetWide( w or 76 )
    btn:SetText( label )
    btn:SetTextColor( CNSX.Theme.text )
    btn:SetCursor( "hand" )
    btn.Paint = function( self, ww, hh )
        local t = CNSX.Theme
        local col = t.panel
        if kind == "danger" then
            col = self:IsHovered() and t.accent or t.accent2
        elseif kind == "on" or self:IsHovered() then
            col = t.accent
        end
        CNSX.PaintBox( 0, 0, ww, hh, col )
        surface.SetDrawColor( t.line )
        surface.DrawOutlinedRect( 0, 0, ww, hh )
    end
    return btn
end

function CNSX.StyleBtn( btn, danger )
    btn:SetTextColor( CNSX.Theme.text )
    btn.Paint = function( self, w, h )
        local t = CNSX.Theme
        local col = danger and t.accent2 or t.panel
        if self:IsHovered() then
            col = t.accent
        end
        CNSX.PaintBox( 0, 0, w, h, col )
        surface.SetDrawColor( t.line )
        surface.DrawOutlinedRect( 0, 0, w, h )
    end
end
