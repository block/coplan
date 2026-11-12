# Browser test synchronization

System specs run Chrome through Capybara and Selenium. The test-only
[`capybara-lockstep`](https://github.com/makandra/capybara-lockstep) gem waits
for browser work around normal Capybara commands. Both page layouts include its
snippet before application scripts. A test-only head wrapper covers ActiveAdmin's
separate layout too. The test environment also uses its Rack
middleware to wait for server requests.

Write normal interactions and assertions:

```ruby
click_button "Post comment"
expect(page).to have_css("mark.anchor-highlight", text: "Selected text")
```

Lockstep tracks fetch/XHR requests and resource loading. The shared snippet in
`spec/support/browser_synchronization.js` also tracks each received Turbo Stream
through its render promise, including renderers wrapped by Stimulus controllers.
That covers both HTTP responses and streams received over Action Cable. A
cancelled or failed renderer releases its work count.

The gem uses Capybara's current wait budget. By default a synchronization timeout
is logged, and synchronization is tried again on the next command. This matters
when a full document navigation discards the previous page's probe. A logged
timeout is not proof of readiness: feature assertions must still pass. The
cancellation/failure regressions explicitly wait for the browser's idle callback
and fail if the work count leaks, regardless of this logging policy.

## Readiness has a scope

Stimulus connects controllers, but does not know when every controller's async
work has finished. `document.readyState` describes the initial document load,
not later changes to a live page. Lockstep supplies test coordination, not a
permanent promise that the document cannot change.

Keep Capybara's retrying assertions. A future broadcast can replace elements
after any readiness check. When asserting a collection, put the entire read
inside a Capybara filter so a detached element retries the whole read:

```ruby
expect(page).to have_css("#plan-content-body") do |body|
  body.all("mark.anchor-highlight", count: 2).map(&:text) == [ "relation", "links" ]
end
```

An open WebSocket is not unfinished work. The shared hook waits for a stream
that has arrived; it cannot predict a future message. Specs that initiate work
from Ruby must first observe the expected delivery and can explicitly call
`Capybara::Lockstep.synchronize` to join its rendering. The real cable regression
in `spec/system/browser_synchronization_spec.rb` demonstrates this boundary.

Timers, animations, service workers, and application promises outside tracked
requests are not automatically idle conditions. Assert their visible result or
use a specific completion signal. Do not add sleeps to guess when a page is ready.

## Test unfinished work deliberately

Progress, overlapping edits, held pointer gestures, and delayed-response tests
must interact while work is unfinished. Mark those examples explicitly:

```ruby
it "keeps the save indicator visible while the response is held", browser_sync: :manual do
  # Hold the response, assert progress, then release it and assert completion.
end
```

This pauses automatic Lockstep synchronization for that example. Capybara's
normal assertion retries remain active. The shared setup restores automatic
mode after every example, including failures. Do not use this metadata to hide
an unexplained synchronization timeout.

For a small observation within an otherwise synchronized test, use
`Capybara::Lockstep.with_mode(:manual) { ... }`, then explicitly synchronize once
the held work is released. Prefer the smallest scope that preserves the race
the regression is meant to exercise.

## Try the integration

Use a dedicated test database so other checkouts retain their data:

```sh
bundle install
RAILS_ENV=test DATABASE_URL=mysql2://root@localhost/coplan_browser_sync_tryout bin/rails db:create db:schema:load
RAILS_ENV=test DATABASE_URL=mysql2://root@localhost/coplan_browser_sync_tryout bundle exec rspec spec/system/browser_synchronization_spec.rb spec/system/math_rendering_spec.rb
```

Expect the delayed-fetch, real-cable, cancelled/failed-renderer, and math cases
to pass. The command starts its own test server. Product navigation and visual
styles are unchanged.

Set `BROWSER_SYNC_DEBUG=1` on a spec command to log Lockstep's synchronization
steps and tracked work while diagnosing a timeout.
