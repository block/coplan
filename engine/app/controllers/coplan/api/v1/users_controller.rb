module CoPlan
  module Api
    module V1
      class UsersController < BaseController
        def search
          query = params[:q].to_s.strip
          if query.blank?
            return render json: []
          end

          users = if CoPlan.configuration.user_search
            CoPlan.configuration.user_search.call(query)
          else
            sanitized = CoPlan::User.sanitize_sql_like(query)
            CoPlan::User
              .where("name LIKE :q OR email LIKE :q", q: "%#{sanitized}%")
              .limit(20)
          end
          render json: users.map { |u| user_json(u) }
        end

        private

        ALLOWED_FIELDS = %i[id name email avatar_url title team].freeze

        def user_json(user)
          if user.respond_to?(:id)
            ALLOWED_FIELDS.to_h { |f| [f, user.public_send(f)] }
          else
            ALLOWED_FIELDS.to_h { |f| [f, user[f]] }
          end
        end
      end
    end
  end
end
