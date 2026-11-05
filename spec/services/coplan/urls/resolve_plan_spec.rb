require "rails_helper"

RSpec.describe CoPlan::Urls::ResolvePlan do
  let(:plan) { create(:plan) }
  let(:base) { "https://coplan.example/coplan/" }

  it "rejects different mount prefixes and URL credentials" do
    [ "https://coplan.example/coplan-other/", "https://user@coplan.example/coplan/" ].each do |prefix|
      expect(described_class.call(url: "#{prefix}#{plan.url_path}", bases: [ base ])).to be_nil
    end
  end

  it "resolves encoded paths with query strings and fragments" do
    encoded = plan.url_path.sub("/", "%2F")
    expect(described_class.call(url: "#{base}#{encoded}?view=read#comment", bases: [ base ])).to eq(plan)
  end

  it "does not mistake a library or folder for a document" do
    folder = create(:folder, library: plan.created_by_user.library)
    [ folder.library.handle, "#{folder.library.handle}/#{folder.slug}" ].each do |path|
      expect(described_class.call(url: "#{base}#{path}", bases: [ base ])).to be_nil
    end
  end

  it "follows a plan moved into a folder" do
    old_path = plan.url_path
    folder = create(:folder, library: plan.created_by_user.library)
    CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: plan.created_by_user)
    expect(described_class.call(url: "#{base}#{old_path}", bases: [ base ])).to eq(plan)
  end

  it "treats invalid percent-encoded text as an unknown address" do
    expect(described_class.call(url: "#{base}%FF/bad", bases: [ base ])).to be_nil
  end
end
