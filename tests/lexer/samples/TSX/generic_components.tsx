// TSX lexer stress: generics vs JSX, arrow generics with trailing comma
import * as React from "react";
import type { FC, ReactNode, PropsWithChildren } from 'react';

interface Props<T> {
  items: readonly T[];
  render: (item: T, index: number) => ReactNode;
  keyOf?: (item: T) => string | number;
}

// The <T,> trick disambiguates generic arrows from JSX in .tsx files
const identity = <T,>(x: T): T => x;
const pair = <A, B>(a: A, b: B): [A, B] => [a, b];
const constrained = <T extends object>(o: T) => Object.keys(o);
const withDefault = <T = string,>(v?: T) => v;
const asyncGeneric = async <T,>(p: Promise<T>): Promise<T> => await p;

export function GenericList<T>({ items, render, keyOf }: Props<T>) {
  return (
    <ul className="generic-list">
      {items.map((item, i) => (
        <li key={keyOf ? keyOf(item) : i}>{render(item, i)}</li>
      ))}
    </ul>
  );
}

export const Typed: FC<PropsWithChildren<{ title: string; count?: number }>> = ({
  title,
  count = 0,
  children,
}) => {
  const [value, setValue] = React.useState<string | null>(null);
  const ref = React.useRef<HTMLDivElement>(null);
  const map = new Map<string, Array<Record<string, number>>>();
  const cast = value as string;
  const nonNull = ref.current!;
  const ratio = count / 2 / (count || 1);

  return (
    <div ref={ref} title={title} data-ratio={ratio}>
      <h2>{title}'s header — it's "typed"</h2>
      <GenericList<number>
        items={[1, 2, 3]}
        render={(n) => <b>{n * 2}</b>}
      />
      <GenericList<{ id: string }> items={[{ id: "a" }]} render={x => x.id} keyOf={x => x.id} />
      {children}
      {value && <p>{value satisfies string}</p>}
      {/* comment with <Generic<T>> inside */}
      <Select<Option> options={opts} onChange={(o: Option | null) => setValue(o?.label ?? null)} />
    </div>
  );
};

type Option = { label: string; value: number };
declare const opts: Option[];
declare function Select<T>(props: { options: T[]; onChange(v: T | null): void }): JSX.Element;

enum Size { Small = "sm", Medium = 'md', Large = `lg` as any }

abstract class Base<TProps = {}> extends React.Component<TProps, { n: number }> {
  state = { n: 0 };
  protected abstract label(): string;
}

class Counter extends Base<{ step?: number }> {
  protected label() { return `count: ${this.state.n}`; }
  render() {
    const { step = 1 } = this.props;
    return (
      <button onClick={() => this.setState(s => ({ n: s.n + step }))}>
        {this.label()}
      </button>
    );
  }
}

const comparisons = (a: number, b: number) => a < b && b > a;
const shifts = (a: number) => (a << 1) >> 2 >>> 3;
const typeArgsCall = useMemo<Array<number>>(() => [], []);
const nestedGeneric: Promise<Map<string, Set<Array<number>>>> = Promise.resolve(new Map());
const fnType: <T>(x: T) => T = identity;
const objType: { <T>(x: T): T } = identity;

const regex = /<(\w+)\s*\/>/g;
const notRegex = total / items.length;

export const Page = () => (
  <>
    <Typed title="Page" count={10}>
      <Counter step={2} />
      <p>
        Text with {"{curly}"} braces and 'quotes' and a {`template ${"inner"}`}.
      </p>
    </Typed>
    <Typed title={`dynamic ${Size.Small}`} />
  </>
);

function useThing<T extends keyof HTMLElementTagNameMap>(tag: T): HTMLElementTagNameMap[T] {
  return document.createElement(tag);
}

const assertion = <T,>(v: unknown): asserts v is T => {};
const tupleOf = <const T extends readonly unknown[]>(...xs: T) => xs;
const inferred = tupleOf("a", 1, true);
type Elem = typeof inferred[number];

const template = `
  <div>${"not jsx in template"}</div>
  ${`<span>${1 / 2}</span>`}
`;

namespace JSX2 {
  export interface IntrinsicElements { "my-el": { foo?: string } }
}

const custom = <my-el foo="bar" />;

export default function Root({ mode }: { mode: "light" | "dark" }) {
  switch (mode) {
    case "light":
      return <div className="light">{mode}</div>;
    case 'dark':
      return <div className="dark">{mode}</div>;
  }
}

const strings = {
  a: 'single \'esc\'',
  b: "double \"esc\"",
  c: `back \`esc\``,
  d: "\x41A\u{1F600}",
  e: "\\",
};

const numbers = [0xFF_FF, 0b1010, 0o17, 1.5e-3, 1_000_000, 100n];

@decorator()
class Decorated {
  @prop() name: string = "";
}

function decorator() { return (t: any) => t; }
function prop() { return (t: any, k: string) => {}; }

const multiline = (
  <div
    className={[
      "a",
      cond ? "b" : "c",
    ].join(" ")}
    onClick={(e: React.MouseEvent<HTMLDivElement>) => {
      e.preventDefault();
    }}
  >
    child
  </div>
);
// end of the first TSX sample
