require "rails_helper"

RSpec.describe CoPlan::Plans::WritingProvenance do
  let(:user) { create(:coplan_user) }

  def make_plan(content, kind: "human", input_sources: nil, token: nil)
    CoPlan::Plans::Create.call(title: "Writing sources", content: content, user: user,
      actor_type: kind, agent_name: token&.agent_name, api_token_id: token&.id, input_sources: input_sources)
  end

  def sources(content, kind = "human")
    { "runs" => [ [ content.encode(Encoding::UTF_16LE).bytesize / 2, kind ] ] }
  end

  def edit(plan, content, kind: "local_agent", input_sources: nil)
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content, base_revision: plan.current_revision,
      actor_type: kind, actor_id: user.id, input_sources: input_sources)
  end

  it "snapshots harness and model identity without exposing a credential" do
    token, = CoPlan::ApiToken.create_with_raw_token(user: user, name: "Codex", agent_name: "Codex",
      metadata: { "harness" => "codex", "model" => "reported-model", "harness_version" => "1.2" })
    plan = make_plan("Model text", kind: "local_agent", token: token)
    summary = plan.writing_provenance_summary
    expect(summary.fetch("counts")).to eq("human" => 0, "ai" => 9, "unknown" => 0)
    expect(summary.fetch("contributors").first).to include("harness" => "codex", "harness_name" => "Codex", "model" => "reported-model")
    expect(summary.to_json).not_to include(token.token_digest)
    token.update!(metadata: { "model" => "different-model" })
    expect(plan.current_plan_version.reload.writing_provenance.fetch("sources").values.first).to include("model" => "reported-model")
  end

  it "distinguishes typed text from paste while retaining the human actor" do
    plan = make_plan("Typed Pasted", input_sources: { "runs" => [ [ 6, "human" ], [ 6, "unknown" ] ] })
    expect(plan.current_plan_version.actor_type).to eq("human")
    expect(plan.writing_provenance_summary.fetch("counts")).to eq("human" => 5, "ai" => 0, "unknown" => 6)
    unknown = plan.current_plan_version.writing_provenance.fetch("sources").values.find { |source| source["kind"] == "unknown" }
    expect(unknown.fetch("user_id")).to eq(user.id)
  end

  it "keeps new missing human input evidence unknown" do
    plan = make_plan("Unknown source")
    expect(plan.writing_provenance_summary.fetch("counts")).to eq("human" => 0, "ai" => 0, "unknown" => 13)
  end

  it "caches inspection mappings and invalidates them when a backfill changes sources" do
    plan = make_plan("Agent", kind: "local_agent")
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    expect(described_class).to receive(:build_rendered_sources).once.and_call_original
    2.times { described_class.rendered_sources(plan.current_plan_version) }
    snapshot = plan.current_plan_version.writing_provenance
    snapshot.fetch("sources").values.first["user_name"] = "Updated name"
    expect(described_class).to receive(:build_rendered_sources).once.and_call_original
    described_class.rendered_sources(plan.current_plan_version)
  end

  it "rejects excessively fragmented inspection without parsing the document" do
    plan = make_plan("Agent", kind: "local_agent")
    stub_const("#{described_class}::MAX_INSPECTION_RUNS", 0)
    expect(CoPlan::Plans::MarkdownTextExtractor).not_to receive(:call)
    expect { described_class.rendered_sources(plan.current_plan_version) }.to raise_error(described_class::InspectionLimit)
  end

  it "attributes only changed characters in a line and removes deleted text" do
    plan = make_plan("abcdef", input_sources: sources("abcdef"))
    original = plan.current_plan_version.writing_provenance.deep_dup
    edit(plan, "abXdef")
    expect(plan.writing_provenance_summary.fetch("counts")).to eq("human" => 5, "ai" => 1, "unknown" => 0)
    edit(plan, "abdef", kind: "human", input_sources: sources("abdef"))
    expect(plan.writing_provenance_summary.fetch("counts")).to eq("human" => 5, "ai" => 0, "unknown" => 0)
    expect(plan.plan_versions.first.writing_provenance).to eq(original)
    expect(plan.reload.writing_provenance_summary.fetch("revision")).to eq(3)
  end

  it "converts UTF-16 evidence to Unicode codepoint ranges" do
    text = "Hi 🧑🏽‍💻"
    plan = make_plan(text, input_sources: sources(text))
    expect(plan.current_plan_version.writing_provenance.fetch("runs").sum(&:first)).to eq(text.length)
    expect(plan.writing_provenance_summary.fetch("counts").fetch("human")).to eq(text.delete(" ").length)
  end

  it "fails toward unknown for malformed evidence and split surrogate pairs" do
    [ { "runs" => [ [ 1, "human" ] ] }, { "runs" => [ [ 1, "human" ], [ 1, "unknown" ] ] },
      { "runs" => [ [ 2, "ai" ] ] }, { "runs" => "human" } ].each do |input|
      plan = make_plan("😀", input_sources: input)
      expect(plan.writing_provenance_summary.fetch("counts").fetch("unknown")).to eq(1)
    end
  end

  it "maps human evidence through a concurrent agent edit without claiming the agent's text" do
    original = "Left middle right"
    plan = make_plan(original, kind: "local_agent")
    edit(plan, "Remote middle right")
    draft = "#{original} local"
    CoPlan::Plans::SaveHumanDraft.call(plan: plan, content: draft, base_revision: 1, actor: user,
      input_sources: { "runs" => [ [ original.length, "unknown" ], [ 6, "human" ] ] })
    expect(plan.current_content).to eq("Remote middle right local")
    expect(plan.writing_provenance_summary.fetch("counts")).to eq("human" => 5, "ai" => 17, "unknown" => 0)
  end

  it "bounds pathological replacement diffs conservatively" do
    plan = make_plan("a" * 2000, input_sources: sources("a" * 2000))
    edit(plan, "b" * 2000)
    expect(plan.writing_provenance_summary.fetch("counts")).to eq("human" => 0, "ai" => 0, "unknown" => 2000)
  end

  it "preserves large unchanged margins instead of exhausting the diff budget" do
    text = "a" * 10_000
    runs = [ [ text.length, "human" ] ]
    changed = text.dup
    changed[5000] = "X"
    result = described_class.remap(text, changed, runs, [ [ changed.length, "ai" ] ])
    expect(result).to eq([ [ 5000, "human" ], [ 1, "ai" ], [ 4999, "human" ] ])
    lines = (1..2000).map { |i| "Line #{i}\n" }.join
    result = described_class.remap(lines, "#{lines}New text", [ [ lines.length, "human" ] ], [ [ lines.length + 8, "ai" ] ])
    expect(result).to eq([ [ lines.length, "human" ], [ 8, "ai" ] ])
  end

  it "does not credit a no-op or request input without creating a content version" do
    plan = make_plan("same", kind: "local_agent")
    expect { edit(plan, "same", kind: "human", input_sources: sources("same")) }.not_to change(CoPlan::PlanVersion, :count)
    expect(plan.writing_provenance_summary.fetch("counts").fetch("ai")).to eq(4)
  end

  it "retains accurate sources in rendered Unicode prose and formatted code" do
    text = "# Héllo 😀\n\nHuman **words** and `code`.\n"
    plan = make_plan(text, input_sources: sources(text))
    rendered = described_class.rendered_sources(plan.current_plan_version)
    expect(rendered.fetch(:text)).to eq("Héllo😀Humanwordsandcode.")
    expect(rendered.fetch(:runs).map { |_, key| rendered.fetch(:sources).fetch(key).fetch("kind") }.uniq).to eq([ "human" ])
    expect(rendered.fetch(:runs).sum(&:first)).to eq(rendered.fetch(:text).encode(Encoding::UTF_16LE).bytesize / 2)
  end
  it "retains the exact author and introduction revision of a one-word edit" do
    plan = make_plan("The worker may retry.", kind: "local_agent")
    edit(plan, "The worker may not retry.", kind: "human", input_sources: sources("The worker may not retry."))
    snapshot = plan.current_plan_version.writing_provenance
    human_key = snapshot.fetch("sources").find { |_, source| source["kind"] == "human" }.first
    expect(snapshot.fetch("runs").select { |_, key| key == human_key }.sum(&:first)).to eq(4)
    expect(snapshot.fetch("sources").fetch(human_key)).to include("origin_revision" => 2, "user_name" => user.name)
    edit(plan, "The worker may not retry. More context.")
    expect(plan.current_plan_version.writing_provenance.fetch("sources").fetch(human_key)).to include("origin_revision" => 2)
  end

  it "maps both prose and slide text without changing presentation offsets" do
    content = "Intro\n\n::: {.presentation #example}\n\n# Slide title\n\nSlide words.\n\n:::\n\nAfter deck."
    plan = make_plan(content, kind: "local_agent")
    data = described_class.rendered_sources(plan.current_plan_version)
    expect(data.fetch(:text)).to include("Slidetitle", "Slidewords.", "Afterdeck.")
    expect(data.fetch(:runs).map { |_, key| data.fetch(:sources).fetch(key).fetch("kind") }.uniq).to eq([ "ai" ])
  end

  it "excludes diagram source and image alt text without moving later prose origins" do
    initial = "```mermaid\nflowchart LR\n A[Foo]\n```\n\n![Foo](https://example.com/foo.png)\n\n<!-- notes Foo -->\n"
    plan = make_plan(initial, kind: "local_agent")
    changed = initial + "\nFoo\n"
    edit(plan, changed, kind: "human", input_sources: sources(changed))
    data = described_class.rendered_sources(plan.current_plan_version)
    expect(data.fetch(:text)).to eq("Foo")
    expect(data.fetch(:runs).map { |_, key| data.fetch(:sources).fetch(key).fetch("kind") }.uniq).to eq([ "human" ])
  end

  %w[human local_agent].each do |kind|
    it "retains #{kind} attribution through escaped punctuation and decoded entities" do
      content = 'Typed \*literal\* &amp; café &copy; &#x1F600; after.'
      plan = make_plan(content, kind: kind, input_sources: sources(content))
      data = described_class.rendered_sources(plan.current_plan_version)
      expect(data.fetch(:text)).to eq("Typed*literal*&café©😀after.")
      expected_kind = kind == "human" ? "human" : "ai"
      expect(data.fetch(:runs).map { |_, key| data.fetch(:sources).fetch(key).fetch("kind") }.uniq).to eq([ expected_kind ])
      expect(data.fetch(:runs).sum(&:first)).to eq(data.fetch(:text).encode(Encoding::UTF_16LE).bytesize / 2)
    end
  end

  it "does not assign a mixed-source entity to the author of its leading ampersand" do
    plan = make_plan("&lt;", kind: "local_agent")
    edit(plan, "&gt;", kind: "human", input_sources: sources("&gt;"))
    data = described_class.rendered_sources(plan.current_plan_version)
    expect(data.fetch(:text)).to eq(">")
    expect(data.fetch(:runs)).to eq([ [ 1, nil ] ])
  end

  it "preserves known sources in padded inline code and indented code blocks" do
    content = "` padded `\n\n    indented\n    café\n\n  ```ruby\n  fenced\n  ```\n\n    ```literal\n    remains code\n"
    plan = make_plan(content, input_sources: sources(content))
    data = described_class.rendered_sources(plan.current_plan_version)
    expect(data.fetch(:text)).to eq("paddedindentedcaféfenced```literalremainscode")
    expect(data.fetch(:runs).map { |_, key| data.fetch(:sources).fetch(key).fetch("kind") }.uniq).to eq([ "human" ])
  end

  it "maps supported raw HTML text while excluding attributes and comments" do
    content = '<details open title="Ignore"><summary>Note &amp; café</summary>raw <b>HTML</b> \*literal\*<!-- hidden --></details>'
    plan = make_plan(content, input_sources: sources(content))
    data = described_class.rendered_sources(plan.current_plan_version)
    expect(data.fetch(:text)).to eq('Note&caférawHTML\*literal\*')
    expect(data.fetch(:runs).map { |_, key| data.fetch(:sources).fetch(key).fetch("kind") }.uniq).to eq([ "human" ])
  end
end
