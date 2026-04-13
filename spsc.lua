local MAGIC = "CSM1"
local HEADER = 12 -- magic + head u32 + tail u32

local function host_path(p)
  if package.config:sub(1, 1) == "\\" and p:sub(1, 1) == "/" then return "Z:" .. p end
  return p
end

local function u16_le(bytes)
  local b1, b2 = bytes:byte(1, 2)
  return b1 + b2 * 256
end

local function u32_le(bytes)
  local b1, b2, b3, b4 = bytes:byte(1, 4)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function pack_u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end

local function pack_u32(v)
  local b1 = v % 256
  local b2 = math.floor(v / 256) % 256
  local b3 = math.floor(v / 65536) % 256
  local b4 = math.floor(v / 16777216) % 256
  return string.char(b1, b2, b3, b4)
end

local function ensure_ring(path, slots, slot_size)
  path = host_path(path)
  local size = HEADER + slots * slot_size
  local f = io.open(path, "r+b") or io.open(path, "w+b")
  local cur = f:seek("end")
  if cur < size then f:write(string.rep("\0", size - cur)) end
  f:seek("set", 0)
  f:setvbuf("no")
  return f
end

local function head_tail(f, slots)
  f:seek("set", 0)
  local data = f:read(HEADER)
  if not data or #data < HEADER then return 0, 0 end
  local magic = data:sub(1, 4)
  local head = u32_le(data:sub(5, 8))
  local tail = u32_le(data:sub(9, 12))
  if magic ~= MAGIC or head >= slots or tail >= slots then return 0, 0 end
  return head, tail
end

local function store_head_tail(f, head, tail)
  f:seek("set", 0)
  f:write(MAGIC .. pack_u32(head) .. pack_u32(tail))
end

local function open_ring(path, slots, slot_size)
  local f = ensure_ring(path, slots, slot_size)
  return {
    pop = function()
      local head, tail = head_tail(f, slots)
      if tail == head then return nil end
      local base = HEADER + tail * slot_size
      f:seek("set", base)
      local len_bytes = f:read(2); if not len_bytes or #len_bytes < 2 then return nil end
      local len = u16_le(len_bytes)
      if len > slot_size - 2 then
        store_head_tail(f, head, (tail + 1) % slots)
        return nil
      end
      local data = len > 0 and f:read(len) or ""
      store_head_tail(f, head, (tail + 1) % slots)
      return data
    end,
    push = function(payload)
      local head, tail = head_tail(f, slots)
      local next_head = (head + 1) % slots
      if next_head == tail or #payload > slot_size - 2 then return false end
      local base = HEADER + head * slot_size
      f:seek("set", base)
      f:write(pack_u16(#payload))
      f:write(payload)
      store_head_tail(f, next_head, tail)
      return true
    end,
  }
end

return { open = open_ring }
