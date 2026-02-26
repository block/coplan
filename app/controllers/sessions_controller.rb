class SessionsController < ApplicationController
  skip_before_action :authenticate_user!, only: [:new, :create]

  def new
  end

  def create
    email = params[:email].to_s.strip.downcase

    user = User.find_or_create_by!(email: email) do |u|
      u.name = email.split("@").first.titleize
    end
    user.update!(last_sign_in_at: Time.current)

    session[:user_id] = user.id
    redirect_to coplan.root_path, notice: "Signed in as #{user.name}."
  end

  def destroy
    reset_session
    redirect_to sign_in_path, notice: "Signed out."
  end
end
