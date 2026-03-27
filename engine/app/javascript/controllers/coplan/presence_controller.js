import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

let sharedConsumer

function getConsumer() {
  if (!sharedConsumer) sharedConsumer = createConsumer()
  return sharedConsumer
}

export default class extends Controller {
  static values = { planId: String }

  connect() {
    this.channel = getConsumer().subscriptions.create(
      { channel: "CoPlan::PlanPresenceChannel", plan_id: this.planIdValue },
      {
        connected: () => { this.startPinging() },
        disconnected: () => { this.stopPinging() }
      }
    )
  }

  disconnect() {
    this.stopPinging()
    if (this.channel) {
      this.channel.unsubscribe()
      this.channel = null
    }
  }

  startPinging() {
    this.pingInterval = setInterval(() => {
      if (this.channel) this.channel.perform("ping")
    }, 15000)
  }

  stopPinging() {
    if (this.pingInterval) {
      clearInterval(this.pingInterval)
      this.pingInterval = null
    }
  }
}
