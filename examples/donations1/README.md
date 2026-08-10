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
- **Typed form params.** `EnterDonorDetails` declares `dob` as a `Types::Date` and `newsletter` as a `Types::Boolean` — even though a form submits both as Strings. `Sidereal::FormsCodec` translates in both directions, so the handler does date arithmetic and a plain `if` on values it never had to parse, and `f.date_field` / `f.check_box` render them back out in the shape the browser expects. Submit a blank date or a malformed email to see the field-level errors stream back over SSE.
- **A custom payload type.** `money.rb` defines `Money` and gives it an encoder on *each* format Sidereal serializes through, since the two are separate registries. `SelectAmount#amount` is a `Money`, so the same value reaches each wire in the shape that wire can carry:

  ```
  hidden form field   value="3000 EUR"                  (MoneyFormsEncoder)
  storage/store/*.json  "amount":{"cents":3000,"currency":"EUR"}  (MoneyJSONEncoder)
  command handler     Money[cents: 3000, currency: 'EUR']
  ```

  The encoders are registered at load time, before any message type is defined — every compile walks the whole message registry, so a format missing an encoder for `Money` would fail to compile at all, at boot rather than on the first donation.

## Reset

Delete `donations.pstore` to clear all donations.
