#!/usr/bin/env ts-node
// Second TS sample: decorators, overloads, accessors, comment nesting (none in TS)
/* block /* not nested in TS */ const visibleAfterComment = 1;

export {};
import json from "./data.json" with { type: "json" };
import { type A, type B } from "./ab";
export * as utils from './utils';
export default class {}

declare global {
  interface Window { __APP__: { version: string } }
}

type DeepPartial<T> = {
  [P in keyof T]?: T[P] extends object ? DeepPartial<T[P]> : T[P];
};
type Getters<T> = {
  [K in keyof T as `get${Capitalize<string & K>}`]: () => T[K];
};
type Unwrap<T> = T extends Promise<infer U> ? Unwrap<U> : T;
type Fn = (...args: readonly unknown[]) => asserts args is string[];
type Ctor = abstract new (...args: any[]) => object;
type Tuple = [first: string, second?: number, ...rest: boolean[]];
type Lit = -1 | 0x10 | 1e3 | 'a' | "b" | `c` | true | null | undefined;
type Shift = Array<Array<Array<number>>>;  // >>> should not be an operator here
const shifted = a >>> 2 >> 1 << 3;
const generic2 = new Map<string, Promise<Array<number>>>();

function overload(x: string): string;
function overload(x: number): number;
function overload(x: any) { return x; }

function isStr(v: unknown): v is string {
  return typeof v === "string";
}

const enum Flags {
  None = 0,
  A = 1 << 0,
  B = 1 << 1,
  AB = A | B,
  Str = "s".length,
}

export abstract class Repo<TEntity extends { id: number }, TKey = TEntity["id"]> {
  private readonly items = new Map<TKey, TEntity>();
  declare readonly brand: unique symbol;
  accessor counter = 0;
  static #instances = 0;
  static {
    Repo.#instances++;
  }
  override toString(): string {
    return `Repo(${this.items.size}) of ${typeof this}`;
  }
  public async find(id: TKey): Promise<TEntity | undefined> {
    await null;
    return this.items.get(id);
  }
}

function log(target: any, key: string, desc: PropertyDescriptor) {}
function cfg(opts: { name: string }) { return (t: any) => t; }

@cfg({ name: "svc" })
export class Service {
  @log
  run(@Inject("TOKEN") token: string): void {}

  @log @log
  twice() {}
}

const regexes = {
  email: /^[\w.+-]+@[\w-]+\.[\w.]+$/i,
  path: /\/usr\/local\/bin/,
  bracket: /[\[\]]/,
  slashInClass: /[a/b]/,
  escapedBracket: /\[\/\]/,
  flags: /x/dgimsuyv,
};
const notRegexes = {
  half: total / 2,
  ratio: (a / b) / (c / d),
  sub: arr[i] / arr[j] / 1,
  call: Math.max(1, 2) / 3,
  tpl: `${a}` / 2,
};

const html = `
<div>
  <p>${user.name.replace(/</g, "&lt;")}</p>
  ${list.map((item, i) => `
    <li data-i="${i}">${item.label ?? `untitled ${i}`}</li>
  `).join("\n")}
</div>`;

const sql = /* sql */ `
  SELECT * FROM "users" WHERE id = ${id} -- not a TS comment
  /* not a TS comment either */
`;

const strings = [
  'single',
  "double",
  `back`,
  '\x41B\u{43}\103',
  "tab\there",
  "\u{1F600}\u{10FFFF}",
  'a\
b',
  "",
  '',
];

// Line comment with URL http://example.com/path?x=1#frag
const url = "http://example.com/*not-comment*/";
const slashes = "//" + '//' + `//`;

let a1 = 1, b1 = 2;
a1
++b1;
const ternary = a1 ? /re/ : b1 / 2;
const obj = { re: /}/, str: "}", t: `}` };
const deep = ((((((1))))));
const arrowRet = () => ({} as const);
const keyofType: keyof typeof obj = "re";

switch (kind) {
  case "a": break;
  case 'b': { /* block */ break; }
  default:
    throw new Error(`unknown kind: ${kind satisfies never}`);
}

try {
  JSON.parse("{\"a\":1}");
} catch {
} finally {
}

export const enum E2 { X }
export type { Repo as R };
using res = getResource();
await using ares = getAsyncResource();

/*
 * This block comment is intentionally never closed.
 * Everything after here should be comment tokens:
 * const notCode = "string";
 * `template ${x}`
 * /regex/g
 * // line comment inside block
 */ /* reopened right after closing
function stillComment() {
  return 1 / 2;
}
class AlsoComment<T> {}
const z = `${ "never" }`;

// end of file inside block comment
