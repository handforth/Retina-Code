--!strict
--!native
-- Luau lexer stress: type annotations, backtick interpolation, compound ops

--[[ Long comment with `backticks` and {braces}
     and "quotes" ]]
--[=[ level 1 long comment ]] still ]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService('ReplicatedStorage')

export type Vector = { x: number, y: number, z: number? }
type Callback<T...> = (T...) -> ()
type Map<K, V> = { [K]: V }
type Union = string | number | boolean | nil
type Intersection = { a: number } & { b: string }
type Optional = string?
type Fn = (a: number, b: string?, ...any) -> (boolean, ...string)
type Generic<T = string, U... = ...number> = { value: T, rest: (U...) -> () }
type Literal = "on" | "off" | 'maybe'
type ReadOnly = { read name: string, write age: number }
type function Keys(t)
  return types.unionof(table.unpack(t:keys()))
end

-- Interpolated strings with backticks
local name = "World"
local count = 3
local s1 = `Hello, {name}!`
local s2 = `Count: {count * 2} and {if count > 2 then "many" else "few"}`
local s3 = `Nested: {`inner {name}`} and {string.format("%d", 1)}`
local s4 = `Escaped brace: \{not interp\} and backtick \` and newline \n`
local s5 = `Table in interp: {({ a = 1 }).a}`
local s6 = `Multi-line via escape \
continues here {name}`
local s7 = `Unterminated interpolated string
local s8 = "regular after"
local s9 = `{name}{name}{name}`
local s10 = ``

-- Regular strings
local d1 = "double \"quoted\" \x41 \u{1F600} \65"
local d2 = 'single \'quoted\''
local d3 = [[long string with `backticks` and {braces}]]
local d4 = [==[
long level-2 string
]] inside
]==]
local d5 = "trailing backslash \\"

-- Numbers (Luau supports binary and separators)
local n1 = 0b1010_1010
local n2 = 0xFF_FF
local n3 = 1_000_000
local n4 = 1.5e-3
local n5 = .5
local n6 = 0x1p4

-- Compound assignment
local x = 1
x += 1
x -= 2
x *= 3
x /= 4
x //= 5
x %= 6
x ^= 2
local str = "a"
str ..= "b"

-- Typed functions
local function add(a: number, b: number): number
  return a + b
end

local function generic<T>(items: { T }, pred: (T) -> boolean): { T }
  local out: { T } = {}
  for _, item in items do
    if pred(item) then
      table.insert(out, item)
    end
  end
  return out
end

local function variadic(...: number): ...string
  local results = {}
  for i, v in { ... } do
    results[i] = tostring(v)
  end
  return table.unpack(results)
end

-- Type casts and assertions
local value = (someValue :: any) :: number
local inst = workspace:FindFirstChild("Part") :: BasePart?
local typed: { [string]: Vector } = {}

-- if-then-else expressions
local label = if count == 0 then "none" elseif count == 1 then "one" else "many"

-- continue keyword
for i = 1, 10 do
  if i % 2 == 0 then
    continue
  end
  print(i)
end

-- Classes via metatables with types
local Account = {}
Account.__index = Account

export type Account = typeof(setmetatable({} :: { balance: number, owner: string }, Account))

function Account.new(owner: string, balance: number?): Account
  local self = setmetatable({}, Account)
  self.owner = owner
  self.balance = balance or 0
  return self
end

function Account.deposit(self: Account, amount: number): ()
  assert(amount > 0, `Invalid amount: {amount}`)
  self.balance += amount
end

function Account:withdraw(amount: number): boolean
  if amount > self.balance then
    warn(`Insufficient funds for {self.owner}: {self.balance} < {amount}`)
    return false
  end
  self.balance -= amount
  return true
end

-- Roblox-flavored code
Players.PlayerAdded:Connect(function(player: Player)
  local leaderstats = Instance.new("Folder")
  leaderstats.Name = "leaderstats"
  leaderstats.Parent = player
  local coins = Instance.new("IntValue")
  coins.Name = "Coins"
  coins.Value = 0
  coins.Parent = leaderstats
  print(`{player.Name} joined with {coins.Value} coins`)
end)

local remote = ReplicatedStorage:WaitForChild("Remote") :: RemoteEvent
remote.OnServerEvent:Connect(function(player, action: string, ...)
  if action == "buy" then
    local args = { ... }
    print(`buy request from {player.UserId}: {#args} args`)
  end
end)

-- Generic iteration (no pairs/ipairs needed)
for k, v in { a = 1, b = 2 } do
  print(k, v)
end

local frozen = table.freeze({ 1, 2, 3 })
local cloned = table.clone(frozen)
local bitops = bit32.band(0xFF, 0x0F) + bit32.lshift(1, 4)
local vec = vector.create(1, 2, 3)

return {
  add = add,
  generic = generic,
  Account = Account,
}
