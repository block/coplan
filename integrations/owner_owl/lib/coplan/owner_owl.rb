require "coplan"
require "coplan/owner_owl/version"
require "coplan/owner_owl/client"
require "coplan/owner_owl/router"

module CoPlan
  module OwnerOwl
    def self.install!(http_client:, endpoint: Client::ENDPOINT)
      client = Client.new(http_client:, endpoint:)
      CoPlan.configuration.approval_router = Router.new(client:)
    end
  end
end
