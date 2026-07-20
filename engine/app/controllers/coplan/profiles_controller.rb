module CoPlan
  # A person's public face: identity (enriched by the host's directory
  # adapter), their published plans, and their library shelves. Profiles
  # are them-facing — they show only publicly listed work, so drafts and
  # archived plans never appear here, not even on your own profile.
  class ProfilesController < ApplicationController
    def show
      @user = User.find_by(username: params[:id]) || User.find(params[:id])
      @profile = Directory.profile_for(@user)
      @library = @user.library

      @plans = @user.created_plans
        .publicly_listed
        .includes(:plan_type, :tags)
        .order(updated_at: :desc)

      # Same shelf-tree ivars LibrariesController#show sets — the profile
      # embeds the library rather than reimplementing it.
      @folders = @library.folders.order(:name).to_a
      @folder_children = @folders.group_by(&:parent_id)
      @root_folders = @folder_children[nil] || []

      placements = @library.placements
        .where(plan: Plan.publicly_listed)
        .joins(:plan).order("coplan_plans.updated_at DESC")
        .includes(plan: [ :created_by_user, :plan_type ])
        .to_a
      @placements_by_folder = placements.group_by(&:folder_id)
      @shelved_count = placements.size
    end
  end
end
