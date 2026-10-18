-- Voxel View: draws the current room as a little 3D voxel diorama.
--
-- A mod can read the game's memory and draw rectangles, nothing more, so this builds the diorama
-- from what the game keeps in work RAM bank 0: the room's tile layout, its per-tile collision
-- values (which say which quarter-tiles are solid) and the tile Link is standing on. Solid
-- quarter-tiles become raised voxel blocks; the "special" collision values become water (flat and
-- blue), staircases (a low step) and cliff ledges (a half-height block); and Link is a small green
-- column. Those special values were read off the real Oracle of Ages ROM: $10 is water, $18 is a
-- staircase, $19-$1b are ledge pieces. Anything else >= $10 is drawn as a low grey slab.
--
-- On a build with oracles.rd_bank1 (this fork) Link is placed at his real pixel position and lifts
-- off the ground when he jumps. On a build without it he is snapped to his tile instead. Enemies,
-- items and NPCs are not shown, and tile *graphics* cannot be read, so colours come from the tile
-- number, not the art.

-- 0 = off, 1 = corner map (default, game stays fully playable), 2 = full-screen replacement of the
-- playfield. There is no settings menu yet (see MODDING.md), so change this line to switch.
local DEFAULT_VIEW = 1

local STATUS_BAR = 16        -- rows taken by the status bar, above the playfield

local view = oracles.setting("Voxel view", {0, 2, DEFAULT_VIEW})
local show_link = oracles.setting("Show Link", true)

-- ---------------------------------------------------------------------------------------------
-- Addresses. The room buffers are at the same place in both games; the rest differ.
local seasons  = oracles.game() == "seasons"
local COLL     = 0xce00                          -- wRoomCollisions, one byte per tile, stride 16
local LAYOUT   = 0xcf00                          -- wRoomLayout, one tile id per tile, stride 16
local TILEPOS  = seasons and 0xccb3 or 0xcc99    -- wActiveTilePos: Link's tile, (row << 4) | col
local CAM_Y    = seasons and 0xffa8 or 0xffaa    -- hCameraY
local CAM_X    = seasons and 0xffaa or 0xffac    -- hCameraX
local ROOM_W   = 0xcd0a                          -- wRoomWidth,  in 8-pixel tiles (20 or 30); same in both games
local ROOM_H   = 0xcd0b                          -- wRoomHeight, in 8-pixel tiles (16 or 22)

-- ---------------------------------------------------------------------------------------------
-- Colours (RGB555, red lowest).
local function rgb(r, g, b) return r + g * 32 + b * 1024 end

local PLATE   = rgb(2, 2, 4)
local PLATE_E = rgb(14, 14, 18)
local FLOOR   = { rgb(9, 18, 8), rgb(11, 20, 9), rgb(8, 16, 10) }
local WALL_T  = { rgb(25, 23, 20), rgb(23, 21, 18), rgb(27, 25, 22) }   -- top faces
local WALL_F  = { rgb(14, 12, 11), rgb(13, 11, 10), rgb(15, 13, 12) }   -- front faces
local WALL_S  = rgb(9, 8, 8)                                              -- shaded right edge

