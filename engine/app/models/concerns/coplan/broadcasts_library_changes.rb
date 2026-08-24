module CoPlan
  # Live library listings. Anything that changes what a library's pages
  # show — a document arriving, moving, being retitled or hidden; a folder
  # created, renamed, moved or deleted — tells the library, and every
  # browser watching it re-fetches its own view of it.
  #
  # In the models rather than the controllers on purpose. Most of what
  # moves a library is an agent filing something through the API or a
  # background job finishing, not a person clicking; a person watching in
  # a browser should see those land either way.
  module BroadcastsLibraryChanges
    extend ActiveSupport::Concern

    private

    # Nil and duplicate libraries drop out, so a move that stays inside one
    # library refreshes it once, and a plan with no library yet is a no-op.
    def broadcast_library_refresh(*libraries)
      libraries.compact.uniq.each { |library| Broadcaster.refresh_to(library) }
    end
  end
end
