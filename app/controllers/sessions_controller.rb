class SessionsController < ApplicationController
  skip_before_action :authenticate_user!, only: [:new, :create]

  def new
  end

  def create
    email = params[:email].to_s.strip.downcase

    user = CoPlan::User.find_or_initialize_by(email: email)
    user.assign_attributes(
      external_id: user.external_id || email,
      name: user.name || email.split("@").first.titleize
    )
    user.save!

    session[:user_id] = user.id
    redirect_to coplan.root_path, notice: "Signed in as #{user.name}."
  end

  def destroy
    reset_session
    redirect_to sign_in_path, notice: "Signed out."
  end
end
