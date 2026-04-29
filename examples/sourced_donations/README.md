# Donations Kiosk (Sourced backend)

The same donation flow as `examples/donations1`, but persisted as an event log via [Sourced](https://github.com/ismasan/sourced). State is rebuilt from past events on every page load; "automations" in the model become Sourced reactions.

Based on the same Event Lanes model: [Sidereal example: donations kiosk flow](https://eventlanes.app/models/42e651db-ee09-4a7d-9c1d-2dd14d6383ea).

## Run

```bash
cd examples/sourced_donations
bundle install
bundle exec falcon host
```

Then open <http://localhost:9295>. The SQLite event store lives at `storage/donations.db`.

## Flow

Same UI flow as `donations1` — `AmountPicker → DonorDetailsForm → PreparingEmail → SendingEmail (~3s) → WaitingForEmail → /verify/:donation_id/:token → PaymentPreparing → PaymentPad → PaymentProcessing → ThankYou`. The `Stepper` tags each step as `:user` or `:background`.

## What changed vs donations1

| | `donations1` | `sourced_donations` |
| --- | --- | --- |
| State | mutable Struct in `PStore` | rebuilt from event log via `Sourced.load` |
| Command handlers | mutate the store directly | pure: validate against state, emit events |
| Automations | `dispatch` from inside command handlers | Sourced `reaction` blocks emit follow-up commands |
| Persistence | `donations.pstore` | `storage/donations.db` (SQLite via Sequel) |
| Workers | Sidereal in-memory queue | Sourced consumer-group workers |
| `/verify/...` lookup | `DonationStore.find_by_token` | URL carries `donation_id`, decider checks the token |

## Decider shape (`domain/donation.rb`)

```ruby
class Donation < Sourced::Decider
  partition_by :donation_id

  # commands & events defined with Sourced::Command.define / Sourced::Event.define

  state { |values| State.new(donation_id: values[:donation_id]) }

  evolve(AmountSelected) { |s, e| s.amount = e.payload.amount; s.status = 'amount_selected' }
  # ... one evolve per event

  command(SelectAmount) do |state, cmd|
    raise 'invalid' unless AMOUNTS.include?(cmd.payload.amount.to_i)
    event AmountSelected, donation_id: cmd.payload.donation_id, amount: cmd.payload.amount.to_i
  end

  # email_sender automation
  reaction(DonorDetailsEntered) { |_, evt| dispatch SendVerificationEmail, donation_id: evt.payload.donation_id }
  reaction(EmailSent)           { |_, evt| dispatch DeliverVerificationEmail, donation_id: evt.payload.donation_id }

  # mock_payment_service automation
  reaction(CardPresented) do |state, evt|
    payment_reference = MockPaymentService.charge(state)
    dispatch ConfirmPayment, donation_id: evt.payload.donation_id, payment_reference:
  end

  # bridge to Sidereal SSE — publish each event on the per-donation channel
  after_sync do |state:, events:, **|
    events.each do |evt|
      Sidereal.pubsub.publish(DonationsApp.commander.channel_name(evt), evt)
    end
  end
end
```

## Loading state in a page

```ruby
def self.load_donation(donation_id)
  decider, _ = Sourced.load(Donation, donation_id:)
  decider.state
end
```

Restart the server and the donation page rebuilds entirely from the event log — no in-memory state to repopulate.

## Reset

Delete `storage/donations.db*` to wipe the event log.
