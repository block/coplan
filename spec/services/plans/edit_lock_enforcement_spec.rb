require "rails_helper"

RSpec.describe "Content write lock enforcement" do
  let(:plan) { create(:plan) }
  let(:token) { SecureRandom.hex(32) }
  before { CoPlan::EditLease.acquire!(plan: plan, holder_type: "human", holder_id: plan.created_by_user_id, lease_token: token) }

  it "blocks whole content replacement, direct version creation, checkbox edits and session commits" do
    expect { CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Agent", base_revision: 1, actor_type: "local_agent", actor_id: nil) }.to raise_error(CoPlan::EditLease::Conflict)
    expect { create(:plan_version, plan: plan, revision: 2) }.to raise_error(CoPlan::EditLease::Conflict)
    expect { CoPlan::Plans::ToggleCheckbox.call(plan: plan, old_text: plan.current_content, new_text: "Toggled", base_revision: 1, actor_id: plan.created_by_user_id) }.to raise_error(CoPlan::EditLease::Conflict)
    session = create(:edit_session, plan: plan, base_revision: 1, draft_content: "Agent draft", operations_json: [ { "op" => "replace_exact", "old_text" => plan.current_content, "new_text" => "Agent draft" } ])
    expect { CoPlan::Plans::CommitSession.call(session: session) }.to raise_error(CoPlan::EditLease::Conflict)
    expect(session.reload).to be_open
    expect(plan.reload.current_revision).to eq(1)
  end

  it "blocks tokenless writes against a legacy empty-token lease" do
    plan.edit_lease.update!(lease_token_digest: Digest::SHA256.hexdigest(""))
    expect { CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Bypass", base_revision: 1, actor_type: "human", actor_id: plan.created_by_user_id) }.to raise_error(CoPlan::EditLease::Conflict)
    expect { create(:plan_version, plan: plan, revision: 2) }.to raise_error(CoPlan::EditLease::Conflict)
    expect(plan.reload.current_revision).to eq(1)
  end

  it "allows the holder, and permits another writer after expiry" do
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Human", base_revision: 1, actor_type: "human", actor_id: plan.created_by_user_id, lease_token: token)
    travel 6.minutes do
      CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "Agent", base_revision: 2, actor_type: "local_agent", actor_id: nil)
    end
    expect(plan.reload.current_content).to eq("Agent")
  end

  it "does not revive an expired lease by renewing it" do
    travel 6.minutes do
      expect { plan.edit_lease.renew!(lease_token: token) }.to raise_error(CoPlan::EditLease::Conflict)
    end
  end
end
