# frozen_string_literal: true

class DonationPage < Sidereal::Page
  path '/:donation_id'

  on SelectAmount, EnterDonorDetails, ShowPaymentButton, PresentCard, ConfirmPayment, ExpireDonation do |evt|
    browser.patch_elements DonationPage.new(donation: DonationStore.find(evt.payload.donation_id))
  end

  on SendVerificationEmail do |evt|
    browser.patch_elements DonationPage.new(donation: DonationStore.find(evt.payload.donation_id))
  end

  on DeliverVerificationEmail do |evt|
    browser.patch_elements DonationPage.new(donation: DonationStore.find(evt.payload.donation_id))
  end

  on VerifyEmailAddress do |evt|
    browser.patch_elements DonationPage.new(donation: DonationStore.find_by_token(evt.payload.token))
  end

  def self.load(params, _ctx)
    donation = DonationStore.find(params[:donation_id])
    new(donation:, donation_id: params[:donation_id])
  end

  def initialize(donation: nil, donation_id: nil)
    @donation = donation
    @donation_id = donation_id || donation&.donation_id
  end

  def channel_name
    @donation_id ? "donations.#{@donation_id}" : 'donations'
  end

  def view_template
    div(id: 'donation-page') do
      header(class: 'header') do
        p(class: 'eyebrow') { 'Community Fund' }
        h1 { 'Donation kiosk' }
      end

      main(class: 'kiosk') do
        render Stepper.new(@donation)
        render CurrentStep.new(@donation)
      end
    end
  end

  class Stepper < Sidereal::Components::BaseComponent
    STEPS = [
      ['amount_selected', 'Select amount', :user],
      ['details_entered', 'Your details', :user],
      ['email_sent', 'Sending email', :background],
      ['verification_email_sent', 'Verify email', :user],
      ['email_verified', 'Verified', :background],
      ['payment_ready', 'Payment', :user],
      ['payment_confirmed', 'Thank you!', :user]
    ].freeze

    STATUS_INDEX = {
      'amount_selected' => 0,
      'details_entered' => 1,
      'email_sent' => 2,
      'verification_email_sent' => 3,
      'email_verified' => 4,
      'payment_ready' => 5,
      'card_presented' => 5,
      'payment_confirmed' => 6
    }.freeze

    def initialize(donation)
      @donation = donation
    end

    def view_template
      expired = @donation&.status == 'expired'
      nav_classes = ['stepper', ('stepper--expired' if expired)].compact.join(' ')
      nav(class: nav_classes, aria_label: 'Donation progress') do
        current = (@donation && !expired) ? STATUS_INDEX.fetch(@donation.status, 0) : -1
        STEPS.each_with_index do |(_, label, source), index|
          classes = ['step', "step--#{source}"]
          if expired
            classes << 'step--expired'
          else
            classes << 'step--complete' if index < current
            classes << 'step--current' if index == current
          end
          div(class: classes.join(' '), title: step_title(source)) do
            span(class: 'step__dot') { (index + 1).to_s }
            span(class: 'step__label') { label }
          end
        end
      end
    end

    private def step_title(source)
      source == :background ? 'Background automation' : 'User request'
    end
  end

  class CurrentStep < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      section(id: 'current-step', class: 'panel') do
        case @donation&.status
        when nil
          render AmountPicker.new
        when 'amount_selected'
          render DonorDetailsForm.new(@donation)
        when 'details_entered'
          render PreparingEmail.new(@donation)
        when 'email_sent'
          render SendingEmail.new(@donation)
        when 'verification_email_sent'
          render WaitingForEmail.new(@donation)
        when 'email_verified'
          render PaymentPreparing.new(@donation)
        when 'payment_ready'
          render PaymentPad.new(@donation)
        when 'card_presented'
          render PaymentProcessing.new(@donation)
        when 'payment_confirmed'
          render ThankYou.new(@donation)
        when 'expired'
          render Expired.new(@donation)
        else
          render AmountPicker.new
        end
      end
    end
  end

  class AmountPicker < Sidereal::Components::BaseComponent
    def view_template
      div(class: 'step-screen') do
        h2 { 'Choose an amount' }
        p(class: 'lede') { 'Select a preset amount to begin a donation.' }

        div(class: 'amount-grid') do
          DONATION_AMOUNTS.each do |amount|
            command SelectAmount, class: 'amount-form', key: amount.cents do |f|
              # A Money goes in; the codec's MoneyFormsEncoder writes it into the
              # hidden field as "3000 EUR" and reads it back as a Money on submit.
              f.payload_fields(amount:)
              button(type: :submit, class: 'amount-button') do
                span(class: 'amount-button__currency') { amount.symbol }
                span(class: 'amount-button__value') { amount.units }
              end
            end
          end
        end
      end
    end
  end

  class DonorDetailsForm < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Your details' }
        p(class: 'lede') { "We will send a verification link before taking #{@donation.amount}." }

        command EnterDonorDetails, class: 'details-form', autocomplete: 'off' do |f|
          f.payload_fields(donation_id: @donation.donation_id)
          label do
            span { 'Name' }
            f.text_field :name, autocomplete: 'name', placeholder: 'Ada Lovelace'
          end
          label do
            span { 'Email' }
            f.text_field :email,
              autocomplete: 'off',
              autocapitalize: 'none',
              spellcheck: 'false',
              inputmode: 'email',
              placeholder: 'ada@example.com'
          end
          # A Types::Date attribute: the browser submits '1815-12-10' and the
          # codec hands the handler a Date.
          label do
            span { 'Date of birth' }
            f.date_field :dob, max: Date.today.to_s
          end
          # A Types::Boolean attribute. The checkbox posts '1'; the hidden '0'
          # the helper renders alongside it is what an unchecked box posts,
          # since an unchecked box otherwise submits nothing at all.
          label(class: 'checkbox-label') do
            f.check_box :newsletter
            span { 'Email me about future campaigns' }
          end
          button(type: :submit, class: 'primary-button') { 'Send verification email' }
        end
      end
    end
  end

  class WaitingForEmail < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Check your email' }
        p(class: 'lede') { "We sent a verification link to #{@donation.email}." }
        # Reads as a Date and a boolean, not as the strings the form submitted:
        # #strftime and a plain ternary need no parsing here.
        p(class: 'lede') do
          "Born #{@donation.dob.strftime('%-d %B %Y')} — " +
            (@donation.newsletter ? 'subscribed to campaign updates.' : 'not subscribed to updates.')
        end

        div(class: 'email-preview') do
          p(class: 'email-preview__label') { 'Email preview' }
          p { "Hello #{@donation.name}, confirm your #{@donation.amount} donation with this link:" }
          a(href: @donation.verification_link) { @donation.verification_link }
        end
      end
    end
  end

  class PreparingEmail < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Preparing email' }
        p(class: 'lede') { "We are preparing a verification email for #{@donation.email}." }
        div(class: 'loading-bar') do
          span
        end
      end
    end
  end

  class SendingEmail < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Sending email' }
        p(class: 'lede') { "The email service is sending your verification link to #{@donation.email}." }
        div(class: 'notice') do
          p { 'This can take a few seconds in the demo.' }
        end
        div(class: 'loading-bar') do
          span
        end
      end
    end
  end

  class PaymentPreparing < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Email verified' }
        p(class: 'lede') { "Preparing the payment screen for your #{@donation.amount} donation." }
        div(class: 'loading-bar') do
          span
        end
      end
    end
  end

  class PaymentPad < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen payment-screen') do
        h2 { "Pay #{@donation.amount}" }
        p(class: 'lede') { 'Use the simulated contactless pad to complete the donation.' }

        div(class: 'card-pad') do
          div(class: 'card-pad__screen') do
            span { 'READY' }
            strong { "#{@donation.amount}" }
          end
          command PresentCard, class: 'tap-form' do |f|
            f.payload_fields(donation_id: @donation.donation_id)
            button(type: :submit, class: 'tap-button') { 'Tap card' }
          end
        end
      end
    end
  end

  class PaymentProcessing < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Processing payment' }
        p(class: 'lede') { 'The mock payment service is calling Stripe synchronously.' }
        div(class: 'loading-bar') do
          span
        end
      end
    end
  end

  class ThankYou < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen thank-you') do
        p(class: 'success-mark') { '✓' }
        h2 { 'Thank you' }
        p(class: 'lede') { "Your #{@donation.amount} donation has been confirmed." }
        dl(class: 'receipt') do
          div do
            dt { 'Donor' }
            dd { @donation.name }
          end
          div do
            dt { 'Email' }
            dd { @donation.email }
          end
          div do
            dt { 'Payment reference' }
            dd { @donation.payment_reference }
          end
        end
        a(href: '/', class: 'primary-button') { 'Make another donation' }
      end
    end
  end

  class Expired < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen expired') do
        p(class: 'expired-mark') { '✕' }
        h2 { 'Donation expired' }
        p(class: 'lede') { 'This donation session has timed out. No payment was taken.' }

        if @donation.amount || @donation.name || @donation.email
          dl(class: 'receipt') do
            if @donation.amount
              div do
                dt { 'Amount' }
                dd { "#{@donation.amount}" }
              end
            end
            if @donation.name
              div do
                dt { 'Donor' }
                dd { @donation.name }
              end
            end
            if @donation.email
              div do
                dt { 'Email' }
                dd { @donation.email }
              end
            end
          end
        end

        a(href: '/', class: 'primary-button') { 'Start a new donation' }
      end
    end
  end
end
