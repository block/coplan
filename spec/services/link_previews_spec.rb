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
end
