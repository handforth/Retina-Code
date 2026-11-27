// JSX lexer stress: nested elements, attributes, text with apostrophes and braces
import React, { useState, useEffect, Fragment } from "react";
import styles from './App.module.css';

/** @jsxRuntime automatic */
/* @jsxImportSource @emotion/react */

const Greeting = ({ name, count = 0 }) => (
  <div className="greeting" data-count={count}>
    Hello, {name}! It's a "nice" day, isn't it?
    <span title='single "quoted" attr'>don't stop</span>
    <span title="double 'quoted' attr">{`template ${name}`}</span>
  </div>
);

function List({ items }) {
  return (
    <ul>
      {items.map((item, i) =>
        <li key={item.id ?? i} className={i % 2 === 0 ? "even" : "odd"}>
          {item.label} &amp; {item.value} &lt;tag&gt; &#x41; &#65; &nbsp;
        </li>
      )}
      {/* a JSX comment with 'quotes' and "doubles" and </fake> tags */}
      {
        // a line comment inside an expression container
        items.length === 0 && <li className="empty">Nothing here; it's empty</li>
      }
    </ul>
  );
}

export default function App() {
  const [state, setState] = useState({ open: false, text: "" });
  useEffect(() => {
    const id = setInterval(() => setState(s => ({ ...s })), 1000 / 60);
    return () => clearInterval(id);
  }, []);

  const ratio = state.text.length / 2 / 3;
  const re = /<\/?[a-z]+>/gi;

  return (
    <>
      <Greeting name="World" count={3} />
      <Greeting name={'Single'} count={1 / 2} />
      <Greeting {...state} name={`T ${state.text}`} />
      <input
        type="text"
        value={state.text}
        onChange={e => setState({ ...state, text: e.target.value.replace(/\s+/g, " ") })}
        disabled
        aria-label="text input"
        style={{ color: "red", fontSize: 12, margin: "0 auto" }}
      />
      <br/>
      <hr />
      <img src="/img/a.png" alt="a picture of 'things'" />
      <Foo.Bar.Baz prop={1} />
      <svg:rect xlink:href="#a" />
      <my-element some-attr="x" />
      <Fragment key="frag">
        <p>
          Text with {"{braces}"} and {'}'} and {`}`} and a lonely &#123; brace
        </p>
        <p>Text that spans
          multiple lines and has an apostrophe: we're here
          and a URL http://example.com/a//b and // not a comment
          and /* not a comment */ either.
        </p>
      </Fragment>
      {state.open ? (
        <Modal onClose={() => setState({ ...state, open: false })}>
          <Modal.Header>Title's "here"</Modal.Header>
          <Modal.Body>
            {[1, 2, 3].map(n => <Item n={n} key={n}>{n * 2}</Item>)}
          </Modal.Body>
        </Modal>
      ) : null}
      {list.length > 0 && list.length < 10 && <Small />}
      {a < b ? <A /> : <B />}
      {a > b}
      <Conditional when={x => x > 0 && x < 100}>child</Conditional>
      <pre>{`
        multi-line template inside JSX
        with ${interp} and ${nested(`inner ${deep}`)}
      `}</pre>
      <textarea defaultValue="line1
line2 inside attribute string" />
      <div
        // comment between attributes
        id="x"
        /* block comment between attributes */
        class="y"
      >
        content
      </div>
    </>
  );
}

const Wrapped = React.memo(function Inner(props) {
  return <section {...props}>{props.children}</section>;
});

class Legacy extends React.Component {
  static defaultProps = { label: "legacy" };
  state = { n: 0 };
  handleClick = () => this.setState(({ n }) => ({ n: n + 1 }));
  render() {
    const { label } = this.props;
    return (
      <button onClick={this.handleClick} type="button">
        {label}: {this.state.n} clicks — that's {this.state.n > 1 ? "many" : 'few'}
      </button>
    );
  }
}

const notJsx = a < b && c > d;
const lessThan = x<y;
const shiftCmp = (a << 2) > (b >> 1);
const divide = total / count;
const regexInJsx = <div pattern={/^\d+$/.source} />;
const arrowInAttr = <div onClick={() => { if (a < b) return; }} />;
const tplInAttr = <div className={`btn btn-${kind} ${active ? 'on' : ''}`} />;
const strAttr = <a href="http://x.com/?a=1&b=2">link's text</a>;
const emptyExpr = <div>{}</div>;
const nestedFragments = <><><span>deep</span></></>;
const selfClosingNoSpace = <Comp/>;
const namespaced = <xml:lang value="en" />;
const numericEntity = <span>&#x1F600; &copy; &unknown;</span>;
const conditionalChain = (
  cond1 ? <One /> :
  cond2 ? <Two /> :
  <Three />
);

export const Table = ({ rows }) => (
  <table>
    <thead>
      <tr><th>Name</th><th>Value</th></tr>
    </thead>
    <tbody>
      {rows.map(({ name, value }) => (
        <tr key={name}>
          <td>{name}</td>
          <td>{value / 100}%</td>
        </tr>
      ))}
    </tbody>
  </table>
);

const str = "a string with </div> inside";
const str2 = '<notATag>';
const tpl = `<div>${"</div>"}</div>`;
// end of the first JSX sample
