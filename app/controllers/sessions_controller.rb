class SessionsController < ApplicationController
  skip_before_action :authenticate_user!, only: [:new, :create]

  def new
  end

  def create
    email = params[:email].to_s.strip.downcase
    domain = email.split("@").last

    org = Organization.all.find { |o| o.email_domain_allowed?(email) }
    if org.nil?
      flash.now[:alert] = "No organization found for email domain \"#{domain}\"."
      render :new, status: :unprocessable_entity
      return
    end

    user = org.users.find_or_create_by!(email: email) do |u|
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
