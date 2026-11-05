require "rails_helper"

RSpec.describe "Concurrent review and content commits" do
  self.use_transactional_tests = false

  after do
    truncate_tables(*(ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata]))
  end

  def threaded(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
  end

  [ true, false ].each do |reset|
    it "makes evidence and stale responses wait for a complete edit with resets=#{reset}" do
      owner = create(:coplan_user)
      reviewer = create(:coplan_user)
      plan = CoPlan::Plans::Create.call(title: "Concurrent review", content: "Before", user: owner)
      plan.update!(reset_reviews_on_change: reset)
      task = CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: owner)
      first = CoPlan::Reviews::Respond.call(request: task, actor: reviewer, revision: 1, generation: 1, decision: "approved")
      edited, release, attempting = Queue.new, Queue.new, Queue.new
      writer = threaded do
        local = CoPlan::Plan.find(plan.id)
        local.with_lock do
          CoPlan::Plans::ReplaceContent.call(plan: local, new_content: "After", base_revision: 1, actor_type: "human", actor_id: owner.id)
          edited << true
          release.pop
        end
      end
      Timeout.timeout(10) { edited.pop }
      reader = threaded do
        attempting << true
        CoPlan::Reviews::Evidence.call(plan: CoPlan::Plan.find(plan.id))
      end
      responder = threaded do
        attempting << true
        begin
          CoPlan::Reviews::Respond.call(request: CoPlan::ReviewRequest.find(task.id), actor: reviewer,
            revision: 1, generation: 1, decision: "approved", idempotency_key: SecureRandom.uuid)
        rescue CoPlan::Reviews::Respond::Conflict => error
          error.code
        end
      end
      Timeout.timeout(10) { 2.times { attempting.pop } }
      expect(reader).to be_alive
      expect(responder).to be_alive
      release << true
      [ writer, reader, responder ].each { |thread| expect(thread.join(20)).to be_present }
      evidence = reader.value
      expect(evidence[:version]).to include(revision: 2, content_markdown: "After")
      expect(evidence[:review_requests].first).to include(status: reset ? "pending" : "approved", effective_response_id: nil, generation: reset ? 2 : 1)
      expect(evidence[:review_sequence]).to eq(first.decision_sequence + 1)
      expect(responder.value).to eq("review_version_changed")
      expect(task.reload.review_responses.pluck(:id)).to eq([ first.id ])
    ensure
      release << true if release
      [ writer, reader, responder ].compact.each { |thread| thread.kill if thread.alive? }
    end
  end

  it "serializes two same-time decisions with unique increasing server sequences" do
    owner = create(:coplan_user)
    reviewer = create(:coplan_user)
    plan = CoPlan::Plans::Create.call(title: "Decision race", content: "Reviewed", user: owner)
    task = CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: owner)
    ready, start = Queue.new, Queue.new
    threads = 2.times.map do |index|
      threaded do
        ready << true
        start.pop
        CoPlan::Reviews::Respond.call(request: CoPlan::ReviewRequest.find(task.id), actor: reviewer,
          revision: 1, generation: 1, decision: index.zero? ? "approved" : "changes_requested",
          note: index.zero? ? nil : "Please clarify", idempotency_key: SecureRandom.uuid)
      end
    end
    Timeout.timeout(10) { 2.times { ready.pop } }
    2.times { start << true }
    threads.each { |thread| expect(thread.join(20)).to be_present }
    responses = threads.map(&:value).sort_by(&:decision_sequence)
    expect(responses.last.decision_sequence).to eq(responses.first.decision_sequence + 1)
    expect(task.reload.effective_response).to eq(responses.last)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end
end
