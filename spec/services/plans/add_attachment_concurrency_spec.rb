require "rails_helper"

RSpec.describe "Concurrent identical attachment uploads" do
  self.use_transactional_tests = false

  after do
    truncate_tables(*(ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata]))
  end

  it "keeps one attachment, blob, stored file, and event when uploads finish together" do
    user = create(:coplan_user)
    plan = create(:plan, created_by_user: user)
    ready, release = Queue.new, Queue.new
    allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_wrap_original do |method, **arguments|
      blob = method.call(**arguments)
      ready << blob
      release.pop
      blob
    end
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          file = Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/sample.png"), "image/png")
          CoPlan::Plans::AddAttachment.call(plan: CoPlan::Plan.find(plan.id), file: file, user: user)
        end
      end
    end
    blobs = Timeout.timeout(10) { 2.times.map { ready.pop } }
    2.times { release << true }
    workers.each { |worker| expect(worker.join(20)).to be_present }
    results = workers.map(&:value)

    expect(results).to all(be_success)
    expect(results.map { |result| result.attachment.id }.uniq.size).to eq(1)
    expect(results.count(&:reused?)).to eq(1)
    expect(plan.attachments.count).to eq(1)
    expect(ActiveStorage::Blob.count).to eq(1)
    expect(blobs.count { |blob| blob.service.exist?(blob.key) }).to eq(1)
    expect(plan.plan_events.where(event_type: "attachment_added").count).to eq(1)
  ensure
    2.times { release << true } if release
    workers&.each do |worker|
      worker.kill if worker.alive?
      worker.join
    end
  end
end
