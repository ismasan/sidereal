# frozen_string_literal: true

# BookingListing's records: one row per booking.
Sequel.migration do
  change do
    create_table?(:booking_listings) do
      String :booking_id, primary_key: true
      String :destination
      Date :depart_on
      Integer :nights
      Integer :travellers
      String :flight
      String :hotel
      # The machine's configuration: the paths of its active states, as JSON.
      String :machine, null: false, default: '[]'
      # When the booking was planned: the listing's order, which updates keep.
      Time :created_at, null: false
      Time :updated_at, null: false
      index :created_at
    end
  end
end
