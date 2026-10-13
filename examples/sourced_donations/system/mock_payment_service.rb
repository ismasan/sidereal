# frozen_string_literal: true

module MockPaymentService
  module_function

  def charge(donation)
    sleep 4 # demo: simulate slow Stripe API
    StripeGateway.authorize(amount: donation.amount, email: donation.email)
  end
end
