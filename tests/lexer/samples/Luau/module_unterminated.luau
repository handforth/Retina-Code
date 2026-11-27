--!nonstrict
-- Second Luau sample: signal/promise module, ends inside an unterminated long string

local Signal = {}
Signal.__index = Signal

export type Connection = {
  Connected: boolean,
  Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
  Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
  Fire: (self: Signal<T...>, T...) -> (),
  Wait: (self: Signal<T...>) -> T...,
  Destroy: (self: Signal<T...>) -> (),
}

type Handler = { fn: (...any) -> (), next: Handler? }

function Signal.new<T...>(): Signal<T...>
  local self = setmetatable({
    _head = nil :: Handler?,
    _count = 0,
    _destroyed = false,
  }, Signal)
  return (self :: any) :: Signal<T...>
end

function Signal:Connect(fn)
  assert(typeof(fn) == "function", `Connect expects a function, got {typeof(fn)}`)
  local handler: Handler = { fn = fn, next = self._head }
  self._head = handler
  self._count += 1
  local conn = { Connected = true }
  function conn.Disconnect(c)
    if not c.Connected then return end
    c.Connected = false
    self._count -= 1
    local prev: Handler? = nil
    local cur = self._head
    while cur do
      if cur == handler then
        if prev then prev.next = cur.next else self._head = cur.next end
        break
      end
      prev, cur = cur, cur.next
    end
  end
  return conn
end

function Signal:Fire(...)
  local h = self._head
  while h ~= nil do
    task.spawn(h.fn, ...)
    h = h.next
  end
end

function Signal:Wait()
  local thread = coroutine.running()
  local conn
  conn = self:Connect(function(...)
    conn:Disconnect()
    task.spawn(thread, ...)
  end)
  return coroutine.yield()
end

function Signal:Destroy()
  self._head = nil
  self._destroyed = true
  table.clear(self)
end

-- A tiny promise-ish helper
type Status = "pending" | "resolved" | "rejected"

local Promise = {}
Promise.__index = Promise

function Promise.new(executor: (resolve: (any) -> (), reject: (any) -> ()) -> ())
  local self = setmetatable({ status = "pending" :: Status, value = nil, _callbacks = {} }, Promise)
  local function settle(status: Status, value: any)
    if self.status ~= "pending" then return end
    self.status = status
    self.value = value
    for _, cb in self._callbacks do
      task.defer(cb, status, value)
    end
  end
  local ok, err = pcall(executor, function(v) settle("resolved", v) end, function(e) settle("rejected", e) end)
  if not ok then settle("rejected", err) end
  return self
end

function Promise:andThen(onOk: ((any) -> any)?, onErr: ((any) -> any)?)
  return Promise.new(function(resolve, reject)
    local function handle(status: Status, value: any)
      local cb = if status == "resolved" then onOk else onErr
      if cb then
        local ok, result = pcall(cb, value)
        if ok then resolve(result) else reject(result) end
      elseif status == "resolved" then
        resolve(value)
      else
        reject(value)
      end
    end
    if self.status == "pending" then
      table.insert(self._callbacks, handle)
    else
      task.defer(handle, self.status, self.value)
    end
  end)
end

-- Typed table utilities
local function map<T, U>(list: { T }, fn: (T, number) -> U): { U }
  local out = table.create(#list) :: { U }
  for i, v in list do
    out[i] = fn(v, i)
  end
  return out
end

local function reduce<T, A>(list: { T }, fn: (A, T) -> A, init: A): A
  local acc = init
  for _, v in list do
    acc = fn(acc, v)
  end
  return acc
end

local doubled = map({ 1, 2, 3 }, function(v: number, _i: number): number return v * 2 end)
local total = reduce(doubled, function(a: number, v: number) return a + v end, 0)
print(`total = {total}, avg = {total / #doubled}`)

local strings = {
  `simple {1 + 1}`,
  `with "double" and 'single' quotes inside {"interp"}`,
  `braces escaped \{ \} and backslash \\`,
  `nested {`level {`two {3}`}`}`,
  `expr with table {({ k = `v` }).k}`,
  "\u{48}\u{49}",
  '\x48\x49',
}

local nums = { 0b0, 0B1, 0x0, 0XF, 1_0, 1., .1, 1e1, 1E+1, 1e-1 }
local ops = nums[1] // 2 + nums[2] ^ 3 % 4

local docs = [==[
This long string is never closed. Everything after should be string content:
]] does not close it, nor does ]=]
local fake = `interp {inside} a long string`
return Signal
