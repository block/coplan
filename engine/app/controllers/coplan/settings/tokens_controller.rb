module CoPlan
  module Settings
    class TokensController < ApplicationController
      PER_PAGE = 25

      def index
        load_personal_tokens
      end

      def sessions
        load_sessions
      end

      def create
        @api_token, @raw_token = ApiToken.create_with_raw_token(user: current_user, name: params.expect(api_token: [ :name ])[:name])
        load_personal_tokens(page: 1)

        respond_to do |format|
          format.turbo_stream
          format.html do
            flash[:raw_token] = @raw_token
            flash[:notice] = "Token created. Copy it now — it won't be shown again."
            redirect_to settings_tokens_path, status: :see_other
          end
        end
      rescue ActiveRecord::RecordInvalid => e
        respond_to do |format|
          format.turbo_stream do
            render turbo_stream: turbo_stream.update("token-errors", e.record.errors.full_messages.to_sentence),
              status: :unprocessable_content
          end
          format.html do
            load_personal_tokens
            flash.now[:alert] = e.message
            render :index, status: :unprocessable_content
          end
        end
      end

      def destroy
        @token = current_user.api_tokens.find(params[:id])
        @token.revoke!
        @sessions_view = params[:surface] == "sessions"
        @sessions_view ? load_sessions : load_personal_tokens

        respond_to do |format|
          format.turbo_stream
          format.html do
            destination = @sessions_view ? settings_agent_sessions_path(filter: @filter, q: @query, page: @page) : settings_tokens_path(page: (@page if @page > 1))
            redirect_to destination, notice: "Access revoked.", status: :see_other
          end
        end
      end

      private

      def load_personal_tokens(page: params[:page])
        paginate(current_user.api_tokens.personal, page: page)
      end

      def load_sessions
        @sessions_view = true
        @filter = params[:filter] == "history" ? "history" : "valid"
        @query = params[:q].to_s.strip.first(200)
        sessions = current_user.api_tokens.sessions
        @valid_count = sessions.usable.count
        @history_count = sessions.where.not(id: sessions.usable.select(:id)).count
        sessions = @filter == "history" ? sessions.where.not(id: sessions.usable.select(:id)) : sessions.usable
        if @query.present?
          # JSON storage differs by adapter; searching its text representation
          # lets a person find a reported harness/model as well as a run name.
          cast_type = ApiToken.connection.adapter_name == "PostgreSQL" ? "TEXT" : "CHAR"
          sessions = sessions.where("LOWER(name) LIKE :q OR LOWER(agent_name) LIKE :q OR LOWER(CAST(metadata AS #{cast_type})) LIKE :q",
            q: "%#{ApiToken.sanitize_sql_like(@query.downcase)}%")
        end
        paginate(sessions.includes(:parent))
      end

      def paginate(scope, page: params[:page])
        @page = page.to_i.clamp(1, 1_000_000)
        rows = scope.order(created_at: :desc, id: :desc).limit(PER_PAGE + 1).offset((@page - 1) * PER_PAGE).to_a
        @has_next = rows.length > PER_PAGE
        @api_tokens = rows.first(PER_PAGE)
      end
    end
  end
end
