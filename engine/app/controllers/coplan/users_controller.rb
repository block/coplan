module CoPlan
  # Session-authenticated user typeahead for in-app pickers (reviewer
  # assignment, @-mentions, etc.).
  #
  # The API equivalent at CoPlan::Api::V1::UsersController#search exists for
  # external callers and uses bearer-token auth — it can't be hit from the
  # browser since fetch() with `credentials: same-origin` only sends cookies.
  # This controller provides the same JSON shape behind the regular session.
  class UsersController < ApplicationController
    ALLOWED_FIELDS = %i[id name email username avatar_url title team].freeze

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
          .where("name LIKE :q OR email LIKE :q OR username LIKE :q", q: "%#{sanitized}%")
          .limit(20)
      end

      render json: users.map { |u| user_json(u) }
    end

    private

    def user_json(user)
      if user.respond_to?(:id)
        ALLOWED_FIELDS.to_h { |f| [f, user.public_send(f)] }
      else
        ALLOWED_FIELDS.to_h { |f| [f, user[f]] }
      end
    end
  end
end
