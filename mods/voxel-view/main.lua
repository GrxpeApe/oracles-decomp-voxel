-- Voxel View: draws the current room as a little 3D voxel diorama.
--
-- A mod can read the game's memory and draw rectangles, nothing more, so this builds the diorama
-- from what the game keeps in work RAM bank 0: the room's tile layout, its per-tile collision
-- values (which say which quarter-tiles are solid) and the tile Link is standing on. Solid
-- quarter-tiles become raised voxel blocks, "special" collision tiles (water, holes, ledges...)
-- become low slabs, and Link is a small green column.
--
-- On a build with oracles.rd_bank1 (this fork) Link is placed at his real pixel position and lifts
-- off the ground when he jumps. On a build without it he is snapped to his tile instead. Enemies,
-- items and NPCs are not shown, and tile *graphics* cannot be read, so colours come from the tile
-- number, not the art.

-- 0 = off, 1 = corner map (default, game stays fully playable), 2 = full-screen replacement of the
-- playfield. There is no settings menu yet (see MODDING.md), so change this line to switch.
local DEFAULT_VIEW = 1

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
local IS_LARGE = seasons and 0xcc4a or 0xcc2e    -- wRoomIsLarge

-- ---------------------------------------------------------------------------------------------
-- Colours (RGB555, red lowest).
local function rgb(r, g, b) return r + g * 32 + b * 1024 end

local PLATE   = rgb(2, 2, 4)
local PLATE_E = rgb(14, 14, 18)
local FLOOR   = { rgb(9, 18, 8), rgb(11, 20, 9), rgb(8, 16, 10) }
local WALL_T  = { rgb(25, 23, 20), rgb(23, 21, 18), rgb(27, 25, 22) }   -- top faces
local WALL_F  = { rgb(14, 12, 11), rgb(13, 11, 10), rgb(15, 13, 12) }   -- front faces
local WALL_S  = rgb(9, 8, 8)                                              -- shaded right edge
local SLAB_T  = { rgb(5, 14, 27), rgb(24, 12, 4), rgb(18, 8, 24), rgb(8, 24, 20) }
local SLAB_F  = { rgb(2, 7, 16), rgb(14, 6, 2), rgb(10, 4, 14), rgb(4, 14, 12) }
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
  local SH   = S // 2              -- slab height
  local ids, cv, qh = {}, {}, { {}, {} }   -- tile ids, collision bytes, quarter heights (0 floor, 1 slab, 2 wall)
  local txe  = math.min(tx0 + ntx - 1, 15)
  local tys  = math.max(ty0, 0)
  local tye  = math.min(ty0 + nty - 1, 10)
  local lrow = lpx and math.max(tys, math.min(tye, (lpy + 6) // 16))   -- the tile row his feet are in

  for ty = tys, tye do
    local base = ty * 16
    for tx = tx0, txe do
      local v = oracles.rd(COLL + base + tx)
      cv[tx], ids[tx] = v, oracles.rd(LAYOUT + base + tx)
      for q = 0, 3 do
        local h
        if v >= 16 then h = 1
        elseif (v >> q) & 1 == 1 then h = 2
        else h = 0 end
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
        if h == 2 then
          local k = id % 3 + 1
          rect(gx, gy - WH, S, S, WALL_T[k])             -- top face
          rect(gx, gy - WH + S, S, WH, WALL_F[k])        -- front face
          if S >= 4 and row[qx + 1] ~= 2 then            -- shaded edge where the block ends
            rect(gx + S - S // 4, gy - WH, S // 4, S + WH, WALL_S)
          end
        elseif h == 1 then
          local k = cv[tx] % 4 + 1
          rect(gx, gy - SH, S, S, SLAB_T[k])
          rect(gx, gy - SH + S, S, SH, SLAB_F[k])
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
    -- Corner map: the whole room at 2 pixels per quarter, on a dark plate, top-right of the picture.
    local S = 2
    local large = oracles.rd(IS_LARGE) ~= 0
    local ntx, nty = large and 15 or 10, large and 11 or 8
    local w, h = ntx * S * 2, nty * S * 2 + S * 3 // 2
    local px = oracles.screen() - w - 5
    cx0, cy0, cx1, cy1 = 0, 0, oracles.screen(), 144
    rect(px - 2, 1, w + 4, h + 4, PLATE_E)
    rect(px - 1, 2, w + 2, h + 2, PLATE)
    cx0, cy0, cx1, cy1 = px, 3, px + w, 3 + h
    render(px, 3 + S * 3 // 2, S, 0, 0, ntx, nty, 0, 0, lpx, lpy, lz)
  else
    -- Full view: the playfield (160x128, above the status bar) redrawn at 8 pixels per quarter,
    -- scrolled with the game's own camera, centred when widescreen is on.
    local ox = (oracles.screen() - 160) // 2
    cx0, cy0, cx1, cy1 = ox, 0, ox + 160, 128
    local camx, camy = oracles.rd(CAM_X), oracles.rd(CAM_Y)
    render(ox, 0, 8, camx // 16, camy // 16, 11, 9, camx % 16, camy % 16, lpx, lpy, lz)
  end
end)

oracles.on_room_change(function(room)
  oracles.log(string.format("voxel-view: room %d", room))
end)

oracles.log("voxel-view ready")
