#!/usr/bin/env lua
-- Lua lexer stress: long brackets, long comments, escapes, numbers

--[[ A long comment
     spanning multiple lines with "quotes" and 'apostrophes'
     and ]] inside? no — that closed it ]]
local afterComment = "visible"

--[==[ Level-2 long comment:
  contains ]] and ]=] which do NOT close it
  and [[ nested-looking ]] brackets
]==]
local afterLevel2 = 'visible too'

--[[ single-line long comment ]] local sameLine = 1
---[[ This is a line comment, not a long comment (three dashes trick)
local notCommented = true
--]]

-- Line comment with [[ brackets ]] that do not open anything
--[ not a long comment because only one bracket
--[=x not a long comment either

local s1 = "double \"quoted\" string"
local s2 = 'single \'quoted\' string'
local s3 = "escapes: \a \b \f \n \r \t \v \\ \" \' \0"
local s4 = "decimal escapes: \65\066\0671 hex: \x41\x42 utf8: \u{1F600} \u{41}"
local s5 = "z escape skips whitespace: \z
           continues here"
local s6 = "backslash-newline continues \
the string on the next line"
local s7 = "trailing backslash \\"
local s8 = "unterminated string at end of line
local s9 = 'next line after unterminated'

local long1 = [[
Long string: no escapes \n here,
"quotes" and 'apostrophes' are literal,
and -- this is not a comment
]]
local long2 = [==[
Level-2 long string with ]] and ]=] inside
and [[ another opener ]] that is just text
]==]
local long3 = [[single line long string]]
local long4 = [=[]=]
local long5 = [===[ ]==] ]=] ]] ]===]

-- Numbers
local n1 = 42
local n2 = 3.14
local n3 = .5
local n4 = 5.
local n5 = 1e10
local n6 = 1.5E-3
local n7 = 0xFF
local n8 = 0XdeadBEEF
local n9 = 0x1p4
local n10 = 0x1.8P-1
local n11 = 0xA.8
local n12 = 9007199254740993
local n13 = -0

-- Operators
local a, b = 10, 3
local ops = {
  a + b, a - b, a * b, a / b, a // b, a % b, a ^ b,
  a & b, a | b, a ~ b, ~a, a << 1, a >> 1,
  a == b, a ~= b, a < b, a <= b, a > b, a >= b,
  "con" .. "cat", #"len", not true, true and false or nil,
}

local t = {
  [1] = "one",
  ["key with spaces"] = 2,
  [ [[long key]] ] = 3,
  nested = { deep = { deeper = { 'x' } } },
  fn = function(...) return select('#', ...) end,
  'positional';
  "mixed separators",
}

local Account = {}
Account.__index = Account

function Account.new(balance)
  return setmetatable({ balance = balance or 0 }, Account)
end

function Account:deposit(v)
  self.balance = self.balance + v
  return self
end

function Account:__tostring()
  return string.format("Account(%.2f)", self.balance)
end

local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end

for i = 1, 10, 2 do
  print(i, fib(i))
end

for k, v in pairs(t) do
  if type(v) == "table" then
    goto continue
  end
  print(k, v)
  ::continue::
end

local i = 0
while i < 5 do i = i + 1 end
repeat i = i - 1 until i <= 0

local co = coroutine.wrap(function(x)
  local y = coroutine.yield(x * 2)
  return y + 1
end)
print(co(1), co(2))

local x <const> = 10
local f <close> = setmetatable({}, { __close = function() print("closed") end })

local pattern = "^%s*(%w+)%s*=%s*\"(.-)\"%s*$"
local key, val = ('name = "value"'):match(pattern)
local gsubbed = ("a.b.c"):gsub("%.", "/")

local ok, err = pcall(error, { code = 1 })
local msg = ok and "fine" or ("failed: " .. tostring(err.code))

-- Long bracket edge cases at line boundaries
local edge1 = [[
]]
local edge2 = [=[
]=]
local edge3 = [[]]  -- empty long string followed by comment
local edge4 = "--[[ not a comment in a string ]]"
local edge5 = '[[ not a long string in a quote ]]'
local edge6 = t[ [[key]] ]   -- indexing with a long string needs a space
local edge7 = t[[[key]]]      -- this is a call with a long string argument
-- end of edge cases

print([[
multi-line
print argument]], [==[and another
one]==])

return {
  Account = Account,
  fib = fib,
  strings = { s1, s2, s3, long1, long2 },
}
