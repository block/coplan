require "rails_helper"

RSpec.describe "Agent review event prompts" do
  # Evaluate only the actual formatter, not each executable's connection loop.
  # Both tools are downloaded as standalone scripts with no Rails dependency.
  def format_event(tool, method, event)
    source = Rails.root.join("engine/agent_tools", tool).read
    formatter = source[/^def #{method}\(event\)\n.*?^end$/m]
    raise "Missing formatter #{method}" unless formatter

    klass = Class.new
    klass.const_set(:BASE, "https://coplan.example")
    klass.class_eval(formatter, tool)
    klass.new.public_send(method, event)
  end

  { "coplan-attach" => "brief", "coplan-bridge" => "wake_prompt" }.each do |tool, method|
    %w[requested requirement_changed withdrawn].each do |action|
      it "shows #{action} review data in #{tool} without directing a document edit" do
        event = { "type" => "review.requested", "plan_id" => "plan",
                  "payload" => { "action" => action, "requirement" => "optional", "review_request_id" => "review" } }
        prompt = format_event(tool, method, event)
        expect(prompt).to include('"action":"' + action + '"', '"review_request_id":"review"', "/agent-instructions/comments")
        expect(prompt).not_to include("then apply any edit")
      end
    end

    it "shows a completed decision in #{tool} without directing a document edit" do
      event = { "type" => "review.responded", "plan_id" => "plan",
                "payload" => { "decision" => "approved", "revision" => 4 } }
      prompt = format_event(tool, method, event)
      expect(prompt).to include('"decision":"approved"', '"revision":4', "/agent-instructions/comments")
      expect(prompt).not_to include("then apply any edit")
    end

    it "retains comment collaboration instructions in #{tool}" do
      event = { "type" => "comment.created", "plan_id" => "plan", "comment_thread_id" => "thread",
                "payload" => { "comment_author" => "Reviewer", "comment_body" => "Please clarify" } }
      expect(format_event(tool, method, event)).to include("then apply any edit")
    end
  end
end
