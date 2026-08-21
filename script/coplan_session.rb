# frozen_string_literal: true

# Thin shim: the real helper lives in the engine (engine/agent_tools/) so
# any CoPlan server can serve it to agents at
# /agent-tools/coplan_session.rb alongside coplan-attach, which requires
# it. This keeps `require_relative "coplan_session"` working for the
# scripts in this directory.
require_relative "../engine/agent_tools/coplan_session"
