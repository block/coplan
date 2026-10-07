require "rails_helper"

RSpec.describe CoPlan::Comments::RefreshPreviews do
  let(:thread) { create(:comment_thread) }

  it "refreshes general previews with a requestless partial" do
    expect(CoPlan::Broadcaster).to receive(:replace_to).with(thread.plan,
      target: "plan-general-comments", partial: "coplan/plans/general_comments", locals: anything)
    expect(described_class.call(thread: thread).map { |preview| preview[:target] }).to eq([ "plan-general-comments" ])
  end

  it "refreshes displaced text previews after their comments change" do
    thread.update!(anchor_text: "Earlier wording", out_of_date: true)
    expect(CoPlan::Broadcaster).to receive(:replace_to).with(thread.plan,
      target: "plan-detached-comments", partial: "coplan/plans/detached_comments", locals: anything)
    expect(described_class.call(thread: thread).size).to eq(1)
  end

  it "leaves current inline threads to their existing popovers" do
    thread.update!(anchor_text: "Current wording")
    expect(CoPlan::Broadcaster).not_to receive(:replace_to)
    expect(described_class.call(thread: thread)).to be_empty
  end
end
