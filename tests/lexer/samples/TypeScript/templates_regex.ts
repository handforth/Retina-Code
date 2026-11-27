// TypeScript lexer stress: template literals, regex vs division, numbers
/// <reference path="./globals.d.ts" />
/// <reference types="node" />
"use strict";

import type { Foo, Bar as Baz } from './types';
import * as path from "node:path";
import def, { named } from `not-really-legal-but-lexable`;

const single = 'it\'s a single-quoted string with \\ backslash';
const double = "double \"quoted\" with \x41\x42 and A and \u{1F600}";
const endsInBackslash = "trailing backslash \\";
const endsInBackslash2 = 'also trailing \\';
const unterminated = "this string never closes
const afterUnterminated = 42;
const unterminatedSingle = 'oops
let continued = "line one \
line two via backslash continuation \
line three";

const commentInString = "// not a comment /* nor this */";
const blockInString = '/* still a string */';
/* "string inside comment" and 'another' and `template` */
// 'unbalanced quote in line comment
/* multi
   line ' " ` comment
   with a regex /a\/b/ inside */

const tpl = `simple ${value} template`;
const nested = `a ${b + `c ${d + `e ${f}`} g`} h`;
const multiLine = `
  first line ${one}
  second line ${two + `inner
  spanning ${three}
  lines`}
  last line \` escaped backtick \${not interpolated}
`;
const tagged = html`<div class="${cls}">${items.map(i => `<li>${i}</li>`).join("")}</div>`;
const objInTemplate = `${ { a: 1, b: { c: `}` } }.a }`;
const braceString = `${ "}" } and ${ '}' } and ${ `}` }`;
const commentInInterp = `${ /* } */ x } and ${ // }
  y }`;

// Regex literals vs division
const re1 = /a\/b[/]c/gi;
const re2 = /[^\]\/]+/u;
const re3 = /(?<year>\d{4})-(?<month>\d{2})/v;
const re4 = /\//;
const re5 = /=/g;          // regex starting with =
const re6 = /=>/;
const division = a / b / c;
const division2 = (x + 1) / 2 / (y - 3);
const division3 = arr[0] / arr[1];
const division4 = obj.prop / 2;
const division5 = foo() / bar() /baz;
let n = 10; n /= 2; n /=3;
const mixed = x / 2 + /re/.test(s) ? 1 / 3 : /\d+/.exec(s);
const afterParen = (a) / b;
const afterKeyword = typeof /x/;
const inReturn = () => { return /ret/i; };
const inArray = [/a/, /b/g, 1 / 2];
const inCall = s.replace(/\s+/g, " ").split(/,/);
if (/^#/.test(line)) { /* regex after paren */ }
const notRegex = a++ / 2;
const notRegex2 = a-- / b;
const regexAfterBang = !/x/.test(y);
const regexAfterAmp = ok && /y/.test(z);
const classWithSlash = /[/]/;
const regexWithQuote = /"'`/;
const regexHashSlash = /#\//;

// Numbers
const hex = 0xFF_FF;
const hexUpper = 0XDEADBEEF;
const bin = 0b1010_0101;
const oct = 0o17;
const legacyOct = 0777;
const flt = 1.5e-3;
const flt2 = .5;
const flt3 = 5.;
const flt4 = 1E+10;
const sep = 1_000_000;
const big = 100n;
const bigHex = 0xFFn;
const member = 1..toString();
const member2 = 1.0.toFixed(2);
const neg = -0.0;
const weird = 0.1e-1_0;

// Generics and contextual keywords
type Dict<T> = { [key: string]: T };
type Nested = Map<string, Array<Set<number>>>;
type Cond<T> = T extends string ? 'str' : T extends number ? "num" : never;
type Tpl = `prefix-${string}-suffix`;
type TplNested = `a${`b${'c'}`}`;
interface Shape<T extends object = {}> extends Base<T>, Other {
  readonly kind: "shape";
  area?(): number;
  [index: number]: T;
}
function identity<T>(arg: T): T { return arg; }
const arrow = <T,>(x: T): T => x;
const cmp = a < b && c > d;      // comparison, not generics
const gen = f<string>(x);        // generic call
const lt = a < (b > c);
enum Color { Red = 1, Green = "g", Blue = 1 << 2 }
declare module "foo" { export const x: number; }
namespace NS.Inner { export type Q = keyof typeof obj; }
abstract class Animal<TFood> implements Eater<TFood> {
  #privateField = 1;
  static readonly count: number = 0;
  protected abstract eat(food: TFood): void;
  constructor(private readonly name: string, public age?: number) {
    super();
  }
  get type(): string { return 'animal'; }
  set type(v: string) { }
}

@Component({
  selector: 'app-root',
  template: `<h1>{{ title }}</h1>`,
})
class AppComponent {
  @Input() name!: string;
  @Output() changed = new EventEmitter<string>();
  @HostListener('window:resize', ['$event'])
  onResize(event: UIEvent) {}
}

const satisfiesCheck = { a: 1 } satisfies Record<string, number>;
const asCast = value as unknown as string;
const nonNull = maybe!.value!;
const optChain = a?.b?.[c]?.(d);
const nullish = a ?? b ??= c;
let x: number | undefined, y: string & {};
for await (const chunk of stream) { yield* chunk; }
label: for (;;) { break label; }

/**
 * JSDoc block with @param {string} name and `code` and {@link Foo}
 * @returns {Promise<void>}
 */
async function* gen2(name: string): AsyncGenerator<number, void, unknown> {
  yield 1;
}

/* a comment that contains */ const after = "visible"; /* another */
const s1 = '\'', s2 = "\"", s3 = `\``;
const s4 = '\\', s5 = "\\", s6 = `\\`;
const emptyTpl = ``;
const onlyInterp = `${x}`;
const dollarNoBrace = `$x $ {y} $$ $`;
const crlf = "a\r\nb";
const octalEscape = "\0\x00\u0000";
const lineSep = "  ";
const jsxLike = a<b>c;
const x2 = y
  / 2      // division at line start
  / 3;
const r2 = (
  /regex at line start/
);
const unclosedTemplate = `this template
spans and spans ${ok}
and ends at EOF without closing...
