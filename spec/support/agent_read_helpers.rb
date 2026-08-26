# The API refuses an agent write when a person has hand-edited a plan since
# that credential last read it (CoPlan::Plans::HumanEditGuard). The plan
# factory builds revision 1 as a human version, so every spec that writes
# through the agent API has to satisfy the fence. In real life an agent
# satisfies it by reading the plan first, which is exactly what this does.
module AgentReadHelpers
  def agent_has_read(plan, token, revision: nil)
    CoPlan::PlanRead.record!(
      plan: plan,
      reader_type: "api_token",
      reader_id: token.id,
      revision: revision || plan.reload.current_revision
    )
  end
end

RSpec.configure do |config|
  config.include AgentReadHelpers
end
