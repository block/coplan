require "rails_helper"

RSpec.describe CoPlan::ReferencesHelper, type: :helper do
  describe "#plan_citation_back_matter" do
    let(:user) { create(:coplan_user) }
    let(:plan) do
      plan = CoPlan::Plan.create!(title: "Sourced plan", created_by_user: user)
      version = CoPlan::PlanVersion.create!(
        plan: plan,
        revision: 1,
        content_markdown: <<~MARKDOWN,
          This decision is evidence-based.[^experiment]

          [^experiment]: A 30-day production sample supported it. [Study](https://docs.google.com/spreadsheets/d/sample).
        MARKDOWN
        actor_type: "human",
        actor_id: user.id
      )
      plan.update!(current_plan_version: version, current_revision: 1)
      plan
    end

    it "joins Markdown citation context to structured source identity" do
      reference = plan.references.find_by!(url: "https://docs.google.com/spreadsheets/d/sample")
      reference.update!(title: "Rollout experiment results")

      result = helper.plan_citation_back_matter(plan, plan.references.reload)
      doc = Nokogiri::HTML::DocumentFragment.parse(result[:html])
      source = doc.at_css("a.citation-source")

      expect(result[:count]).to eq(1)
      expect(result[:cited_urls]).to contain_exactly(reference.url)
      expect(doc.at_css(".reference-citations")).to be_present
      expect(doc.at_css(".footnotes-title")).to be_nil
      expect(doc.text).to include("A 30-day production sample supported it.")
      expect(source["target"]).to eq("_blank")
      expect(source["rel"]).to eq("noopener noreferrer")
      expect(source["class"]).to include("citation-source--block")
      expect(source.at_css(".citation-source__title").text).to eq("Rollout experiment results")
      expect(source.at_css(".citation-source__meta").text).to eq("Google Sheet · docs.google.com ↗")
    end

    it "keeps a source link inline when prose follows it" do
      version = CoPlan::PlanVersion.create!(
        plan: plan,
        revision: 2,
        content_markdown: "Claim.[^inline]\n\n[^inline]: The [study](https://example.com/study) informed this decision.",
        actor_type: "human",
        actor_id: user.id
      )
      plan.update!(current_plan_version: version, current_revision: 2)

      result = helper.plan_citation_back_matter(plan, plan.references.reload)
      source = Nokogiri::HTML::DocumentFragment.parse(result[:html]).at_css("a.citation-source")

      expect(source["class"]).to include("citation-source--inline")
      expect(source.text).to eq("study")
      expect(source["title"]).to eq("Website · example.com")
    end

    it "lists uncited resources without repeating cited resources" do
      cited = plan.references.first
      uncited = create(:reference, plan: plan, url: "https://github.com/block/coplan", source: "extracted")
      explicit = create(:reference, plan: plan, url: cited.url.sub("sample", "curated"), source: "explicit")
      cited.update!(source: "explicit")

      listed = helper.listed_plan_references(plan.references.reload, Set[cited.url])

      expect(listed).to contain_exactly(uncited, explicit)
    end
  end

  describe "#reference_type_label" do
    it "identifies useful document and publisher types from the URL" do
      expect(helper.reference_type_label("document", "https://docs.google.com/document/d/1")).to eq("Google Doc")
      expect(helper.reference_type_label("document", "https://docs.google.com/presentation/d/1")).to eq("Google Slides")
      expect(helper.reference_type_label("link", "https://www.usda.gov/topics")).to eq("Government website")
    end
  end
end
