require "rails_helper"

RSpec.describe "Document components", type: :request do
  let(:user) { create(:coplan_user) }
  let(:catalog) { Coplan::ComponentCatalog.new }
  let(:content) do
    <<~'MD'
      # Demo

      ::: {.component #retry type="diagram" uses="maths@1" title="Retry flow"}

      const { delay } = await import("maths");
      diagram.node("retry", "Retry " + delay(2));

      :::
    MD
  end

  before do
    allow(Coplan.configuration).to receive(:component_catalog).and_return(catalog)
    catalog.library("maths@1", source: "export const delay = n => n * 10", example: "delay(2)")
  end

  it "serves a fixed sandbox even on a direct visit" do
    get component_frame_path, params: { source: "ignored-component-input" }
    expect(response).to have_http_status(:ok)
    nonce = Nokogiri::HTML.fragment(response.body).at_css("script")["nonce"]
    expect(response.headers["Content-Security-Policy"]).to include("sandbox allow-scripts;", "frame-ancestors 'self'", "connect-src 'none'", "'nonce-#{nonce}'")
    expect(response.headers["Content-Security-Policy"]).not_to include("allow-same-origin", "'unsafe-eval'")
    expect(response.headers["Connection-Allowlist"]).to eq("()")
    expect(response.body).not_to include("ignored-component-input")
    allow(Coplan.configuration).to receive(:components_enabled).and_return(false)
    get component_frame_path
    expect(response).to have_http_status(:not_found)
  end

  it "retains modules for each version and signs whole-component comments" do
    sign_in_as(user)
    plan = Coplan::Plans::Create.call(title: "Demo", content:, user:, actor_type: "human")
    first = plan.current_plan_version
    catalog.library("maths@1", source: "export const delay = n => n * 20", example: "delay(2)")
    get plan_page_path(plan)
    block = Nokogiri::HTML.fragment(response.body).at_css("figure#retry")
    payload = JSON.parse(block["data-coplan--component-program-value"])
    expect(payload.fetch("libraries").keys).to contain_exactly("diagram", "maths")
    expect(payload.dig("libraries", "maths")).to include("* 10")
    expect(first.component_catalog.dig("libraries", "maths@1", "sha256")).to eq(Digest::SHA256.hexdigest(payload.dig("libraries", "maths")))
    expect(block.at_css("iframe")["sandbox"]).to eq("allow-scripts")
    target = JSON.parse(block.at_css("button")["data-source-target"])
    resolved = Coplan::Plans::SourceTargets.resolve(target["token"], first.content_markdown)
    expect(resolved).to include("kind" => "component", "label" => "Retry flow")
    expect(first.content_markdown[resolved["start"]...resolved["end"]]).to eq(content.split("\n\n", 2).last.chomp)
    expect(Coplan::Plans::SourceTargets.new(first.content_markdown).ranges).to include([ "component", resolved["start"], resolved["end"] ])

    thread = plan.comment_threads.create!(plan_version: first, created_by_user: user, source_token: target["token"])
    Coplan::Plans::ReplaceContent.call(plan:, new_content: content.sub("delay(2)", "delay(3)"), granularity: :character, base_revision: plan.current_revision,
      actor_type: "human", actor_id: user.id)
    expect(thread.reload).not_to be_out_of_date
    expect(thread.anchor_text).to include("delay(3)")
    expect(plan.reload.current_plan_version.component_catalog.dig("libraries", "maths@1", "source")).to include("* 20")
    get plan_version_page_path(plan, first)
    historical = Nokogiri::HTML.fragment(response.body).at_css("figure#retry")
    expect(JSON.parse(historical["data-coplan--component-program-value"]).dig("libraries", "maths")).to include("* 10")
    expect(first.reload.component_catalog.dig("libraries", "maths@1", "source")).to include("* 10")
  end

  it "uses the saved type's text comment preference with per-block overrides" do
    sign_in_as(user)
    catalog.type("custom", source: "", bindings: [], example: "", text_comments: false)
    markers = [ "", ' type="custom"', ' type="custom" text-comments="on"', ' text-comments="off"' ]
    markdown = markers.map { |attrs| "::: {.component#{attrs}}\n\nroot.textContent = 'Content'\n\n:::" }.join("\n\n")
    plan = Coplan::Plans::Create.call(content: "# Preferences\n\n#{markdown}", user:, actor_type: "human")
    get plan_page_path(plan)
    flags = Nokogiri::HTML.fragment(response.body).css("figure.document-component").map do |block|
      JSON.parse(block["data-coplan--component-program-value"]).fetch("textComments")
    end
    expect(flags).to eq([ true, false, true, false ])
  end

  describe "component annotations" do
    let(:plan) { Coplan::Plans::Create.call(title: "Demo", content:, user:, actor_type: "human") }
    let(:selection) { { width: 500, height: 200, x: 30, y: 15, w: 60, h: 20, label: "Retry" } }
    let(:form) { { source_token: @source_token, component_selection: selection.to_json, body_markdown: "Check this delay" } }

    before do
      sign_in_as(user)
      get plan_page_path(plan)
      @source_token = JSON.parse(Nokogiri::HTML.fragment(response.body).at_css("#retry button[data-source-target]")["data-source-target"]).fetch("token")
    end

    it "keeps the marked view with the original comment and serves it to the plan's readers and agents" do
      post plan_comment_threads_path(plan), params: { comment_thread: form.merge(component_snapshot: fixture_file_upload("sample.png", "image/png")) }
      comment = plan.comments.sole
      expect(comment.component_selection).to include("label" => "Retry", "image" => true, "revision" => plan.current_revision)
      get snapshot_plan_comment_thread_comment_path(plan, comment.comment_thread, comment)
      png = file_fixture("sample.png").binread
      expect(response.body.b).to eq(png)
      create(:api_token, user:, raw_token: "component-agent")
      headers = { "Authorization" => "Bearer component-agent" }
      get api_v1_plan_comment_path(plan, comment.comment_thread), headers: headers
      payload = response.parsed_body.fetch("comments").sole
      expect(payload.fetch("component_selection")).to include("label" => "Retry", "revision" => plan.current_revision)
      attachment = payload.fetch("attachments").sole
      expect(attachment).to include("type" => "component_snapshot", "content_type" => "image/png")
      get snapshot_api_v1_plan_path(plan), headers: headers
      expect(response.parsed_body.fetch("comment_threads").sole.fetch("comments").sole.fetch("attachments")).to eq([ attachment ])
      get attachment.fetch("download_url")
      expect(response).to have_http_status(:unauthorized)
      get attachment.fetch("download_url"), headers: headers
      expect(response.media_type).to eq("image/png")
      expect(response.body.b).to eq(png)
      other_plan = create(:plan, created_by_user: user)
      get api_v1_plan_comment_attachment_path(other_plan, comment, "component_snapshot"), headers: headers
      expect(response).to have_http_status(:not_found)
      comment.soft_delete!
      get api_v1_plan_comment_path(plan, comment.comment_thread), headers: headers
      deleted = response.parsed_body.fetch("comments").sole
      expect(deleted.fetch("body_markdown")).to eq(Coplan::Comment::DELETED_BODY)
      expect(deleted.fetch("attachments")).to be_empty
      expect(deleted).not_to have_key("component_selection")
      get attachment.fetch("download_url"), headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "keeps a failed image upload from posting a partial discussion" do
      allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError, "storage unavailable")
      expect {
        post plan_comment_threads_path(plan, format: :turbo_stream), params: { comment_thread: form.merge(component_snapshot: fixture_file_upload("sample.png", "image/png")) }
      }.to have_enqueued_job(ActiveStorage::PurgeJob)
      expect(response).to have_http_status(:service_unavailable)
      expect(plan.comment_threads).to be_empty
      expect(plan.comments).to be_empty
    end

    it "keeps the selection when the frame cannot supply an image" do
      post plan_comment_threads_path(plan), params: { comment_thread: form }
      comment = plan.comments.sole
      expect(comment.component_snapshot).not_to be_attached
      expect(comment.component_selection).to include("image" => false, "x" => selection[:x], "w" => selection[:w])
      create(:api_token, user:, raw_token: "selection-agent")
      get api_v1_plan_comment_path(plan, comment.comment_thread), headers: { "Authorization" => "Bearer selection-agent" }
      expect(response.parsed_body.fetch("comments").sole.fetch("attachments")).to be_empty
    end

    it "rejects an invalid image, coordinates, or an unsigned anchor without leaving an empty thread" do
      corrupt_png = file_fixture("sample.png").binread
      pixel_data = corrupt_png.index("IDAT") + 4
      corrupt_png.setbyte(pixel_data, corrupt_png.getbyte(pixel_data) ^ 1)
      invalid = [
        form.merge(component_snapshot: Rack::Test::UploadedFile.new(StringIO.new(corrupt_png), "image/png", original_filename: "corrupt.png")),
        form.merge(component_snapshot: fixture_file_upload("sample.txt", "image/png")),
        form.merge(component_selection: selection.merge(x: 499).to_json),
        form.merge(component_selection: selection.merge(label: { nested: [ "Retry" ] }).to_json),
        form.except(:source_token)
      ]
      invalid.each do |values|
        expect {
          post plan_comment_threads_path(plan, format: :turbo_stream), params: { comment_thread: values }
        }.not_to change(Coplan::CommentThread, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  it "keeps generated source inside its visible section when reading changes and replacing a section" do
    markdown = "# Demo\r\n\r\n## First\r\n\r\n::: {.component}\r\n\r\nroot.textContent = `\r\n~~~js\r\n## Later\r\n`;\r\n\r\n:::\r\n\r\n## Later\r\n\r\nKeep me."
    change = Coplan::Plans::ChangedSections.call(old_content: markdown, new_content: markdown.sub("~~~js", "~~~ruby"))
    expect(change.keys).to eq([ "first" ])
    expect(Coplan::Plans::ChangedSections.call(old_content: markdown, new_content: markdown.gsub("\r\n", "\n")).keys).to be_empty
    resolution = Coplan::Plans::PositionResolver.call(content: markdown, operation: { "op" => "replace_section", "heading" => "## Later", "new_content" => "New" })
    first, last = resolution.ranges.sole
    expect(markdown[first...last]).to eq("## Later\r\n\r\nKeep me.")
  end

  it "retains structural discussion targets after Markdown-looking component source" do
    markdown = "::: {.component}\n\nroot.textContent = `\n~~~js\nhello\n`;\n\n:::\n\n| Item |\n| --- |\n| Later |\n"
    ranges = Coplan::Plans::SourceTargets.new(markdown).ranges
    expect(ranges).to include([ "table_cell", markdown.index(" Later "), markdown.index(" Later ") + 7 ])
  end

  it "keeps source visible for an unknown library, conflicts, and disabled execution" do
    sign_in_as(user)
    catalog.library("diagram@2", source: "export const version = 2", example: "version")
    post preview_draft_plans_path, params: { content: content.sub("maths@1", "missing@1") }
    expect(response.body).to include("Unknown component library: missing@1", "diagram.node")
    expect(response.body).not_to include("<iframe")
    post preview_draft_plans_path, params: { content: content.sub("maths@1", "diagram@2") }
    expect(response.body).to include("Conflicting versions of diagram")
    allow(Coplan.configuration).to receive(:components_enabled).and_return(false)
    post preview_draft_plans_path, params: { content: }
    expect(response.body).to include("diagram.node")
    expect(response.body).not_to include("<iframe")
  end
end
