if not CLIENT then return end

surface.CreateFont( "CNSX_Title", {
    font = "Tahoma",
    size = 16,
    weight = 700,
    antialias = true
} )
surface.CreateFont( "CNSX_Body", {
    font = "Tahoma",
    size = 13,
    weight = 500,
    antialias = true
} )
surface.CreateFont( "CNSX_Tiny", {
    font = "Tahoma",
    size = 11,
    weight = 500,
    antialias = true
} )
surface.CreateFont( "CNSX_Mono", {
    font = "Consolas",
    size = 14,
    weight = 500,
    antialias = true
} )

local T = {
    bg = Color( 16, 16, 18, 250 ),
    panel = Color( 24, 24, 28, 255 ),
    raised = Color( 34, 34, 40 ),
    hair = Color( 58, 58, 66 ),
    accent = Color( 56, 110, 220 ),
    accentDim = Color( 16, 28, 56 ),
    text = Color( 242, 242, 246 ),
    muted = Color( 140, 140, 148 ),
    shadow = Color( 0, 0, 0, 90 )
}

CNSX.Theme = CNSX.Theme or {}
for k, v in pairs( T ) do
    CNSX.Theme[k] = v
end
CNSX.Theme.err = CNSX.Theme.err or Color( 255, 80, 80 )
CNSX.Theme.ok = CNSX.Theme.ok or Color( 80, 200, 110 )
T = CNSX.Theme

local function logoMat()
    if CNSX._logo then
        return CNSX._logo
    end
    local mat = Material( "consolex/cnsx_banner.png", "smooth noclamp vertexalpha" )
    if not mat or mat:IsError() then
        mat = Material( "consolex/cnsx_logo.jpg", "smooth noclamp" )
    end
    CNSX._logo = mat
    return mat
end

