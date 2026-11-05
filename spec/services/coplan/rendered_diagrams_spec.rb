require "rails_helper"

RSpec.describe CoPlan::RenderedDiagrams do
  def fence(source, image: "/rails/active_storage/blobs/a/flow.png", renderer: "graphviz")
    "```#{renderer} {image=\"#{image}\" alt=\"Flow\"}\n#{source}\n```\n"
  end

  describe ".parse_info" do
    it "reads the renderer, image, alt text, width and source language, and names the skill after the renderer" do
      expect(described_class.parse_info('draw-diagram {image="/x/flow.png" alt="Checkout flow" width=640 lang=javascript}'))
        .to eq(renderer: "draw-diagram", image: "/x/flow.png", alt: "Checkout flow", width: "640", lang: "javascript",
          skill: "draw-diagram", skill_source: nil)
    end

    it "reads a skill named apart from the renderer, and where to find it" do
      info = described_class.parse_info('dot {image=/x/a.png skill="acme:graphviz" skill-source="https://skills.example.com/graphviz"}')

      expect(info).to include(renderer: "dot", skill: "acme:graphviz", skill_source: "https://skills.example.com/graphviz")
    end

    it "allows braces inside quoted values" do
      expect(described_class.parse_info('graphviz {image="/x/a.png" alt="Config {a, b} flow"}')).to include(alt: "Config {a, b} flow")
    end

    it "doesn't let the source be highlighted as a language CoPlan draws itself" do
      expect(described_class.parse_info('draw-diagram {image="/x/a.png" lang=mermaid}')).to include(lang: nil)
    end

    it "ignores attributes it can't use safely" do
      expect(described_class.parse_info('graphviz {image=https://cdn.example.com/a.png width=100% lang="a b" skill="x y" skill-source="javascript:alert(1)"}'))
        .to eq(renderer: "graphviz", image: "https://cdn.example.com/a.png", alt: "", width: nil, lang: nil,
          skill: "graphviz", skill_source: nil)
    end

    it "is nil for ordinary code fences and unsafe or missing images" do
      [ "ruby", "graphviz", "graphviz {alt=\"No image\"}", 'graphviz {image="javascript:alert(1)"}',
        'graphviz {image="//evil.example/a.png"}', 'graphviz {image="/\\evil.example/a.png"}',
        'graphviz {image="data:image/png;base64,AAAA"}', 'mermaid {image="/x/flow.png"}',
        # Commonmarker only splits the info string at a space.
        'graphviz{image="/x/flow.png"}', 'c4/plantuml {image="/x/flow.png"}', nil ].each do |info|
        expect(described_class.parse_info(info)).to be_nil, info.inspect
      end
    end
  end

  describe ".blocks" do
    it "finds rendered diagram fences with their source and skips other code" do
      markdown = "# Plan\n\n#{fence("digraph { a -> b }")}\n```ruby\nputs 1\n```\n"

      expect(described_class.blocks(markdown)).to eq([
        described_class::Block.new(renderer: "graphviz", image: "/rails/active_storage/blobs/a/flow.png",
          alt: "Flow", width: nil, lang: nil, skill: "graphviz", skill_source: nil, source: "digraph { a -> b }\n")
      ])
      expect(described_class.blocks("```ruby\nputs 1\n```")).to eq([])
      expect(described_class.blocks(nil)).to eq([])
    end
  end

  describe ".stale_images" do
    let(:user) { create(:coplan_user) }

    def edit(plan, content)
      CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content,
        base_revision: plan.current_revision, actor_type: "human", actor_id: user.id)
      plan.reload
    end

    it "marks an image whose source changed after it went in, until a new image replaces it" do
      plan = CoPlan::Plans::Create.call(title: "Diagram", content: "# Diagram\n\n#{fence("digraph { a -> b }")}", user: user)
      expect(described_class.stale_images(plan)).to be_empty

      plan = edit(plan, "# Diagram\n\nIntro.\n\n#{fence("digraph { a -> b }")}")
      expect(described_class.stale_images(plan)).to be_empty

      plan = edit(plan, "# Diagram\n\nIntro.\n\n#{fence("digraph { a -> c }")}")
      expect(described_class.stale_images(plan)).to eq(Set["/rails/active_storage/blobs/a/flow.png"])

      plan = edit(plan, "# Diagram\n\nIntro.\n\n#{fence("digraph { a -> c }", image: "/rails/active_storage/blobs/b/flow.png")}")
      expect(described_class.stale_images(plan)).to be_empty
    end

    it "matches an image URL literally, not as a LIKE pattern" do
      plan = CoPlan::Plans::Create.call(title: "Diagram", content: fence("a", image: "/x/a%b_c.png"), user: user)
      plan = edit(plan, fence("b", image: "/x/a%b_c.png"))

      expect(described_class.stale_images(plan)).to eq(Set["/x/a%b_c.png"])
    end
  end
end
