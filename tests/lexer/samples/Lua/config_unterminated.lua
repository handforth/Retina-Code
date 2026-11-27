-- Second Lua sample: a config module that ends inside an unterminated long comment.
local M = {}

M.version = "1.0.0"
M._VERSION = 'module ' .. M.version

--- LDoc style comment
-- @tparam string name the name
-- @treturn table
function M.create(name)
  return { name = name, created = os.time() }
end

M.defaults = {
  width = 800,
  height = 600,
  title = "Window \"Main\"",
  path = [[C:\Program Files\App\]],
  regex = "%d+%.%d+",
  colors = { 0xFF0000, 0x00FF00, 0x0000FF },
  ratio = 16 / 9,
  intdiv = 16 // 9,
  enabled = true,
  none = nil,
}

M.templates = {
  header = [[
<header>
  <h1>{{title}}</h1>
</header>]],
  footer = [==[
<footer>
  <p>]] inside a level-2 string is fine</p>
</footer>]==],
  inline = [[<span>inline</span>]],
}

local function render(tpl, vars)
  return (tpl:gsub("{{(%w+)}}", function(k)
    return tostring(vars[k] or ("{{" .. k .. "}}"))
  end))
end

M.render = render

local escapes = {
  "\\n is a newline escape",
  '\\ at end \\',
  "\"double\"",
  '\'single\'',
  "\x7A\122\u{7A}",
  "line one\
line two",
  "\z   skipped",
}

local Queue = {}
Queue.__index = Queue

function Queue.new()
  return setmetatable({ first = 1, last = 0, items = {} }, Queue)
end

function Queue:push(v)
  self.last = self.last + 1
  self.items[self.last] = v
end

function Queue:pop()
  if self.first > self.last then return nil end
  local v = self.items[self.first]
  self.items[self.first] = nil
  self.first = self.first + 1
  return v
end

function Queue:__len() return self.last - self.first + 1 end

M.Queue = Queue

local function serialize(v, indent)
  indent = indent or ""
  local tv = type(v)
  if tv == "string" then
    return string.format("%q", v)
  elseif tv == "number" or tv == "boolean" or tv == "nil" then
    return tostring(v)
  elseif tv == "table" then
    local parts = {}
    for k, val in pairs(v) do
      local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. serialize(k) .. "]")
      parts[#parts + 1] = indent .. "  " .. key .. " = " .. serialize(val, indent .. "  ")
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  end
  error("cannot serialize " .. tv, 2)
end

M.serialize = serialize

-- Numbers with odd forms
local nums = { 0, 00, 0.0, 0x0, 0x.1, 0x1., 1e+0, 1E-0, 3e2, 0xFFp-2, 1 // 1, 2 ^ -1 }

-- Method call on string literal and long string
local up = ("abc"):upper()
local len = #[[long]]
local call = print "no parens" or print [[long no parens]] or print { "table" }

-- Varargs and multiple assignment
local function va(...)
  local a, b, c = ...
  local packed = table.pack(...)
  return packed.n, a, b, c
end

-- Integer division vs comment start: a //b is division, a --b is a comment
local q = 10 //3
local r = 10 --3 this is a comment
local s = 10 - -3

-- Bitwise ops (5.3+)
local bits = (0xF0 & 0x3C) | (1 << 4) ~ (0xFF >> 2)

for _, line in ipairs({ "a", "b" }) do
  io.write(line, "\n")
end

-- Closures and upvalues
local function counter(start)
  local n = start or 0
  return function(step)
    n = n + (step or 1)
    return n
  end
end

local c1 = counter(10)
print(c1(), c1(5), c1(-2))

-- Metamethods
local Vec = {}
Vec.__index = Vec
Vec.__add = function(a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y }, Vec) end
Vec.__eq = function(a, b) return a.x == b.x and a.y == b.y end
Vec.__lt = function(a, b) return a.x < b.x end
Vec.__concat = function(a, b) return tostring(a) .. tostring(b) end
Vec.__tostring = function(v) return ("(%g, %g)"):format(v.x, v.y) end
Vec.__call = function(self, k) return self[k] end

M.Vec = Vec

M.long_comment_follows = true

--[==[ This long comment never closes.
It contains ]] and ]=] and even ]===] which are not the right level.
local not_code = "string inside"
function not_a_function() end
--[[ nested-looking opener ]]
return M
