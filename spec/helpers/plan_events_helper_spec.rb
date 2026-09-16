require "rails_helper"

RSpec.describe CoPlan::PlanEventsHelper, type: :helper do
  it "summarizes touched files without rendering the stored path inventory" do
    event = build(:plan_event,
      event_type: "touched_files_changed",
      before_value: "1",
      after_value: "3",
      metadata: { "repositories" => [ "squareup/java", "squareup/web" ] })

    expect(helper.render_event_summary(event)).to eq(
      "Updated touched files — 3 files across squareup/java and squareup/web"
    )
  end
end
