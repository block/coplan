require "cgi"
require "rails_helper"

RSpec.describe CoPlan::LinkPreviews do
  let(:base_url) { "https://coplan.example.test/app" }
  let(:plan) { create(:plan, :draft, summary: nil) }

  it "resolves canonical, history, and version URLs across every state without visibility policy" do
    expect(CoPlan::Plan).not_to receive(:visible_to)
    expect(CoPlan::PlanPolicy).not_to receive(:new)

    [
      { visibility: "draft", archived_at: nil },
      { visibility: "published", archived_at: nil },
      { visibility: "published", archived_at: Time.current }
    ].each do |state|
      plan.update!(state)
      version_id = plan.current_plan_version.id
      [
        "#{base_url}/plans/#{plan.id}?x=1#section",
        "#{base_url}/plans/#{plan.id}/history",
        "#{base_url}/plans/#{plan.id}/versions/#{version_id}/diff"
      ].each do |url|
        expect(described_class.resolve(url: url, base_url: base_url)&.external_id).to eq(plan.id)
      end
    end
  end

  it "resolves browsable URLs — canonical, edit, history, and version sub-pages" do
    expect(CoPlan::Plan).not_to receive(:visible_to)
    expect(CoPlan::PlanPolicy).not_to receive(:new)

    plan.update!(visibility: "published")
    plan.reload
    # url_path is "handle/slug" — the browsable address without a leading slash.
    path = plan.url_path
    expect(path).to be_present, "plan should have a browsable url_path"

    [
      "#{base_url}/#{path}",
      "#{base_url}/#{path}/edit",
      "#{base_url}/#{path}/history",
      "#{base_url}/#{path}/history/#{plan.current_plan_version.revision}",
      "#{base_url}/#{path}/history/#{plan.current_plan_version.revision}/diff"
    ].each do |url|
      resolved = described_class.resolve(url: url, base_url: base_url)
      expect(resolved&.external_id).to eq(plan.id),
        "expected #{url} to resolve to plan #{plan.id}, got #{resolved&.external_id.inspect}"
    end
  end

  it "emits a browsable canonical URL from for_plan instead of /plans/<id>" do
    plan.update!(visibility: "published")
    plan.reload

    preview = described_class.for_plan(plan, base_url: base_url)
    # The canonical URL should contain the plan's url_path (handle/slug),
    # not the legacy /plans/<id> path.
    expect(preview.canonical_url).to include("/#{plan.url_path}")
    expect(preview.canonical_url).not_to include("/plans/#{plan.id}")
  end

  it "does not treat reserved handles as browsable plan paths" do
    plan.update!(visibility: "published")
    plan.reload

    # /plans/<id> is a legacy path, not a browsable handle — "plans" is
    # in RESERVED_HANDLES, so a URL like /plans/something should only
    # resolve via the legacy matcher, not the browsable matcher.
    reserved_url = "#{base_url}/plans/#{plan.url_path.split('/').last}"
    expect(described_class.resolve(url: reserved_url, base_url: base_url)).to be_nil
  end

  it "resolves browsable URLs for plans whose slug is literally 'edit' or 'history'" do
    author = plan.created_by_user
    library = author.library

    edit_plan = create(:plan, :published, created_by_user: author, title: "Edit")
    create(:plan_placement, plan: edit_plan, folder: create(:folder, library: library, created_by_user: author))
    edit_plan.reload
    expect(edit_plan.slug).to eq("edit")

    # The full path /<handle>/<folder-slug>/edit is a valid plan URL,
    # not a sub-page action — resolve must find the plan, not strip "edit".
    url = "#{base_url}/#{edit_plan.url_path}"
    resolved = described_class.resolve(url: url, base_url: base_url)
    expect(resolved&.external_id).to eq(edit_plan.id)
  end

  it "encodes Unicode slugs in the canonical URL from for_plan" do
    author = plan.created_by_user
    library = author.library

    unicode_plan = create(:plan, :published, created_by_user: author, title: "信頼性向上ロードマップ")
    create(:plan_placement, plan: unicode_plan,
      folder: create(:folder, library: library, name: "プロジェクト", created_by_user: author))
    unicode_plan.reload

    # for_plan must not raise on Unicode url_path — it should percent-encode.
    expect { described_class.for_plan(unicode_plan, base_url: base_url) }.not_to raise_error
    preview = described_class.for_plan(unicode_plan, base_url: base_url)
    expect(preview.canonical_url).to start_with(base_url)
    # The URL should be valid and parseable.
    expect { URI.parse(preview.canonical_url) }.not_to raise_error
  end

  it "resolves percent-encoded browsable URLs for Unicode slugs" do
    author = plan.created_by_user
    library = author.library

    unicode_plan = create(:plan, :published, created_by_user: author, title: "信頼性向上ロードマップ")
    create(:plan_placement, plan: unicode_plan,
      folder: create(:folder, library: library, name: "プロジェクト", created_by_user: author))
    unicode_plan.reload

    # Slack sends percent-encoded URLs — simulate that here.
    encoded_path = unicode_plan.url_path.split("/").map { |s| CGI.escape(s) }.join("/")
    url = "#{base_url}/#{encoded_path}"

    resolved = described_class.resolve(url: url, base_url: base_url)
    expect(resolved&.external_id).to eq(unicode_plan.id)
  end

  it "rejects foreign origins, credentials, insecure hosts, mount lookalikes, bad IDs, and unsupported paths" do
    urls = [
      "https://other.test/app/plans/#{plan.id}",
      "https://user@coplan.example.test/app/plans/#{plan.id}",
      "http://coplan.example.test/app/plans/#{plan.id}",
      "#{base_url}2/plans/#{plan.id}",
      "#{base_url}/plans/not-a-uuid",
      "#{base_url}/plans/#{plan.id}/edit"
    ]
    urls.each { |url| expect(described_class.resolve(url: url, base_url: base_url)).to be_nil }
    expect(described_class.resolve(url: "#{base_url}/plans/#{SecureRandom.uuid}", base_url: base_url)).to be_nil
  end

  it "flags Private and Archived in the context; published plans stay unmarked" do
    expect(described_class.for_plan(plan, base_url: base_url).context).to start_with("Private · ")

    plan.update!(visibility: "published")
    published_context = described_class.for_plan(plan.reload, base_url: base_url).context
    expect(published_context).not_to include("Private")
    expect(published_context).to include("by #{plan.created_by_user.name}")

    plan.update!(archived_at: Time.current)
    expect(described_class.for_plan(plan.reload, base_url: base_url).context).to start_with("Archived · ")
  end

  it "prefers summary, otherwise strips and truncates markdown, and keys on content SHA" do
    plan.update!(summary: "Generated summary")
    expect(described_class.for_plan(plan, base_url: base_url).description).to eq("Generated summary")

    plan.update!(summary: nil)
    plan.current_plan_version.update!(content_markdown: "# Heading\n\n#{"word " * 80}", content_sha256: nil)
    first = described_class.for_plan(plan.reload, base_url: base_url)
    expect(first.description.length).to be <= 240
    expect(first.description).not_to include("#")

    plan.current_plan_version.update!(content_markdown: "Changed", content_sha256: nil)
    expect(described_class.for_plan(plan.reload, base_url: base_url).cache_key).not_to eq(first.cache_key)
  end

  it "changes its cache key when preview metadata changes" do
    first = described_class.for_plan(plan, base_url: base_url)
    plan.update!(title: "A new title")
    expect(described_class.for_plan(plan.reload, base_url: base_url).cache_key).not_to eq(first.cache_key)
  end

  it "only includes HTTPS image URLs" do
    plan.update!(metadata: { "image_url" => "http://example.test/image.png" })
    expect(described_class.for_plan(plan, base_url: base_url).image_url).to be_nil

    plan.update!(metadata: { "image_url" => "https://example.test/image.png" })
    expect(described_class.for_plan(plan, base_url: base_url).image_url).to eq("https://example.test/image.png")
  end

  it "includes the author's identity with a safe avatar URL" do
    plan.created_by_user.update!(name: "Ada Lovelace", avatar_url: "https://example.test/ada.png")

    preview = described_class.for_plan(plan.reload, base_url: base_url)

    expect(preview.author_name).to eq("Ada Lovelace")
    expect(preview.author_avatar_url).to eq("https://example.test/ada.png")

    plan.created_by_user.update!(avatar_url: "http://example.test/ada.png")
    expect(described_class.for_plan(plan.reload, base_url: base_url).author_avatar_url).to be_nil
  end
end
