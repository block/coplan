module CoPlan
  # A person's page and their library are the same page now: /<handle>,
  # served by BrowseController. This is the old /people/:id address, kept so
  # links written before the switch still land — and 301, so the address bar
  # and everything copied out of it converges on the readable form.
  #
  # The identity this page used to carry (name, title, team, directory link)
  # is the header of that page; the "Published plans" and "Library" columns
  # are the level view underneath it, with the same filters and counts
  # everyone gets.
  class ProfilesController < ApplicationController
    def show
      user = User.find_by(username: params[:id]) || User.find(params[:id])
      redirect_to browse_library_path(handle: user.library.handle), status: :moved_permanently
    end
  end
end
