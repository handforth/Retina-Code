/**
 * TSX second sample: hooks, context, generics, and an unterminated comment at EOF.
 * @module hooks
 */
import React, { createContext, useContext, useReducer, type Dispatch } from "react";

type Action =
  | { type: "add"; payload: string }
  | { type: 'remove'; id: number }
  | { type: `reset` };

interface State {
  readonly items: ReadonlyArray<{ id: number; text: string }>;
  nextId: number;
}

const initial: State = { items: [], nextId: 1 };

function reducer(state: State, action: Action): State {
  switch (action.type) {
    case "add":
      return {
        items: [...state.items, { id: state.nextId, text: action.payload }],
        nextId: state.nextId + 1,
      };
    case "remove":
      return { ...state, items: state.items.filter(i => i.id !== action.id) };
    case "reset":
      return initial;
    default: {
      const _exhaustive: never = action;
      return _exhaustive;
    }
  }
}

const Ctx = createContext<[State, Dispatch<Action>] | null>(null);

export function Provider({ children }: { children: React.ReactNode }) {
  const value = useReducer(reducer, initial);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useStore(): [State, Dispatch<Action>] {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error(`useStore must be used inside <Provider>`);
  return ctx;
}

export const useDebounced = <T,>(value: T, ms = 300): T => {
  const [v, setV] = React.useState<T>(value);
  React.useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
};

function Input() {
  const [, dispatch] = useStore();
  const [text, setText] = React.useState("");
  const debounced = useDebounced(text);
  const valid = /^[\w\s'"-]{1,80}$/.test(debounced);
  const percent = (debounced.length / 80) * 100 / 1;
  return (
    <form
      onSubmit={e => {
        e.preventDefault();
        if (valid) dispatch({ type: "add", payload: text });
      }}
    >
      <input value={text} onChange={e => setText(e.currentTarget.value)} />
      <progress max={100} value={percent} />
      <span>{valid ? "ok" : `invalid: ${JSON.stringify(debounced)}`}</span>
      <button type="submit" disabled={!valid}>Add it's item</button>
    </form>
  );
}

function Items() {
  const [{ items }, dispatch] = useStore();
  return (
    <ol>
      {items.map(({ id, text }) => (
        <li key={id}>
          {text}{" "}
          <a href="#" onClick={() => dispatch({ type: "remove", id })}>
            &times;
          </a>
        </li>
      ))}
      {items.length === 0 ? <li><i>empty — nothing's here</i></li> : null}
    </ol>
  );
}

export const App = (): JSX.Element => (
  <Provider>
    <Input />
    <Items />
    <footer>
      {new Date().getFullYear()} &copy; {"Example {Inc}"}
    </footer>
  </Provider>
);

// Generic component with explicit type args in JSX
function Table<Row extends Record<string, unknown>>(props: { rows: Row[]; cols: (keyof Row)[] }) {
  return (
    <table>
      <tbody>
        {props.rows.map((r, i) => (
          <tr key={i}>
            {props.cols.map(c => <td key={String(c)}>{String(r[c])}</td>)}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

const t = <Table<{ a: number; b: string }> rows={[{ a: 1, b: "x" }]} cols={["a", "b"]} />;

type Props2 = React.ComponentProps<typeof Table>;
type Mapped = { [K in "a" | "b" as `on${Uppercase<K>}`]: () => void };
const keyRemap: Mapped = { onA() {}, onB: () => {} };

const lambdaReturningJsx = <P extends {}>(C: React.ComponentType<P>) =>
  (props: P) => <C {...props} />;

const hoc = lambdaReturningJsx(Items);

const nums = { h: 0xCAFE_BABE, b: 0B1111, o: 0O777, e: 6.02e+23, n: 9007199254740993n };
const ops = { a: 1 < 2, b: 2 > 1, c: 3 <= 4, d: 4 >= 3, e: 1 << 3, f: -8 >> 1 };
const ternaryJsx = ops.a ? <Yes /> : <No />;
const strangeSpacing = < div >spaced</ div >;

// Arrow function generics that look like tags
const f1 = <T,>() => <span />;
const f2 = <T extends unknown>(x: T) => <b>{String(x)}</b>;
const f3 = <K extends string, V,>(k: K, v: V) => ({ [k]: v });
const cmpChain = a < b > c;   // nonsense but lexable
const shiftedGeneric: Array<Array<number>>= [];
const strangeTpl = `${<b>jsx in template</b>}`;
const strInAttr = <div title="a 'b' \"c\"" />;

/* An unterminated block comment begins here and runs to EOF.
 * <Fake attr="x">jsx inside comment</Fake>
 * const s = "string in comment";
 * `template in comment ${x}`
 *
 * function notCode<T,>(x: T) { return x; }
 *
 * The lexer should keep every following line as a comment token.
 */  /*
const late = "still in comment";
export default App;
