require "rails_helper"
require "rake"

RSpec.describe "coplan:summaries:backfill", type: :task do
  include ActiveJob::TestHelper

  subject(:run_task) { Rake::Task["coplan:summaries:backfill"].tap(&:reenable).invoke }

  around do |example|
    previous_application = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load CoPlan::Engine.root.join("lib/tasks/coplan_summaries.rake").to_s
    example.run
  ensure
    Rake.application = previous_application
  end

  before { clear_enqueued_jobs }

  it "enqueues SummarizePlanJob for summary-less plans with a current version" do
    plan = create(:plan)

    expect { run_task }.to have_enqueued_job(CoPlan::SummarizePlanJob).with(plan_id: plan.id)
  end

  it "skips plans that already have a summary" do
    create(:plan).update_columns(summary: "Already summarized.")

    expect { run_task }.not_to have_enqueued_job(CoPlan::SummarizePlanJob)
  end

  it "skips plans with no current_plan_version" do
    create(:plan).update_columns(current_plan_version_id: nil)

    expect { run_task }.not_to have_enqueued_job(CoPlan::SummarizePlanJob)
  end

  it "enqueues only the eligible plans when mixed" do
    eligible = create(:plan)
    create(:plan).update_columns(summary: "Has one.")
    create(:plan).update_columns(current_plan_version_id: nil)

    # Plan creation enqueues its own SummarizePlanJob (PlanVersion
    # after_create_commit); clear those so we observe only the task's.
    clear_enqueued_jobs
    run_task

    expect(enqueued_jobs.map { |job| job[:args].first["plan_id"] }).to eq([eligible.id])
  end

  it "falls back to defaults when BATCH_SIZE/INTERVAL are blank" do
    plan = create(:plan)
    ENV["BATCH_SIZE"] = ""
    ENV["INTERVAL"] = ""

    expect { run_task }.to have_enqueued_job(CoPlan::SummarizePlanJob).with(plan_id: plan.id)
  ensure
    ENV.delete("BATCH_SIZE")
    ENV.delete("INTERVAL")
  end
end