function CNSX.DrawLogo( x, y, w, h )
    local mat = logoMat()
    if mat and not mat:IsError() then
        surface.SetMaterial( mat )
        surface.SetDrawColor( 255, 255, 255, 255 )
        surface.DrawTexturedRect( x, y, w, h )
        return true
    end
    draw.SimpleText( "CNSX", "CNSX_Title", x + 4, y + h * 0.5, T.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
    return false
end

function CNSX.SkinEntry( entry )
    if not IsValid( entry ) then
        return
    end
    entry:SetTextColor( T.text )
    entry:SetCursorColor( T.accent )
    entry:SetHighlightColor( T.accentDim )
    entry:SetDrawBackground( false )
    entry:SetPaintBackground( false )
    entry.Paint = function( self, w, h )
        draw.RoundedBox( 4, 0, 0, w, h, T.bg )
        surface.SetDrawColor( self:HasFocus() and T.accent or T.hair )
        surface.DrawOutlinedRect( 0, 0, w, h )
        if ( self:GetText() or "" ) == "" and not self:HasFocus() then
            draw.SimpleText( self:GetPlaceholderText() or "", "CNSX_Tiny", 6, h * 0.5, T.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
        end
        self:DrawTextEntryText( T.text, T.accent, T.text )
        return true
    end
end

function CNSX.SkinList( list )
    if not IsValid( list ) then
        return
    end
    list.Paint = function( self, w, h )
        draw.RoundedBox( 4, 0, 0, w, h, T.bg )
        return true
    end
end

local COMBO_HIDDEN = Color( 0, 0, 0, 0 )
local EDGE_HOT = Color( 180, 180, 190 )
local EDGE = Color( 70, 70, 78 )
local SUBTITLE = Color( 160, 190, 240 )
local CLOCK = Color( 140, 170, 220 )

-- fully self-drawn: background + border + label + chevron, so the box is visible on the dark panel
-- whatever the skin does (the old version relied on a fill nearly identical to the panel behind it)
function CNSX.SkinCombo( box, placeholder )
    if not IsValid( box ) then
        return
    end
    box._placeholder = placeholder
    box:SetFont( "CNSX_Body" )
    box:SetTextColor( COMBO_HIDDEN )
    if IsValid( box.DropButton ) then
        box.DropButton:SetVisible( false )
    end
    box.Paint = function( self, w, h )
        local open = self:IsMenuOpen()
        local hot = open or self:IsHovered()
        draw.RoundedBox( 4, 0, 0, w, h, hot and T.raised or T.bg )
        surface.SetDrawColor( hot and T.accent or T.hair )
        surface.DrawOutlinedRect( 0, 0, w, h )
        local label = self:GetText() or ""
        local col = T.text
        if label == "" then
            label = self._placeholder or ""
            col = T.muted
        end
        draw.SimpleText( label, "CNSX_Body", 8, h * 0.5, col, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
        local cx, cy = w - 12, h * 0.5
        surface.SetDrawColor( hot and T.text or T.muted )
        if open then
            surface.DrawLine( cx - 4, cy + 2, cx, cy - 2 )
            surface.DrawLine( cx, cy - 2, cx + 4, cy + 2 )
        else
            surface.DrawLine( cx - 4, cy - 2, cx, cy + 2 )
            surface.DrawLine( cx, cy + 2, cx + 4, cy - 2 )
        end
        return true
    end
end

function CNSX.FieldLabel( parent, text )
    local lab = vgui.Create( "DLabel", parent )
    lab:Dock( TOP )
    lab:DockMargin( 2, 4, 0, 1 )
    lab:SetTall( 14 )
    lab:SetFont( "CNSX_Tiny" )
    lab:SetText( text )
    lab:SetTextColor( T.muted )
    return lab
end

local function round( r, x, y, w, h, col )
    draw.RoundedBox( r, x, y, w, h, col )
end

local MAT_GRAD = Material( "gui/gradient", "noclamp smooth" )
local MAT_GRADU = Material( "vgui/gradient-u", "noclamp smooth" )
local MAT_CENT = Material( "gui/center_gradient", "noclamp smooth" )

function CNSX.PaintGrain( x, y, w, h, alpha )
    alpha = alpha or 18
    if MAT_GRAD and not MAT_GRAD:IsError() then
        surface.SetMaterial( MAT_GRAD )
        surface.SetDrawColor( 40, 70, 140, alpha )
        surface.DrawTexturedRect( x, y, w, h )
    end
    if MAT_GRADU and not MAT_GRADU:IsError() then
        surface.SetMaterial( MAT_GRADU )
        surface.SetDrawColor( 8, 12, 22, math.min( 90, alpha * 3 ) )
        surface.DrawTexturedRect( x, y + h * 0.55, w, h * 0.45 )
    end
    surface.SetDrawColor( 50, 90, 160, math.max( 6, alpha * 0.35 ) )
    local step = 16
    for gx = x, x + w, step do
        surface.DrawLine( gx, y, gx, y + h )
    end
    for gy = y, y + h, step do
        surface.DrawLine( x, gy, x + w, gy )
    end
end

function CNSX.PaintBrackets( w, h, inset )
    inset = inset or 8
    local len = 14
    surface.SetDrawColor( 80, 140, 230, 90 )
    surface.DrawRect( inset, inset, len, 2 )
    surface.DrawRect( inset, inset, 2, len )
    surface.DrawRect( w - inset - len, inset, len, 2 )
    surface.DrawRect( w - inset - 2, inset, 2, len )
    surface.DrawRect( inset, h - inset - 2, len, 2 )
    surface.DrawRect( inset, h - inset - len, 2, len )
    surface.DrawRect( w - inset - len, h - inset - 2, len, 2 )
    surface.DrawRect( w - inset - 2, h - inset - len, 2, len )
end

function CNSX.PaintSheen( y, w, h )
    local t = SysTime() * 28
    local x = ( t % ( w + 160 ) ) - 80
    if MAT_GRAD and not MAT_GRAD:IsError() then
        surface.SetMaterial( MAT_GRAD )
        surface.SetDrawColor( 180, 210, 255, 28 )
        surface.DrawTexturedRect( x, y, 80, h )
    else
        surface.SetDrawColor( 180, 210, 255, 18 )
        surface.DrawRect( x, y, 70, h )
    end
end

function CNSX.FireBanner( kind )
    CNSX.FlashRim( kind ~= "err" )
end

function CNSX.FlashRim( ok )
    CNSX._flash = {
        t = SysTime(),
        dur = 0.85,
        ok = ok ~= false
    }
    if CNSX.Prefs and CNSX.Prefs.sounds == false then
        return
    end
    if ok ~= false then
        surface.PlaySound( "buttons/button9.wav" )
    else
        surface.PlaySound( "resource/warning.wav" )
    end
end

function CNSX.PaintVital( x, y, w, h )
    if w < 48 or h < 8 then
        return
    end
    local mid = y + h * 0.5
    local burst = CNSX._banner
    local age = burst and ( SysTime() - burst.t ) or 99
    local live = burst and age >= 0 and age < burst.dur
    local fill = 0
    if live then
        local p = math.Clamp( age / burst.dur, 0, 1 )
        fill = 1 - ( 1 - p ) * ( 1 - p )
    end

    surface.SetDrawColor( 40, 80, 150, live and 70 or 35 )
    surface.DrawLine( x, mid, x + w, mid )

    if live then
        local fw = w * fill
        surface.SetDrawColor( 40, 90, 200, 70 )
        surface.DrawRect( x, y + 3, fw, h - 6 )
        if MAT_GRAD and not MAT_GRAD:IsError() then
            surface.SetMaterial( MAT_GRAD )
            surface.SetDrawColor( 140, 190, 255, 160 )
            surface.DrawTexturedRect( x + fw - 48, y + 2, 56, h - 4 )
        else
            surface.SetDrawColor( 160, 210, 255, 140 )
            surface.DrawRect( x + fw - 10, y + 2, 10, h - 4 )
        end
        surface.SetDrawColor( 200, 230, 255, 220 )
        surface.DrawRect( x + fw - 2, y + 1, 3, h - 2 )
    end

    local function beat( u )
        if not live then
            return 0
        end
        local localU = fill > 0.001 and ( u / math.max( fill, 0.05 ) ) or 0
        if localU > 1 then
            return 0
        end
        local phase = ( localU * 2.2 ) % 1
        if phase < 0.08 then
            return phase / 0.08 * 0.2
        end
        if phase < 0.14 then
            return 0.2 - ( phase - 0.08 ) / 0.06 * 0.45
        end
        if phase < 0.2 then
            return -0.25 + ( phase - 0.14 ) / 0.06 * 1.35
        end
        if phase < 0.26 then
            return 1.1 - ( phase - 0.2 ) / 0.06 * 1.5
        end
        if phase < 0.34 then
            return -0.4 + ( phase - 0.26 ) / 0.08 * 0.4
        end
        return 0
    end

    local steps = math.max( 48, math.floor( w / 2 ) )
    local amp = h * 0.44
    local px, py
    local limit = live and fill or 0
    for i = 0, steps do
        local u = i / steps
        if u > limit + 0.01 then
            break
        end
        local nx = x + u * w
        local ny = mid - beat( u ) * amp
        if px then
            surface.SetDrawColor( 120, 190, 255, 230 )
            surface.DrawLine( px, py, nx, ny )
        end
        px, py = nx, ny
    end
end

local FRAME = {}
function FRAME:Init()
    self:SetTitle( "" )
    self:ShowCloseButton( false )
    self:SetDraggable( true )
    self:SetSizable( true )
    self:DockPadding( 0, 36, 0, 0 )
    self.m_fCreateTime = SysTime()
    self._dragOff = nil
end

local RESIZE_GRIP = 20

function FRAME:OnMousePressed( code )
    if code ~= MOUSE_LEFT then
        return
    end
    self:MoveToFront()
    local cx, cy = self:CursorPos()
    -- bottom-right grip goes to DFrame, which owns SetSizable resizing
    if self:GetSizable() and not self._maxed and not self._minBar and cx > self:GetWide() - RESIZE_GRIP and cy > self:GetTall() - RESIZE_GRIP then
        DFrame.OnMousePressed( self, code )
        return
    end
    self:MouseCapture( true )
    if self._minBar then
        if isfunction( self._restore ) then
            self._restore()
        end
        return
    end
    if cy <= 36 and not self._maxed then
        self._dragOff = { x = cx, y = cy }
    end
end

function FRAME:OnMouseReleased( code )
    DFrame.OnMouseReleased( self, code )
    self._dragOff = nil
end

function FRAME:Think()
    DFrame.Think( self )
    if not self._dragOff then
        return
    end
    if not input.IsMouseDown( MOUSE_LEFT ) then
        self._dragOff = nil
        self:MouseCapture( false )
        return
    end
    local mx, my = input.GetCursorPos()
    local nx = mx - self._dragOff.x
    local ny = my - self._dragOff.y
    local sw, sh = ScrW(), ScrH()
    nx = math.Clamp( nx, 8 - self:GetWide(), sw - 8 )
    ny = math.Clamp( ny, 0, sh - 28 )
    self:SetPos( nx, ny )
end
function FRAME:Paint( w, h )
    local minBar = self._minBar == true
    if not minBar and ( not CNSX.Prefs or CNSX.Prefs.blur ~= false ) then
        Derma_DrawBackgroundBlur( self, self.m_fCreateTime or SysTime() )
    end
    local rad = ( minBar or self._maxed ) and 0 or 12
    if not minBar then
        round( rad, 3, 6, w - 6, h - 6, T.shadow )
    end
    round( rad, 0, 0, w, h, T.bg )
    if not minBar and ( not CNSX.Prefs or CNSX.Prefs.grain ~= false ) then
        CNSX.PaintGrain( 0, 36, w, h - 36, 14 )
    end
    surface.SetDrawColor( T.accentDim )
    surface.DrawRect( 0, 0, w, minBar and h or 36 )
    surface.SetDrawColor( 70, 70, 78 )
    surface.DrawOutlinedRect( 0, 0, w, minBar and h or 36 )
    CNSX.DrawLogo( 8, 2, minBar and 120 or 168, minBar and 24 or 32 )
    if not minBar then
        draw.SimpleText( self._subtitle or ( "v" .. tostring( CNSX.Version ) ), "CNSX_Tiny", 184, 19, SUBTITLE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
    else
        draw.SimpleText( "CNSX  hold C and click (or !cnsx) to restore", "CNSX_Tiny", 140, h * 0.5, T.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
    end
    draw.SimpleText( os.date( "%H:%M:%S" ), "CNSX_Tiny", w - 128, minBar and h * 0.5 or 19, CLOCK, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER )
    local flash = CNSX._flash
    if flash then
        local p = ( SysTime() - flash.t ) / ( flash.dur or 0.85 )
        if p < 1 then
            local a = math.floor( ( 1 - p ) * 230 )
            if flash.ok then
                surface.SetDrawColor( 40, 220, 90, a )
            else
                surface.SetDrawColor( 230, 50, 50, a )
            end
            surface.DrawOutlinedRect( 0, 0, w, h )
            surface.DrawOutlinedRect( 1, 1, w - 2, h - 2 )
            surface.DrawOutlinedRect( 2, 2, w - 4, h - 4 )
        end
    end
    return true
end
vgui.Register( "CNSXFrame", FRAME, "DFrame" )

local BTN = {}
AccessorFunc( BTN, "m_Kind", "Kind", FORCE_STRING )
function BTN:Init()
    self:SetFont( "CNSX_Body" )
    self:SetTextColor( T.text )
    self:SetCursor( "hand" )
    self.m_Kind = "default"
end
function BTN:Paint( w, h )
    local col = T.raised
    if self.m_Kind == "danger" then
        col = self:IsDown() and T.accent or ( self:IsHovered() and T.accent or T.accentDim )
    elseif self.m_Kind == "on" then
        col = T.accent
    elseif self:IsDown() then
        col = T.accentDim
    elseif self:IsHovered() then
        col = T.accent
    end
    draw.RoundedBox( 0, 0, 0, w, h, col )
    surface.SetDrawColor( self:IsHovered() and EDGE_HOT or EDGE )
    surface.DrawOutlinedRect( 0, 0, w, h )
    draw.SimpleText( self:GetText() or "", "CNSX_Body", w * 0.5, h * 0.5, T.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    return true
end
vgui.Register( "CNSXButton", BTN, "DButton" )

local ICON = {}
AccessorFunc( ICON, "m_Glyph", "Glyph", FORCE_STRING )
function ICON:Init()
    self:SetText( "" )
    self:SetCursor( "hand" )
    self.m_Glyph = "max"
end
function ICON:Paint( w, h )
    local hover = self:IsHovered()
    local col = hover and T.accent or T.raised
    if self.m_Glyph == "close" then
        col = hover and T.accent or T.accentDim
    end
    round( 5, 0, 0, w, h, col )
    surface.SetDrawColor( T.text )
    local cx, cy = w * 0.5, h * 0.5
    if self.m_Glyph == "min" then
        surface.DrawRect( cx - 5, cy, 10, 2 )
    elseif self.m_Glyph == "max" then
        surface.DrawOutlinedRect( cx - 5, cy - 4, 10, 9 )
    elseif self.m_Glyph == "restore" then
        surface.DrawOutlinedRect( cx - 3, cy - 5, 8, 7 )
        surface.DrawOutlinedRect( cx - 6, cy - 2, 8, 7 )
    else
        surface.DrawLine( cx - 4, cy - 4, cx + 4, cy + 4 )
        surface.DrawLine( cx + 4, cy - 4, cx - 4, cy + 4 )
    end
    return true
end
vgui.Register( "CNSXIcon", ICON, "DButton" )

local PNL = {}
function PNL:Init()
    self.m_Col = T.panel
    self.m_Rad = 8
end
function PNL:SetTone( col )
    self.m_Col = col
end
function PNL:Paint( w, h )
    round( self.m_Rad or 8, 0, 0, w, h, self.m_Col or T.panel )
    return true
end
vgui.Register( "CNSXPanel", PNL, "DPanel" )

local FIELD = {}
function FIELD:Init()
    self:SetFont( "CNSX_Mono" )
    self:SetTextColor( T.text )
    self:SetCursorColor( T.accent )
    self:SetHighlightColor( T.accentDim )
    self:SetDrawBackground( false )
    self:SetPaintBackground( false )
end
function FIELD:Paint( w, h )
    round( 6, 0, 0, w, h, T.bg )
    surface.SetDrawColor( self:HasFocus() and T.accent or T.hair )
    surface.DrawOutlinedRect( 0, 0, w, h )
    self:DrawTextEntryText( T.text, T.accent, T.text )
    return true
end
vgui.Register( "CNSXField", FIELD, "DTextEntry" )
