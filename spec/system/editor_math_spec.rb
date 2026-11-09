require "rails_helper"

RSpec.describe "Math in the rich editor", type: :system do
  let(:author) { create(:coplan_user, email: "editor-math@example.com") }
  let(:source) { "# Math\n\nThe area is $\\pi r^2$ and $x_1 * y_1$.\n\n$$\n\\sum_{i=1}^n a_i\n$$\n" }
  let(:plan) do
    CoPlan::Plans::Create.call(title: "Math", content: source, user: author,
      visibility: "draft", actor_type: "human")
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    visit plan_edit_page_path(plan)
    expect(page).to have_css(".document-editor__math", text: "$\\pi r^2$", wait: 20)
    expect(page).to have_no_css(".inline-editor--preparing", wait: 20)
  end

  it "round-trips every math form, including after the paragraph is re-serialized" do
    examples = [
      "Inline $x_1 + \\alpha$ and *$a*b$* here.\n",
      "Display $$\\frac{a_1}{b^2} * c$$ inline.\n",
      "$$\n\\sum_{i=1}^n x_i \\\\ y_*\n$$\n",
      "Code math $`\\frac{a_b}{c} * d`$ and `$x_1$` code.\n",
      "It costs $5 and $10.\n\nEscaped \\$x_1$ stays text.\n",
      "- Item $x_1^2$ and *b*\n- $$\n  a_1 * b_2\n  $$\n",
      "1. Step $\\alpha_i$\n   > quoted $y_j$\n",
      "| Cell | Value |\n| --- | --- |\n| $a_1$ | $\\beta^*$ |\n",
      "```math\nx_1 = \\frac{a}{b}\n```\n",
      "```ruby\nputs \"$x_1$\"\n```\n",
      "    indented $a_1$ code\n",
      "## Area $\\pi r^2$\n",
      "Compare $a<b$ and $[0,1] [2]$.\n"
    ]
    result = page.evaluate_async_script(<<~'JS', examples)
      const [sources, done] = arguments;
      Promise.all([import("coplan/rich_document"), import("prosemirror-model")]).then(([m, { Fragment }]) => {
        const maths = doc => {
          const found = [];
          doc.descendants(node => { if (node.isText && node.marks.some(mark => mark.type.name === "math")) found.push(node.text) });
          return found;
        };
        // Clearing each block's source forces the Markdown serializer.
        const reserialized = doc => m.serializeDocument(doc.copy(Fragment.from(
          Array.from({ length: doc.childCount }, (_, i) => doc.child(i)).map(node =>
            node.type.create({ ...node.attrs, ...(node.type.spec.attrs.snapshot ? { source: null, snapshot: null } : {}) }, node.content, node.marks)))));
        done(sources.map(source => {
          const doc = m.parseDocument(source), kinds = [];
          doc.forEach(node => kinds.push(node.type.name));
          return { exact: m.serializeDocument(doc) === source, kinds, maths: maths(doc), forced: reserialized(doc) };
        }));
      }).catch(error => done({ error: error.message }));
    JS
    expect(result).to all(include("exact" => true))
    expect(result.map { |entry| entry.fetch("maths") }).to eq([
      [ "$x_1 + \\alpha$", "$a*b$" ],
      [ "$$\\frac{a_1}{b^2} * c$$" ],
      [ "$$\n\\sum_{i=1}^n x_i \\\\ y_*\n$$" ],
      [ "$`\\frac{a_b}{c} * d`$" ],
      [],
      [ "$x_1^2$", "$$\na_1 * b_2\n$$" ],
      [ "$\\alpha_i$", "$y_j$" ],
      [], [], [], [],
      [ "$\\pi r^2$" ],
      [ "$a<b$", "$[0,1] [2]$" ]
    ])
    # Math stays in rich prose: no source cards for these paragraphs.
    expect(result.first(4).map { |entry| entry.fetch("kinds") }).to all(eq([ "paragraph" ]))
    expect(result.last.fetch("kinds")).to eq([ "paragraph" ])
    forced = result.map { |entry| entry.fetch("forced") }
    expect(forced[0]).to eq("Inline $x_1 + \\alpha$ and *$a*b$* here.")
    expect(forced[1]).to eq("Display $$\\frac{a_1}{b^2} * c$$ inline.")
    expect(forced[2]).to eq("$$\n\\sum_{i=1}^n x_i \\\\ y_*\n$$")
    expect(forced[3]).to eq("Code math $`\\frac{a_b}{c} * d`$ and `$x_1$` code.")
    expect(forced[4]).to eq("It costs $5 and $10.\n\nEscaped \\$x_1$ stays text.")
    expect(forced[5]).to eq("* Item $x_1^2$ and *b*\n* $$\n  a_1 * b_2\n  $$")
    expect(forced[6]).to eq("1. Step $\\alpha_i$\n\n   > quoted $y_j$")
    expect(forced[8]).to eq("```math\nx_1 = \\frac{a}{b}\n```")
    expect(forced[11]).to eq("## Area $\\pi r^2$")
    expect(forced[12]).to eq("Compare $a<b$ and $[0,1] [2]$.")

    edits = [
      [ "Energy $E = mc^2$, $\\sum_{i=1}^n x_i * y_i$, $`a_b \\\\ c`$ and\n$$\n\\int_0^1 f^*(x)\\,dx\n$$\ncost $5 and $10.\n", " Edited_*." ],
      [ "Escaped \\$x$ and \\$y_1$ cost $5 and $10.\n", " Edited." ],
      [ "Pay \\$$x$ now.\n", " Edited." ],
      [ "Price $5 and x\\$ later.\n", " Edited." ]
    ]
    edited = page.evaluate_async_script(<<~'JS', edits)
      const [examples, done] = arguments;
      import("coplan/rich_document").then(m => done(examples.map(([source, addition]) => {
        const doc = m.parseDocument(source), paragraph = doc.firstChild;
        // An ordinary edit: the block keeps its old source, but no longer matches it.
        const changed = paragraph.type.create(paragraph.attrs, paragraph.content.addToEnd(doc.type.schema.text(addition)));
        return m.serializeDocument(doc.copy(doc.content.replaceChild(0, changed)));
      }))).catch(error => done({ error: error.message }));
    JS
    expect(edited).to eq([
      # Soft line breaks outside math become spaces, as for any edited paragraph;
      # every math span, including the display block's own lines, stays exact.
      "Energy $E = mc^2$, $\\sum_{i=1}^n x_i * y_i$, $`a_b \\\\ c`$ and $$\n\\int_0^1 f^*(x)\\,dx\n$$ cost $5 and $10. Edited\\_\\*.",
      # Literal dollars stay literal: only a dollar comrak would read as a
      # delimiter is escaped, and currency stays bare.
      "Escaped \\$x$ and \\$y_1$ cost $5 and $10. Edited.",
      "Pay \\$$x$ now. Edited.",
      "Price \\$5 and x$ later. Edited."
    ])
  end

  it "recognizes exactly the math spans the server renders" do
    lines = [
      "costs $5 and $10", "$$$x$$$", "$$x$", "a $x$5 b", "a $x $ b", "a $ x$ b", "\\$x$", "$a\\$b$",
      "$`x`$ and $`a`", "`$x$` and $`y$`", "$x_1$ and *$a*b$*", "x $$ a $ b $$ y", "$$a$ b$", "$a$ b$c$",
      "$a\\\\$ b", "$a\\$", "$`a`b`$", "$` a `$", "$$ a $$", "$a$x", "a$b$c", "$$a$$5", "*a $x*y$ b*",
      "[$x]$](https://example.com)", "$a\nb$", "$a\n$", "$`$", "$a$$", "$a$$$b$", "$$a$b$$", "$$a$$b$$",
      "$a$$b$", "_$x_1$_ and __$y$__", "$x$\\", "$-1$ and $+2$", "$``$ x`$", "$`$ x`$", "$```$", "a $$$$ b",
      "It costs $5 and $10.", "Escaped \\$x_1$ stays text.", "It costs $5 and $10, or \\$x_1$ escaped."
    ]
    browser = page.evaluate_async_script(<<~'JS', lines)
      const [sources, done] = arguments;
      Promise.all([import("coplan/rich_document"), import("prosemirror-markdown")]).then(([, { defaultMarkdownParser }]) => {
        const strip = math => (math.startsWith("$`") ? math.slice(2, -2) : math.startsWith("$$") ? math.slice(2, -2) : math.slice(1, -1)).replace(/\s+/g, " ").trim();
        done(sources.map(source => defaultMarkdownParser.tokenizer.parseInline(source, {})[0].children
          .filter(token => token.type === "coplan_math").map(token => strip(token.content))));
      }).catch(error => done({ error: error.message }));
    JS
    server = lines.map do |line|
      html = Commonmarker.to_html(line, options: { extension: CoPlan::MarkdownHelper::EXTENSION_OPTIONS })
      Nokogiri::HTML.fragment(html).css("[data-math-style]").map { |node| node.text.gsub(/\s+/, " ").strip }
    end
    expect(browser).to eq(server)
  end

  it "keeps math exact when typing into its paragraph and styles it in both themes" do
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      style = page.evaluate_script(<<~'JS')
        (() => {
          const math = getComputedStyle(document.querySelector(".document-editor__math"));
          const paper = getComputedStyle(document.querySelector(".document-editor__paper"));
          return { font: math.fontFamily, paperFont: paper.fontFamily, background: math.backgroundColor, color: math.color, paperColor: paper.color };
        })()
      JS
      expect(style.fetch("font")).not_to eq(style.fetch("paperFont"))
      expect(style.fetch("background")).not_to eq("rgba(0, 0, 0, 0)")
      expect(style.fetch("color")).to eq(style.fetch("paperColor"))
    end
    expect(page).to have_css(".document-editor__math", exact_text: "$$\n\\sum_{i=1}^n a_i\n$$")
    paragraph = find(".ProseMirror > p", text: "The area is")
    paragraph.click
    paragraph.send_keys(:end, " Then *x_2*. Typed $x_1 + \\alpha$ costs $5 and $10.")
    expect(paragraph).to have_text("Then *x_2*.")
    # The closing dollar turns a math span raw; currency never does.
    expect(paragraph).to have_css(".document-editor__math", exact_text: "$x_1 + \\alpha$")
    expect(paragraph).to have_css(".document-editor__math", count: 3)
    paragraph.send_keys(:enter, "Undone $y$")
    undone = find(".ProseMirror > p", text: "Undone")
    expect(undone).to have_css(".document-editor__math", exact_text: "$y$")
    undone.send_keys(:backspace)
    expect(undone).to have_no_css(".document-editor__math")
    expect(undone).to have_text("Undone $y$")
    expected = "# Math\n\nThe area is $\\pi r^2$ and $x_1 * y_1$. Then \\*x_2\\*. Typed $x_1 + \\alpha$ costs $5 and $10.\n\n" \
      "Undone \\$y$\n\n$$\n\\sum_{i=1}^n a_i\n$$\n"
    click_button "Raw", exact: true
    expect(find('[aria-label="Markdown source"]').text).to eq(expected.strip)
    click_button "Editor", exact: true
    click_link "Done"
    expect(page).to have_current_path(plan_page_path(plan), wait: 15)
    expect(plan.reload.current_content).to eq(expected)
  end
end
