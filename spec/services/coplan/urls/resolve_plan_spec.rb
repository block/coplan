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

  it "follows aliases beyond one rewrite batch" do
    old_path = "old-library/old-plan"
    paths = [ old_path ] + (1..(CoPlan::UrlAlias::MAX_HOPS + 1)).map { |n| "old-library/plan-#{n}" } + [ plan.url_path ]
    paths.each_cons(2) { |from, to| CoPlan::UrlAlias.record!(from: from, to: to) }

    expect(described_class.call(url: "#{base}#{old_path}", bases: [ base ])).to eq(plan)
  end

  it "stops on cyclic aliases" do
    CoPlan::UrlAlias.record!(from: "old-library/one", to: "old-library/two")
    CoPlan::UrlAlias.record!(from: "old-library/two", to: "old-library/one")

    expect(described_class.call(url: "#{base}old-library/one", bases: [ base ])).to be_nil
  end

  it "bounds redirect traversal even when no path repeats" do
    calls = 0
    allow(CoPlan::Urls::Resolve).to receive(:call) do
      calls += 1
      CoPlan::Urls::Resolve::Result.new(redirect_to_path: "library/plan-#{calls}")
    end

    expect(described_class.call(url: "#{base}library/start", bases: [ base ])).to be_nil
    expect(calls).to eq(described_class::MAX_REDIRECTS)
  end

  it "treats invalid percent-encoded text as an unknown address" do
    expect(described_class.call(url: "#{base}%FF/bad", bases: [ base ])).to be_nil
  end
end
