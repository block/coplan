require "rails_helper"
require_relative "../../../integrations/owner_owl/lib/coplan/owner_owl/router"

RSpec.describe CoPlan::OwnerOwl::Router do
  let(:client) { double("client") }
  let(:plan) { double("plan", id: "plan-123") }
  let(:team) do
    {
      "type" => "Team", "id" => "payments", "members" => [
        { "type" => "User", "id" => "alice" },
        { "type" => "User", "id" => "bob" },
        { "type" => "User", "id" => "author" }
      ]
    }
  end
  let(:response) do
    {
      "sha" => "abc123",
      "results" => [
        {
          "path" => "payments/a.rb",
          "requested_reviewers" => [
            {
              "source" => "payments/OWNERS.yaml", "pathspec" => "payments/",
              "principals" => [ "payments" ], "expanded_principals" => [ team ], "round_robin" => 2
            }
          ],
          "policies" => []
        },
        {
          "path" => "payments/b.rb",
          "requested_reviewers" => [
            {
              "source" => "payments/OWNERS.yaml", "pathspec" => "payments/",
              "principals" => [ "payments" ], "expanded_principals" => [ team ], "round_robin" => 2
            }
          ],
          "policies" => []
        }
      ]
    }
  end

  it "groups identical path routes, honors the reviewer count, and excludes the author" do
    expect(client).to receive(:ownership).with(
      repo: "squareup/example", ref: "main", paths: [ "payments/a.rb", "payments/b.rb" ]
    ).and_return(response)

    routes = described_class.new(client:).call(
      plan:, author_identity: "author", touched_files: [
        { "repo" => "squareup/example", "ref" => "main", "path" => "payments/a.rb" },
        { "repo" => "squareup/example", "ref" => "main", "path" => "payments/b.rb" }
      ]
    )

    expect(routes.map { |route| route[:identity] }).to contain_exactly("alice", "bob")
    expect(routes.map { |route| route.dig(:metadata, "paths") }.uniq).to eq([ [ "payments/a.rb", "payments/b.rb" ] ])
  end

  it "honors an explicit zero reviewer count" do
    response["results"].each { |result| result["requested_reviewers"].first["round_robin"] = 0 }
    allow(client).to receive(:ownership).and_return(response)

    routes = described_class.new(client:).call(
      plan:, author_identity: "author",
      touched_files: [ { "repo" => "squareup/example", "ref" => "main", "path" => "payments/a.rb" } ]
    )

    expect(routes).to be_empty
  end
end
