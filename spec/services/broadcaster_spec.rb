require "rails_helper"

RSpec.describe CoPlan::Broadcaster do
  let(:author) { create(:coplan_user) }
  let(:plan) do
    p = CoPlan::Plan.create!(title: "Test Plan", created_by_user: author)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: "# Hello world\n\nSome content here.",
      actor_type: "human", actor_id: author.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  describe ".replace_plan_content" do
    # Ensure plan is built BEFORE we start spying, so setup-time broadcasts
    # (from CoPlan::Plan.create! / CoPlan::PlanVersion.create!) don't pollute
    # the captured payloads.
    before { plan }

    it "broadcasts a custom turbo-stream action targeting #plan-content-body" do
      payloads = []
      allow(Turbo::StreamsChannel).to receive(:broadcast_stream_to) do |_streamable, content:|
        payloads << content.to_s
      end

      described_class.replace_plan_content(plan)

      expect(payloads.size).to eq(1)
      expect(payloads.first).to include('action="coplan-replace-if-clean"')
      expect(payloads.first).to include('target="plan-content-body"')
      expect(payloads.first).to include('data-revision="1"')
      # The fresh markdown render is wrapped in a <template>
      expect(payloads.first).to include("<template>")
      expect(payloads.first).to include("Hello world")
    end

    it "reflects the latest revision so stale-tab clients can ignore self-broadcasts" do
      version2 = CoPlan::PlanVersion.create!(
        plan: plan, revision: 2,
        content_markdown: "# Updated\n\nMore content.",
        actor_type: "local_agent", actor_id: author.id
      )
      plan.update!(current_plan_version: version2, current_revision: 2)

      payloads = []
      allow(Turbo::StreamsChannel).to receive(:broadcast_stream_to) do |_, content:|
        payloads << content.to_s
      end

      described_class.replace_plan_content(plan.reload)

      expect(payloads.first).to include('data-revision="2"')
      expect(payloads.first).to include("Updated")
    end
  end
end
