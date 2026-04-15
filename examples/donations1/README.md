# Donations Kiosk

A Sidereal demo modeling a multi-step donation flow with a mix of user-driven and background-driven steps. Each donation has its own SSE channel, so multiple kiosks can run side by side without crosstalk.

## Run

```bash
cd examples/donations1
bundle install
bundle exec falcon host
```

Then open <http://localhost:9294>.

## Flow

```
AmountPicker
  → DonorDetailsForm
  → PreparingEmail        (background: SendVerificationEmail)
  → SendingEmail          (background: DeliverVerificationEmail, ~3s)
  → WaitingForEmail       (user clicks the verification link)
  → /verify/:token        → PaymentPreparing (background: ShowPaymentButton)
  → PaymentPad            (user taps card)
  → PaymentProcessing     (mock Stripe call)
  → ThankYou
```

The `Stepper` component tags each step as `:user` or `:background` so you can see which transitions are driven by the visitor and which by the server.

## Notable patterns

- **Per-donation channels.** `handle` blocks in `app.rb` stamp each command with `metadata.channel = "donations.<donation_id>"`, and `DonationPage#channel_name` subscribes to the same channel. SSE updates only flow to the matching donation's open page.
- **Custom route.** `GET /verify/:token` looks up the donation, appends a `VerifyEmailAddress` command to the store with the right channel metadata, then redirects to the donation page.
- **Persistent read model.** `DonationStore` is backed by `PStore` (`donations.pstore`) so the donation survives the redirect and is visible to all worker fibers.
- **Mock payment.** `MockPaymentService.charge` returns a fake Stripe reference; `DeliverVerificationEmail` uses `sleep 3` to simulate email-service latency.

## Reset

Delete `donations.pstore` to clear all donations.
