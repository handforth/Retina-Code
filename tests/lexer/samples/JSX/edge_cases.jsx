'use client';
/* JSX second sample: weird boundaries, unterminated things */

import { h, render } from 'preact';

const icons = {
  check: <svg viewBox="0 0 24 24"><path d="M9 16.2L4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4L9 16.2z"/></svg>,
  close: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
    <line x1="18" y1="6" x2="6" y2="18" />
    <line x1="6" y1="6" x2="18" y2="18" />
  </svg>,
};

function Text() {
  return <p>
    He said "it's {'fine'}" and she said 'it isn{"'"}t'.
    {/* comment
        spanning
        lines */}
    Braces: {'{'} {"}"} {`${'{'}`}
    Arrow-like text: =&gt; and -&gt; and a > b in text
    Slash text: a / b / c and // and /* */
  </p>;
}

const renderProp = (
  <DataSource
    render={({ data, loading }) =>
      loading ? <Spinner size={16 / 2} /> : (
        <ul>
          {data.map(d => <li key={d}>{d}</li>)}
        </ul>
      )
    }
  />
);

const withChildrenFn = (
  <Consumer>
    {value => (
      <>
        <span>{value.a}</span>
        {value.b && <em>{value.b}</em>}
      </>
    )}
  </Consumer>
);

const deeplyNested = (
  <A>
    <B>
      <C>
        <D>
          <E>
            <F prop={<G inner={<H />} />}>
              text inside F
            </F>
          </E>
        </D>
      </C>
    </B>
  </A>
);

const attrsGalore = (
  <input
    a="1"
    b='2'
    c={3}
    d={"4"}
    e={'5'}
    f={`6`}
    g={[7, 8]}
    h={{ i: 9 }}
    j
    k-l="m"
    n:o="p"
    {...rest}
    {...{ q: 1 }}
  />
);

const conditional = flag
  ? <Yes />
  : <No />;

const generatorish = function* () {
  yield <Item />;
  yield* [<A key="a" />, <B key="b" />];
};

const asyncComp = async () => {
  const res = await fetch(`/api/items?limit=${10 / 2}`);
  const data = await res.json();
  return data.map(x => <Row {...x} />);
};

const regexAfterJsx = <div /> && /abc/.test(s);
const divisionAfterParen = (<div />) / 1;
const lt = i < n;
const gt = i > n;
const arrowGt = (a) => a > 0;
const genericLookalike = useState<number>(0);   // invalid in JSX, still lexable

const strs = [
  "double with \"escaped\" quotes",
  'single with \'escaped\' quotes',
  `backtick with \` escaped`,
  "unicode \u{1F600} \u00e9 \x7F",
  'trailing backslash \\',
];

const longTemplate = `
  <html>
    <body class="${theme}">
      ${content}
      ${items.map(i => `<p>${i.replace(/`/g, "\\`")}</p>`).join("")}
    </body>
  </html>
`;

const numbers = [0, -1, 1.5, .5, 5., 1e10, 1E-5, 0xff, 0b11, 0o7, 1_000, 10n];

function Weird() {
  return (
    <div>
      {
        /* expression container with only a comment */
      }
      {
        // also just a line comment
      }
      <>{"fragment with string"}</>
      {"multi\nline\tescapes"}
      <code>{"<"}{">"}{"&"}</code>
      <style>{`
        .a { color: red; }
        .b::after { content: "}"; }
      `}</style>
      <script dangerouslySetInnerHTML={{ __html: "var x = '</script>';" }} />
    </div>
  );
}

export { Text, Weird };

render(<Weird />, document.getElementById("root"));

const unclosedTag = (
  <div className="never-closed">
    <span>text
    {value}
    more text that's
