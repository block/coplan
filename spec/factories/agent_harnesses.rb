FactoryBot.define do
  factory :agent_harness, class: "CoPlan::AgentHarness" do
    sequence(:key) { |n| "agent-harness-#{n}" }
    sequence(:display_name) { |n| "Agent Harness #{n}" }
  end
end
