require "rails_helper"
require_relative "../../../integrations/owner_owl/lib/coplan/owner_owl/client"

RSpec.describe CoPlan::OwnerOwl::Client do
  Response = Struct.new(:code, :body)

  it "requests expanded v2 ownership for the supplied paths" do
    http = double("http")
    body = { "sha" => "abc", "results" => [ { "path" => "foo.rb", "requested_reviewers" => [], "policies" => [] } ] }
    expect(http).to receive(:post) do |path, json, headers|
      expect(path).to eq("/api/v2/")
      expect(JSON.parse(json)).to include(
        "repo" => "squareup/example", "ref" => "main", "paths" => [ "foo.rb" ],
        "options" => include("expandTeams" => true)
      )
      expect(headers).to eq("Content-Type" => "application/json")
      Response.new("200", JSON.generate(body))
    end

    expect(described_class.new(http_client: http).ownership(repo: "squareup/example", ref: "main", paths: [ "foo.rb" ])).to eq(body)
  end

  it "raises a typed error with the Ownership API message" do
    http = double("http", post: Response.new("503", JSON.generate("message" => "try again")))

    expect {
      described_class.new(http_client: http).ownership(repo: "squareup/example", ref: "main", paths: [ "foo.rb" ])
    }.to raise_error(CoPlan::OwnerOwl::Client::Error, "try again")
  end
end
