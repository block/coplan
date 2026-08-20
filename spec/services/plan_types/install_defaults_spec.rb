require "rails_helper"

RSpec.describe CoPlan::PlanTypes::InstallDefaults do
  # The database may already contain plan types when the suite runs — the PG
  # CI job seeds before rspec, and a data migration installs General. These
  # examples are about what the installer does from a known starting state,
  # so start from a clean table. Transactional fixtures roll the delete back.
  before { CoPlan::PlanType.delete_all }

  describe "the shipped defaults" do
    it "creates the full default set on a fresh install" do
      result = described_class.call

      expect(result.created).to include(
        "Engineering Design", "Exploration", "PRD", "Project 1-Pager",
        "Research", "Technical Documentation", "Implementation Plan",
        "Test Plan", "Handoff", "Scratchpad", "General", "Slideshow"
      )
      expect(CoPlan::PlanType.count).to eq(result.created.size)

      design = CoPlan::PlanType.find_by_name("Engineering Design")
      expect(design.description).to include("decision")
      expect(design.template_content).to include("## Alternatives considered")
      expect(design.icon).to eq("scroll")

      # The catch-alls deliberately ship without templates.
      expect(CoPlan::PlanType.find_by_name("Scratchpad").template_content).to be_nil
      expect(CoPlan::PlanType.find_by_name("General").template_content).to be_nil
    end

    it "installs behavior from front matter, defaulting to document" do
      described_class.call

      slideshow = CoPlan::PlanType.find_by_name("Slideshow")
      expect(slideshow.behavior).to eq("slideshow")
      expect(slideshow.template_content).to include("---")
      expect(CoPlan::PlanType.find_by_name("Research").behavior).to eq("document")
    end

    it "is idempotent" do
      described_class.call
      result = described_class.call

      expect(result.created).to be_empty
      expect(result.updated).to be_empty
      expect(result.skipped).not_to be_empty
    end

    it "fills blank fields on existing types without touching edited ones" do
      # A pre-templates instance: type exists with a custom description and
      # no template (Square's situation before this shipped).
      create(:plan_type, name: "Research", description: "Hand-written description", template_content: nil, icon: nil)

      result = described_class.call

      research = CoPlan::PlanType.find_by_name("Research")
      expect(result.updated).to include("Research")
      expect(research.description).to eq("Hand-written description")
      expect(research.template_content).to include("## Findings")
      expect(research.icon).to eq("flask")
    end

    it "matches existing types case-insensitively" do
      create(:plan_type, name: "handoff", description: "custom", template_content: nil)

      result = described_class.call

      expect(result.created).not_to include("Handoff")
      expect(CoPlan::PlanType.find_by_name("Handoff").description).to eq("custom")
    end

    it "overwrites edited fields with force" do
      create(:plan_type, name: "Research", description: "Hand-written description", template_content: "custom template")

      described_class.call(force: true)

      research = CoPlan::PlanType.find_by_name("Research")
      expect(research.description).not_to eq("Hand-written description")
      expect(research.template_content).to include("## Findings")
    end

    it "restores blank shipped values with force" do
      # Scratchpad deliberately ships without a template; force means "back
      # to the shipped defaults", so a custom template must be cleared too.
      create(:plan_type, name: "Scratchpad", template_content: "custom template", default_tags: ["wip"])

      described_class.call(force: true)

      scratchpad = CoPlan::PlanType.find_by_name("Scratchpad")
      expect(scratchpad.template_content).to be_nil
      expect(scratchpad.default_tags).to eq([])
    end

    it "never touches types the defaults don't know about" do
      custom = create(:plan_type, name: "Marketing Pitch", description: "Sell it", template_content: "persuade")

      described_class.call(force: true)

      expect(custom.reload).to have_attributes(description: "Sell it", template_content: "persuade")
    end
  end

  describe "parsing" do
    it "raises on a defaults file without front matter" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "broken.md"), "no front matter here")

        expect { described_class.call(dir: dir) }.to raise_error(ArgumentError, /front matter/)
      end
    end
  end
end
