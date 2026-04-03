module CoPlan
  module Api
    module V1
      class UsersController < BaseController
        def search
          query = params[:q].to_s.strip
          if query.blank?
            return render json: []
          end

          if CoPlan.configuration.user_search
            results = CoPlan.configuration.user_search.call(query)
            render json: results
          else
            users = CoPlan::User
              .where("name LIKE :q OR email LIKE :q", q: "%#{query}%")
              .limit(20)
            render json: users.map { |u| user_json(u) }
          end
        end

        private

        def user_json(user)
          {
            id: user.id,
            name: user.name,
            email: user.email,
            avatar_url: user.avatar_url,
            title: user.title,
            team: user.team
          }
        end
      end
    end
  end
end
