module CoPlan
  module Api
    module V1
      class EmbedDomainsController < BaseController
        def index
          render json: { hostnames: EmbedDomain.order(:hostname).pluck(:hostname) }
        end
      end
    end
  end
end
