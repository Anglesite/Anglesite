import test from "node:test";
import assert from "node:assert/strict";
import { htmlToPlainText } from "./html-to-plain-text.ts";

test("htmlToPlainText: strips tags and collapses whitespace", () => {
  const html = "<html><body><h1>Hello</h1><p>World   there</p></body></html>";
  assert.equal(htmlToPlainText(html), "Hello World there");
});

test("htmlToPlainText: drops script, style, nav, header, footer content entirely", () => {
  const html =
    "<header>Site Nav</header><nav>Menu</nav><main><p>Real content</p></main>" +
    "<script>doStuff();</script><style>.x{color:red}</style><footer>Copyright</footer>";
  assert.equal(htmlToPlainText(html), "Real content");
});

test("htmlToPlainText: decodes common named and numeric entities", () => {
  const html = "<p>Fish &amp; Chips &mdash;&#8212; &quot;quoted&quot; &#39;single&#39;</p>";
  const result = htmlToPlainText(html);
  assert.ok(result.includes("Fish & Chips"));
  assert.ok(result.includes('"quoted"'));
  assert.ok(result.includes("'single'"));
});

test("htmlToPlainText: strips HTML comments", () => {
  assert.equal(htmlToPlainText("<p>Before<!-- hidden --> After</p>"), "Before After");
});

test("htmlToPlainText: empty input yields empty string", () => {
  assert.equal(htmlToPlainText(""), "");
});
