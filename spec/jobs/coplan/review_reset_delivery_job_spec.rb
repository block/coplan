require "rails_helper"

RSpec.describe Coplan::ReviewResetDeliveryJob, type: :job do
  let(:plan) { create(:plan, :published) }
  let!(:task) { Coplan::Reviews::Request.call(plan: plan, reviewer: create(:coplan_user), actor: plan.created_by_user) }

  it "retries a transient delivery failure for a still-pending request" do
    allow(Coplan::Reviews::Changed).to receive(:call).and_raise(IOError, "temporary failure")
    expect {
      described_class.perform_now(request_id: task.id, generation: task.generation, revision: 1)
    }.to have_enqueued_job(described_class)
  end

  it "ignores deliveries for older generations and removed requests" do
    allow(Coplan::Reviews::Changed).to receive(:call)
    described_class.perform_now(request_id: task.id, generation: task.generation - 1, revision: 1)
    task.destroy!
    described_class.perform_now(request_id: task.id, generation: task.generation, revision: 1)
    expect(Coplan::Reviews::Changed).not_to have_received(:call)
  end

  it "ignores a reset delivery after a fresh decision" do
    Coplan::Reviews::Respond.call(request: task, actor: task.reviewer, revision: 1,
      generation: task.generation, decision: "approved")
    allow(Coplan::Reviews::Changed).to receive(:call)
    described_class.perform_now(request_id: task.id, generation: task.generation, revision: 1)
    expect(Coplan::Reviews::Changed).not_to have_received(:call)
  end

  it "retries controls transport failures and ignores missing plans" do
    allow(Coplan::Broadcaster).to receive(:custom_action_to).and_raise(IOError, "temporary transport failure")
    expect { described_class.perform_now(plan_id: plan.id) }.to have_enqueued_job(described_class).with(plan_id: plan.id)
    described_class.perform_now(plan_id: SecureRandom.uuid)
    expect(Coplan::Broadcaster).to have_received(:custom_action_to).once
  end
end