-- How each special collision value is drawn: top colour, front colour and height (0 = flat).
-- h is given as a function of the quarter size S so the corner map and full view both scale.
local WATER  = { top = rgb(5, 15, 28),  front = rgb(2, 8, 18),   h = function(S) return 0 end }
local STAIRS = { top = rgb(28, 10, 8),  front = rgb(16, 4, 4),   h = function(S) return S // 2 end }
local LEDGE  = { top = rgb(26, 16, 15), front = rgb(15, 8, 8),   h = function(S) return S end }
local OTHER  = { top = rgb(14, 13, 18), front = rgb(8, 7, 11),   h = function(S) return S // 2 end }
local SPECIAL = { [0x10] = WATER, [0x18] = STAIRS, [0x19] = LEDGE, [0x1a] = LEDGE, [0x1b] = LEDGE }
local TUNIC, SKIN, CAP = rgb(4, 22, 5), rgb(31, 24, 18), rgb(3, 15, 4)

-- ---------------------------------------------------------------------------------------------
-- A clipped rectangle: everything the diorama draws stays inside the box set for the current view
-- (the corner map must not leave its plate; the full view must not cover the status bar).
local cx0, cy0, cx1, cy1 = 0, 0, 160, 144
local draw_rect = oracles.draw_rect

local function rect(x, y, w, h, c)
  local x1, y1 = x + w, y + h
  if x < cx0 then x = cx0 end
  if y < cy0 then y = cy0 end
  if x1 > cx1 then x1 = cx1 end
  if y1 > cy1 then y1 = cy1 end
  if x1 > x and y1 > y then draw_rect(x, y, x1 - x, y1 - y, c) end
end

-- Draws tile rows ty0..ty0+nty-1 and columns tx0..tx0+ntx-1. (ox, oy) is where tile (tx0, ty0)'s
-- top-left lands on screen and (sx, sy) is a pixel scroll subtracted from that. One tile is two
-- by two "quarters" of S pixels each, which is exactly how the game stores collisions. Rows are
-- drawn back to front, so a tall block in front correctly hides what is behind it.
local function render(ox, oy, S, tx0, ty0, ntx, nty, sx, sy, lpx, lpy, lz)
  local T    = S * 2
  local WH   = S * 3 // 2          -- wall height in pixels
  local ids, qh = {}, { {}, {} }   -- tile ids; per quarter: false = floor, true = wall, or a SPECIAL kind
  local rw   = math.min(oracles.rd(ROOM_W) // 2, 15)       -- the room's size in 16-pixel tiles
  local rh   = math.min(oracles.rd(ROOM_H) // 2, 11)
  local txe  = math.min(tx0 + ntx - 1, rw - 1)
  local tys  = math.max(ty0, 0)
  local tye  = math.min(ty0 + nty - 1, rh - 1)
  local lrow = lpx and math.max(tys, math.min(tye, (lpy + 6) // 16))   -- the tile row his feet are in

  for ty = tys, tye do
    local base = ty * 16
    for tx = tx0, txe do
      local v = oracles.rd(COLL + base + tx)
      ids[tx] = oracles.rd(LAYOUT + base + tx)
      -- Values below $10 are four solid/not-solid bits, one per quarter of the tile. The game's own
      -- lookup (_simpleCollision) reads bit 3 for the top-left quarter, bit 2 top-right, bit 1
      -- bottom-left and bit 0 bottom-right, so quarter q (row * 2 + column) is bit 3 - q.
      for q = 0, 3 do
        local h
        if v >= 16 then h = SPECIAL[v] or OTHER
        else h = ((v >> (3 - q)) & 1) == 1 end
        qh[(q >> 1) + 1][tx * 2 + (q & 1)] = h
      end
    end

    local y = oy + (ty - ty0) * T - sy
    for qr = 0, 1 do
      local row = qh[qr + 1]
      local gy = y + qr * S
      for qx = tx0 * 2, txe * 2 + 1 do
        local tx = qx >> 1
        local gx = ox + (qx - tx0 * 2) * S - sx
        local id = ids[tx]
        local h  = row[qx]
        rect(gx, gy, S, S, FLOOR[id % 3 + 1])            -- the ground under every quarter
        if h == true then
          local k = id % 3 + 1
          rect(gx, gy - WH, S, S, WALL_T[k])             -- top face
          rect(gx, gy - WH + S, S, WH, WALL_F[k])        -- front face
          if S >= 4 and row[qx + 1] ~= true then         -- shaded edge where the block ends
            rect(gx + S - S // 4, gy - WH, S // 4, S + WH, WALL_S)
          end
        elseif h then
          local sh = h.h(S)
          rect(gx, gy - sh, S, S, h.top)
          if sh > 0 then rect(gx, gy - sh + S, S, sh, h.front) end
        end
      end
    end

    if ty == lrow then
      -- Game pixels to diorama pixels: a tile is 16 game pixels and T diorama pixels.
      local mx = ox - sx + (lpx - tx0 * 16) * S // 8 - S // 2     -- a column one quarter wide,
      local by = oy - sy + (lpy + 6 - ty0 * 16) * S // 8 - lz * S // 8   -- at his feet, lifted by z
      local bh, hh = S * 3 // 2, S
      rect(mx, by - bh, S, bh, TUNIC)
      rect(mx, by - bh - hh, S, hh, SKIN)
      rect(mx, by - bh - hh - S // 4, S, S // 4 + (S >= 4 and 1 or 0), CAP)
    end
  end
end

-- ---------------------------------------------------------------------------------------------
oracles.on_frame(function()
  local mode = view()
  if mode == 0 then return end

  local lpx, lpy, lz            -- Link's position in room pixels, and how high he is off the ground
  if show_link() then
    if oracles.rd_bank1 then
      lpx, lpy = oracles.rd_bank1(0xd00d), oracles.rd_bank1(0xd00b)   -- w1Link_xh, w1Link_yh
      local z = oracles.rd_bank1(0xd00f)                                -- w1Link_zh, signed, up is negative
      lz = z >= 128 and 256 - z or 0
    else
      local pos = oracles.rd(TILEPOS)                                   -- no bank 1: his tile's centre
      lpx, lpy, lz = (pos & 15) * 16 + 8, (pos >> 4) * 16 + 4, 0
    end
  end

  if mode == 1 then
    -- Corner map: the whole room at 2 pixels per quarter, on a dark plate, top-right of the
    -- playfield (just under the status bar, which takes the top 16 rows).
    local S = 2
    local ntx = math.min(oracles.rd(ROOM_W) // 2, 15)
    local nty = math.min(oracles.rd(ROOM_H) // 2, 11)
    if ntx == 0 or nty == 0 then return end              -- no room loaded yet
    local w, h = ntx * S * 2, nty * S * 2 + S * 3 // 2
    local px, py = oracles.screen() - w - 5, STATUS_BAR + 2
    cx0, cy0, cx1, cy1 = 0, 0, oracles.screen(), 144
    rect(px - 2, py - 1, w + 4, h + 4, PLATE_E)
    rect(px - 1, py, w + 2, h + 2, PLATE)
    cx0, cy0, cx1, cy1 = px, py + 1, px + w, py + 1 + h
    render(px, py + 1 + S * 3 // 2, S, 0, 0, ntx, nty, 0, 0, lpx, lpy, lz)
  else
    -- Full view: the playfield (160x128, below the status bar) redrawn at 8 pixels per quarter,
    -- scrolled with the game's own camera, centred when widescreen is on.
    local ox = (oracles.screen() - 160) // 2
    cx0, cy0, cx1, cy1 = ox, STATUS_BAR, ox + 160, 144
    local camx, camy = oracles.rd(CAM_X), oracles.rd(CAM_Y)
    render(ox, STATUS_BAR, 8, camx // 16, camy // 16, 11, 9, camx % 16, camy % 16, lpx, lpy, lz)
  end
end)

oracles.on_room_change(function(room)
  oracles.log(string.format("voxel-view: room %d", room))
end)

oracles.log("voxel-view ready")
