import { test } from "node:test";
import assert from "node:assert/strict";
import { escapeHtml, portableTextPlainText, portableTextToHtml, safeHref } from "./portable-text-html.ts";

const span = (text: string, marks: string[] = []) => ({ _type: "span", _key: text, text, marks });
const block = (children: unknown[], extra: Record<string, unknown> = {}) => ({
  _type: "block", _key: "b", style: "normal", children, markDefs: [], ...extra,
});

test("renders paragraphs, headings and block quotes", () => {
  const html = portableTextToHtml([
    block([span("Intro")]),
    block([span("Section")], { style: "h2" }),
    block([span("Quoted")], { style: "blockquote" }),
  ]);
  assert.equal(html, "<p>Intro</p><h2>Section</h2><blockquote><p>Quoted</p></blockquote>");
});

test("renders the standard marks", () => {
  const html = portableTextToHtml([
    block([span("bold", ["strong"]), span(" "), span("both", ["strong", "em"]), span(" "), span("x()", ["code"])]),
  ]);
  assert.equal(html, "<p><strong>bold</strong> <em><strong>both</strong></em> <code>x()</code></p>");
});

test("renders a link annotation, and drops an unsafe target but keeps its text", () => {
  const html = portableTextToHtml([
    block([span("read", ["l1"]), span(" "), span("bad", ["l2"])], {
      markDefs: [
        { _type: "link", _key: "l1", href: "https://example.com/a?b=1&c=2" },
        { _type: "link", _key: "l2", href: "javascript:alert(1)" },
      ],
    }),
  ]);
  assert.equal(html, '<p><a href="https://example.com/a?b=1&amp;c=2">read</a> bad</p>');
});

test("escapes text, so markup a writer typed stays text", () => {
  const html = portableTextToHtml([block([span(`<script>alert("x")</script> & more`)])]);
  assert.equal(html, "<p>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; more</p>");
  assert.equal(portableTextToHtml([block([span("line one\nline two")])]), "<p>line one<br>line two</p>");
});

test("groups list items into lists, nesting deeper levels inside the item before them", () => {
  const item = (text: string, listItem: string, level = 1) => block([span(text)], { listItem, level });
  const html = portableTextToHtml([
    item("one", "bullet"),
    item("one.a", "bullet", 2),
    item("two", "bullet"),
    item("first", "number"),
    block([span("after")]),
  ]);
  assert.equal(
    html,
    "<ul><li>one<ul><li>one.a</li></ul></li><li>two</li></ul><ol><li>first</li></ol><p>after</p>",
  );
});

test("renders images through EmDash's media route, galleries as their images, and code blocks", () => {
  const html = portableTextToHtml([
    { _type: "image", _key: "i", asset: { _ref: "01MEDIA" }, alt: "A \"quote\"", caption: "Taken today" },
    { _type: "image", _key: "e", asset: { _ref: "x", url: "https://cdn.example/p.jpg" } },
    { _type: "image", _key: "u", asset: { _ref: "y", url: "http://insecure.example/p.jpg" } },
    { _type: "gallery", _key: "g", images: [{ _type: "image", _key: "g1", asset: { _ref: "G1" }, alt: "" }] },
    { _type: "code", _key: "c", code: "if (a < b) {}" },
  ]);
  assert.equal(
    html,
    '<figure><img src="/_emdash/api/media/file/01MEDIA" alt="A &quot;quote&quot;"><figcaption>Taken today</figcaption></figure>' +
      '<figure><img src="https://cdn.example/p.jpg" alt=""></figure>' +
      '<figure><img src="/_emdash/api/media/file/G1" alt=""></figure>' +
      "<pre><code>if (a &lt; b) {}</code></pre>",
  );
});

test("leaves out raw HTML, tables and unknown blocks", () => {
  const html = portableTextToHtml([
    { _type: "htmlBlock", _key: "h", html: "<iframe src=//evil></iframe>" },
    { _type: "table", _key: "t", rows: [] },
    { _type: "plugin-widget", _key: "p", text: "hidden" },
    block([span("kept")]),
  ]);
  assert.equal(html, "<p>kept</p>");
});

test("renders a plain-string body as escaped paragraphs, and nothing for no body", () => {
  assert.equal(portableTextToHtml("One & two\n\nThree"), "<p>One &amp; two</p><p>Three</p>");
  assert.equal(portableTextToHtml(null), "");
  assert.equal(portableTextToHtml(undefined), "");
});

test("plain text joins each text block's spans, one block per line", () => {
  const text = portableTextPlainText([
    block([span("Hello "), span("world", ["strong"])]),
    { _type: "image", _key: "i", asset: { _ref: "m" } },
    block([span("Second")]),
  ]);
  assert.equal(text, "Hello world\nSecond");
});

test("safeHref allows web, mail and phone links, fragments and site paths only", () => {
  for (const ok of ["https://a.example", "http://a.example", "mailto:a@b.example", "tel:+1555", "#top", "/about/"]) {
    assert.equal(safeHref(ok), ok, ok);
  }
  for (const bad of ["javascript:alert(1)", "data:text/html,x", "//evil.example", "", "  ", 42, undefined]) {
    assert.equal(safeHref(bad), undefined, String(bad));
  }
  assert.equal(escapeHtml(`'<&>"`), "&#39;&lt;&amp;&gt;&quot;");
});
